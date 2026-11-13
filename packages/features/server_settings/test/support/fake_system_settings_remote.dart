import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [SystemSettingsRemoteDataSource] whose answers a test completes by hand.
class FakeSystemSettingsRemote implements SystemSettingsRemoteDataSource {
  final List<Completer<SystemSettings>> fetches = [];
  final List<Completer<SystemSettings>> updates = [];
  final List<({String id, SystemSettingsPatch patch})> updateCalls = [];

  @override
  Future<SystemSettings> fetch() {
    final completer = Completer<SystemSettings>();
    fetches.add(completer);
    return completer.future;
  }

  @override
  Future<SystemSettings> update(String id, SystemSettingsPatch patch) {
    updateCalls.add((id: id, patch: patch));
    final completer = Completer<SystemSettings>();
    updates.add(completer);
    return completer.future;
  }

  /// How many times [sendMailTest] was called.
  int sendMailTestCalls = 0;

  /// What [sendMailTest] throws, when set.
  Exception? sendMailTestError;

  /// What [sendMailTest] waits on before it answers, when set.
  Completer<void>? sendMailTestGate;

  @override
  Future<void> sendMailTest() async {
    sendMailTestCalls++;
    await sendMailTestGate?.future;
    final error = sendMailTestError;
    if (error != null) {
      throw error;
    }
  }
}

/// Settings as the server would first send them.
SystemSettings settingsFixture({String? smtpHost}) => SystemSettings(
  id: 'settings-1',
  smtpHost: smtpHost,
  smtpPort: 587,
  smtpSecurity: SmtpSecurity.startTls,
  smtpUser: null,
  smtpPasswordSet: false,
  mailFromAddress: null,
  passwordResetLinkLifetimeMinutes: 1440,
  allowPasswordResets: true,
  providerLinkingPolicy: ProviderLinkingPolicy.signedIn,
);
