import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  test('an empty patch is empty', () {
    expect(const SystemSettingsPatch().isEmpty, isTrue);
    expect(
      const SystemSettingsPatch(allowPasswordResets: false).isEmpty,
      isFalse,
    );
    expect(
      const SystemSettingsPatch(smtpUser: SettingValue.clear()).isEmpty,
      isFalse,
    );
  });

  group('every field', () {
    // One patch per field, each setting only that field.
    const patches = <String, SystemSettingsPatch>{
      'smtpHost': SystemSettingsPatch(smtpHost: SettingValue.set('h')),
      'smtpPort': SystemSettingsPatch(smtpPort: 587),
      'smtpSecurity': SystemSettingsPatch(smtpSecurity: SmtpSecurity.none),
      'smtpUser': SystemSettingsPatch(smtpUser: SettingValue.clear()),
      'smtpPassword': SystemSettingsPatch(smtpPassword: SettingValue.set('p')),
      'mailFromAddress': SystemSettingsPatch(
        mailFromAddress: SettingValue.set('a@b.c'),
      ),
      'passwordResetLinkLifetimeMinutes': SystemSettingsPatch(
        passwordResetLinkLifetimeMinutes: 30,
      ),
      'allowPasswordResets': SystemSettingsPatch(allowPasswordResets: true),
      'providerLinkingPolicy': SystemSettingsPatch(
        providerLinkingPolicy: ProviderLinkingPolicy.signedIn,
      ),
    };

    test('each sets its own entry of props, and together they cover them', () {
      final setIndexes = <int>{};
      for (final MapEntry(key: field, value: patch) in patches.entries) {
        final indexes = [
          for (var i = 0; i < patch.props.length; i++)
            if (patch.props[i] != null) i,
        ];
        expect(indexes, hasLength(1), reason: field);
        setIndexes.add(indexes.single);
      }
      expect(setIndexes, hasLength(const SystemSettingsPatch().props.length));
    });

    test('each makes a patch non-empty and unequal to the empty one', () {
      for (final MapEntry(key: field, value: patch) in patches.entries) {
        expect(patch.isEmpty, isFalse, reason: field);
        expect(patch, isNot(const SystemSettingsPatch()), reason: field);
      }
    });
  });

  group('changesMailServer', () {
    test('is true for host, port or security', () {
      expect(
        const SystemSettingsPatch(smtpPort: 465).changesMailServer,
        isTrue,
      );
      expect(
        const SystemSettingsPatch(
          smtpHost: SettingValue.set('h'),
        ).changesMailServer,
        isTrue,
      );
      expect(
        const SystemSettingsPatch(
          smtpSecurity: SmtpSecurity.none,
        ).changesMailServer,
        isTrue,
      );
    });

    test('is false for other fields', () {
      expect(
        const SystemSettingsPatch(
          smtpUser: SettingValue.clear(),
        ).changesMailServer,
        isFalse,
      );
    });
  });

  test('setting values compare by value', () {
    expect(
      const SettingValue<String>.set('a'),
      const SettingValue<String>.set('a'),
    );
    expect(
      const SettingValue<String>.set('a'),
      isNot(const SettingValue<String>.set('b')),
    );
    expect(
      const SettingValue<String>.clear(),
      const SettingValue<String>.clear(),
    );
    // Not const, so not identical: compared by props.
    // ignore: prefer_const_constructors
    expect(SettingClear<String>(), const SettingValue<String>.clear());
    expect(
      const SettingValue<String>.set('a'),
      isNot(const SettingValue<String>.clear()),
    );
  });
}
