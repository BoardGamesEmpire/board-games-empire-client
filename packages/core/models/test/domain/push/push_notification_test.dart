import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('PushNotification', () {
    test('round-trips through JSON with all fields populated', () {
      const notification = PushNotification(
        localServerId: 'srv_local_1',
        title: 'Game night',
        body: 'Ticket to Ride at 7pm',
        data: <String, Object?>{
          'eventId': 'evt_1',
          'occurrence': 3,
          'nested': <String, Object?>{'key': 'value'},
        },
        deepLink: 'bge://events/evt_1',
      );

      final round = PushNotification.fromJson(notification.toJson());
      expect(round, equals(notification));
    });

    test('round-trips with optional fields absent', () {
      const notification = PushNotification(
        localServerId: 'srv_local_1',
        title: 'Friend request',
        body: 'alex wants to be your friend',
      );

      final round = PushNotification.fromJson(notification.toJson());
      expect(round, equals(notification));
      expect(round.data, isNull);
      expect(round.deepLink, isNull);
    });

    test('data map values survive the round-trip', () {
      const notification = PushNotification(
        localServerId: 'srv_local_1',
        title: 'Import complete',
        body: '42 games imported',
        data: <String, Object?>{'batchId': 'batch_1', 'count': 42},
      );

      final round = PushNotification.fromJson(notification.toJson());
      expect(round.data, equals(notification.data));
    });

    test('serializes with camelCase keys', () {
      const notification = PushNotification(
        localServerId: 'srv_local_1',
        title: 't',
        body: 'b',
        deepLink: 'bge://x',
      );

      final json = notification.toJson();
      expect(
        json.keys,
        containsAll(<String>['localServerId', 'title', 'body', 'deepLink']),
      );
    });
  });
}
