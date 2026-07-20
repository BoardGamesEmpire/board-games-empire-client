import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

PushRegistration _registration({PushPlatform platform = PushPlatform.fcm}) =>
    PushRegistration(
      registrationId: 'reg_1',
      localServerId: 'srv_local_1',
      bgeServerId: 'a3a52c3e-2b6f-4a3f-9d5e-1f2a3b4c5d6e',
      platformToken: 'token-abc123',
      platform: platform,
      registeredAt: DateTime.parse('2026-07-19T10:30:00Z'),
    );

void main() {
  group('PushRegistration', () {
    test('round-trips through JSON', () {
      final registration = _registration();
      final round = PushRegistration.fromJson(registration.toJson());
      expect(round, equals(registration));
    });

    test('serializes with camelCase keys', () {
      final json = _registration().toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'registrationId',
          'localServerId',
          'bgeServerId',
          'platformToken',
          'platform',
          'registeredAt',
        ]),
      );
    });

    test('registeredAt survives the round-trip', () {
      final registration = _registration();
      final round = PushRegistration.fromJson(registration.toJson());
      expect(round.registeredAt, equals(registration.registeredAt));
    });
  });

  group('PushPlatform', () {
    test('every Dart value round-trips through PushRegistration', () {
      for (final value in PushPlatform.values) {
        final registration = _registration(platform: value);
        final round = PushRegistration.fromJson(registration.toJson());
        expect(round.platform, equals(value));
      }
    });

    test('wire format uses Dart enum names (server contract deferred to '
        'backend #186)', () {
      const expectations = <PushPlatform, String>{
        PushPlatform.fcm: 'fcm',
        PushPlatform.apns: 'apns',
        PushPlatform.webPush: 'webPush',
        PushPlatform.unifiedPush: 'unifiedPush',
        PushPlatform.unsupported: 'unsupported',
      };

      for (final entry in expectations.entries) {
        expect(
          _registration(platform: entry.key).toJson()['platform'],
          equals(entry.value),
          reason:
              'PushPlatform.${entry.key.name} should serialize as '
              '"${entry.value}"',
        );
      }
    });
  });
}
