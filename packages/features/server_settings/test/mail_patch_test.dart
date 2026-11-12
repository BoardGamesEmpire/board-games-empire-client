import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/src/mail/mail_patch.dart';

const _stored = SystemSettings(
  id: 'settings-1',
  smtpHost: 'smtp.example.com',
  smtpPort: 587,
  smtpSecurity: SmtpSecurity.startTls,
  smtpUser: 'mailer',
  smtpPasswordSet: true,
  mailFromAddress: 'games@example.com',
  passwordResetLinkLifetimeMinutes: 1440,
  allowPasswordResets: true,
  providerLinkingPolicy: ProviderLinkingPolicy.signedIn,
);

const _noHost = SystemSettings(
  id: 'settings-1',
  smtpHost: null,
  smtpPort: 587,
  smtpSecurity: SmtpSecurity.startTls,
  smtpUser: null,
  smtpPasswordSet: false,
  mailFromAddress: null,
  passwordResetLinkLifetimeMinutes: 1440,
  allowPasswordResets: true,
  providerLinkingPolicy: ProviderLinkingPolicy.signedIn,
);

/// The form's values for [from] as it was read, with the changes given.
MailFormValues _values(
  SystemSettings from, {
  String? host,
  int? port,
  SmtpSecurity? Function()? security,
  String? user,
  String password = '',
  PasswordEdit? passwordEdit,
  String? fromAddress,
  bool? allowPasswordResets,
  int? linkLifetimeMinutes,
}) => MailFormValues(
  host: host ?? from.smtpHost ?? '',
  port: port ?? from.smtpPort,
  security: security != null ? security() : from.smtpSecurity,
  user: user ?? from.smtpUser ?? '',
  password: password,
  passwordEdit:
      passwordEdit ??
      (from.smtpPasswordSet ? PasswordEdit.keep : PasswordEdit.replace),
  from: fromAddress ?? from.mailFromAddress ?? '',
  allowPasswordResets: allowPasswordResets ?? from.allowPasswordResets,
  linkLifetimeMinutes:
      linkLifetimeMinutes ?? from.passwordResetLinkLifetimeMinutes,
);

void main() {
  group('mailPatch', () {
    test('unchanged values make an empty patch', () {
      expect(mailPatch(_stored, _values(_stored)).isEmpty, isTrue);
      expect(mailPatch(_noHost, _values(_noHost)).isEmpty, isTrue);
    });

    test('a host of spaces clears a stored host', () {
      expect(
        mailPatch(_stored, _values(_stored, host: '  ')),
        const SystemSettingsPatch(smtpHost: SettingValue.clear()),
      );
    });

    test('a host of spaces with none stored is left out', () {
      expect(mailPatch(_noHost, _values(_noHost, host: '  ')).isEmpty, isTrue);
    });

    test('host, user and From are sent trimmed, and only when they differ '
        'from the stored value once trimmed', () {
      expect(
        mailPatch(
          _stored,
          _values(
            _stored,
            host: ' smtp.example.com ',
            user: ' relay ',
            fromAddress: ' admin@example.com ',
          ),
        ),
        const SystemSettingsPatch(
          smtpUser: SettingValue.set('relay'),
          mailFromAddress: SettingValue.set('admin@example.com'),
        ),
      );
    });

    test('the numbers and the switch are sent when they differ', () {
      expect(
        mailPatch(
          _stored,
          _values(
            _stored,
            port: 465,
            allowPasswordResets: false,
            linkLifetimeMinutes: 60,
          ),
        ),
        const SystemSettingsPatch(
          smtpPort: 465,
          allowPasswordResets: false,
          passwordResetLinkLifetimeMinutes: 60,
        ),
      );
    });

    test('a replacing password is sent as typed, untrimmed', () {
      expect(
        mailPatch(
          _stored,
          _values(
            _stored,
            password: ' p ',
            passwordEdit: PasswordEdit.replace,
          ),
        ),
        const SystemSettingsPatch(smtpPassword: SettingValue.set(' p ')),
      );
    });

    test('an empty replacing password is left out', () {
      expect(
        mailPatch(
          _noHost,
          _values(_noHost, passwordEdit: PasswordEdit.replace),
        ).isEmpty,
        isTrue,
      );
      // The form refuses this one before building a patch; the patch still
      // never sends a password the server refuses as empty.
      expect(
        mailPatch(
          _stored,
          _values(_stored, passwordEdit: PasswordEdit.replace),
        ).isEmpty,
        isTrue,
      );
    });

    test('a kept password is left out, whatever the field holds', () {
      expect(
        mailPatch(_stored, _values(_stored, password: 'typed')).isEmpty,
        isTrue,
      );
    });

    test('removing a saved password clears it', () {
      expect(
        mailPatch(
          _stored,
          _values(_stored, passwordEdit: PasswordEdit.remove),
        ),
        const SystemSettingsPatch(smtpPassword: SettingValue.clear()),
      );
    });

    test('removing with no password saved is left out', () {
      expect(
        mailPatch(
          _noHost,
          _values(_noHost, passwordEdit: PasswordEdit.remove),
        ).isEmpty,
        isTrue,
      );
    });

    test('a null security, a setting this app does not know, is left out', () {
      expect(
        mailPatch(_stored, _values(_stored, security: () => null)).isEmpty,
        isTrue,
      );
    });

    test('a security that differs is sent', () {
      expect(
        mailPatch(_stored, _values(_stored, security: () => SmtpSecurity.none)),
        const SystemSettingsPatch(smtpSecurity: SmtpSecurity.none),
      );
    });
  });

  group('mailPasswordNeeded', () {
    bool needed(SystemSettings from, MailFormValues values) =>
        mailPasswordNeeded(from, mailPatch(from, values));

    test('a port change with a saved password kept needs it', () {
      expect(needed(_stored, _values(_stored, port: 2525)), isTrue);
    });

    test('a host or security change with a saved password kept needs it', () {
      expect(needed(_stored, _values(_stored, host: 'mail.other.org')), isTrue);
      expect(
        needed(_stored, _values(_stored, security: () => SmtpSecurity.none)),
        isTrue,
      );
    });

    test('clearing the host does not: nothing is sent anywhere', () {
      expect(needed(_stored, _values(_stored, host: '')), isFalse);
    });

    test('a replacing or removed password does not', () {
      expect(
        needed(
          _stored,
          _values(
            _stored,
            port: 2525,
            password: 'new',
            passwordEdit: PasswordEdit.replace,
          ),
        ),
        isFalse,
      );
      expect(
        needed(
          _stored,
          _values(_stored, port: 2525, passwordEdit: PasswordEdit.remove),
        ),
        isFalse,
      );
    });

    test('an empty new password with a change of server needs it: like the '
        'server, it reads the patch, which carries no password', () {
      expect(
        needed(
          _stored,
          _values(_stored, port: 2525, passwordEdit: PasswordEdit.replace),
        ),
        isTrue,
      );
    });

    test('a change that leaves the mail server alone does not', () {
      expect(needed(_stored, _values(_stored, user: 'other')), isFalse);
    });

    test('no saved password does not', () {
      expect(
        needed(_noHost, _values(_noHost, host: 'smtp.example.com')),
        isFalse,
      );
    });
  });
}
