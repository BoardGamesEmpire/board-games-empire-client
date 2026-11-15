import 'package:models/domain.dart';
import 'package:test/test.dart';

SystemSettings _settings({String? host, String? from}) => SystemSettings(
  id: 's1',
  smtpHost: host,
  smtpPort: 587,
  smtpSecurity: SmtpSecurity.startTls,
  smtpUser: null,
  smtpPasswordSet: false,
  mailFromAddress: from,
  passwordResetLinkLifetimeMinutes: 1440,
  allowPasswordResets: true,
  providerLinkingPolicy: ProviderLinkingPolicy.signedIn,
  name: 'Board Games Empire',
  allowUserRegistration: true,
  allowUsernameChange: true,
  feedbackReportRetentionDays: 90,
  feedbackReportServerRedactionEnabled: true,
  requireContributionApproval: false,
  contributionReclaimDays: 14,
  auditLogRetentionDays: null,
  householdInviteePolicy: Reach.public,
  eventInviteePolicy: Reach.public,
);

void main() {
  group('SmtpSecurity', () {
    test('reads a known name', () {
      expect(SmtpSecurity.fromWire('ImplicitTls'), SmtpSecurity.implicitTls);
    });

    test('reads an unknown name as unknown', () {
      expect(SmtpSecurity.fromWire('Ssl'), SmtpSecurity.unknown);
    });

    test('writes known names and refuses to write unknown', () {
      expect(SmtpSecurity.startTls.wireName, 'StartTls');
      expect(SmtpSecurity.implicitTls.wireName, 'ImplicitTls');
      expect(SmtpSecurity.none.wireName, 'None');
      expect(() => SmtpSecurity.unknown.wireName, throwsStateError);
    });
  });

  group('ProviderLinkingPolicy', () {
    test('reads a known name', () {
      expect(
        ProviderLinkingPolicy.fromWire('AutomaticWhenVerified'),
        ProviderLinkingPolicy.automaticWhenVerified,
      );
    });

    test('reads an unknown name as unknown', () {
      expect(
        ProviderLinkingPolicy.fromWire('AdminApproval'),
        ProviderLinkingPolicy.unknown,
      );
    });

    test('writes known names and refuses to write unknown', () {
      expect(ProviderLinkingPolicy.signedIn.wireName, 'SignedIn');
      expect(
        ProviderLinkingPolicy.automaticWhenVerified.wireName,
        'AutomaticWhenVerified',
      );
      expect(() => ProviderLinkingPolicy.unknown.wireName, throwsStateError);
    });
  });

  group('SystemSettings.mailConfigured', () {
    test('is false without a from address', () {
      expect(_settings(host: 'mail.example.com').mailConfigured, isFalse);
    });

    test('is false without a host', () {
      expect(_settings(from: 'a@example.com').mailConfigured, isFalse);
    });

    test('is true with both', () {
      expect(
        _settings(
          host: 'mail.example.com',
          from: 'a@example.com',
        ).mailConfigured,
        isTrue,
      );
    });
  });

  test('compares by every field', () {
    const base = SystemSettings(
      id: 's1',
      smtpHost: 'mail.example.com',
      smtpPort: 587,
      smtpSecurity: SmtpSecurity.startTls,
      smtpUser: 'mailer',
      smtpPasswordSet: true,
      mailFromAddress: 'a@example.com',
      passwordResetLinkLifetimeMinutes: 1440,
      allowPasswordResets: true,
      providerLinkingPolicy: ProviderLinkingPolicy.signedIn,
      name: 'Board Games Empire',
      allowUserRegistration: true,
      allowUsernameChange: true,
      feedbackReportRetentionDays: 90,
      feedbackReportServerRedactionEnabled: true,
      requireContributionApproval: false,
      contributionReclaimDays: 14,
      auditLogRetentionDays: null,
      householdInviteePolicy: Reach.public,
      eventInviteePolicy: Reach.public,
    );
    SystemSettings copy({
      String id = 's1',
      String? host = 'mail.example.com',
      int port = 587,
      SmtpSecurity security = SmtpSecurity.startTls,
      String? user = 'mailer',
      bool passwordSet = true,
      String? from = 'a@example.com',
      int lifetime = 1440,
      bool allowPasswordResets = true,
      ProviderLinkingPolicy linking = ProviderLinkingPolicy.signedIn,
      String name = 'Board Games Empire',
      bool registration = true,
      bool usernameChange = true,
      int feedbackDays = 90,
      bool redaction = true,
      bool approval = false,
      int reclaimDays = 14,
      int? auditDays,
      Reach household = Reach.public,
      Reach event = Reach.public,
    }) => SystemSettings(
      id: id,
      smtpHost: host,
      smtpPort: port,
      smtpSecurity: security,
      smtpUser: user,
      smtpPasswordSet: passwordSet,
      mailFromAddress: from,
      passwordResetLinkLifetimeMinutes: lifetime,
      allowPasswordResets: allowPasswordResets,
      providerLinkingPolicy: linking,
      name: name,
      allowUserRegistration: registration,
      allowUsernameChange: usernameChange,
      feedbackReportRetentionDays: feedbackDays,
      feedbackReportServerRedactionEnabled: redaction,
      requireContributionApproval: approval,
      contributionReclaimDays: reclaimDays,
      auditLogRetentionDays: auditDays,
      householdInviteePolicy: household,
      eventInviteePolicy: event,
    );

    expect(copy(), base);
    for (final other in [
      copy(id: 's2'),
      copy(host: 'mail.other.org'),
      copy(port: 465),
      copy(security: SmtpSecurity.none),
      copy(user: null),
      copy(passwordSet: false),
      copy(from: 'b@example.com'),
      copy(lifetime: 60),
      copy(allowPasswordResets: false),
      copy(linking: ProviderLinkingPolicy.automaticWhenVerified),
      copy(name: 'Other'),
      copy(registration: false),
      copy(usernameChange: false),
      copy(feedbackDays: 30),
      copy(redaction: false),
      copy(approval: true),
      copy(reclaimDays: 7),
      copy(auditDays: 365),
      copy(household: Reach.friends),
      copy(event: Reach.friends),
    ]) {
      expect(other, isNot(base));
    }
  });
}
