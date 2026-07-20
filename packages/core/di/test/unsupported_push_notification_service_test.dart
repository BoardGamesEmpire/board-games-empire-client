import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

/// Behavior tests for the #15 null object. The stub semantics are a
/// locked contract (see #15 "Stub" section): callers are entitled to
/// rely on the empty-broadcast-stream and notDetermined guarantees, and
/// on requestPermission being the *only* member that throws.
void main() {
  const service = UnsupportedPushNotificationService();

  group('UnsupportedPushNotificationService', () {
    test('is a PushNotificationService and const-constructible', () {
      expect(service, isA<PushNotificationService>());
      expect(
        identical(
          const UnsupportedPushNotificationService(),
          const UnsupportedPushNotificationService(),
        ),
        isTrue,
        reason: 'const canonicalization — registration allocates nothing',
      );
    });

    test('isPlatformSupported is false', () {
      expect(service.isPlatformSupported, isFalse);
    });

    test('permissionStatus resolves to notDetermined — nothing was ever '
        'asked', () async {
      await expectLater(
        service.permissionStatus,
        completion(PushPermissionStatus.notDetermined),
      );
    });

    test('requestPermission fails the returned Future with '
        'UnsupportedError — a loud "not yet" for an ungated call, never '
        'a synchronous throw', () async {
      late final Future<PushPermissionStatus> future;

      // The call itself must not throw: the error belongs on the
      // Future so catchError/onError handlers and unawaited callers
      // see it (Effective Dart).
      expect(() => future = service.requestPermission(), returnsNormally);
      await expectLater(future, throwsUnsupportedError);
    });

    group('watchIncoming', () {
      test('emits nothing and closes', () async {
        await expectLater(service.watchIncoming(), emitsDone);
      });

      test('is a broadcast stream — UI may subscribe unconditionally '
          'and repeatedly', () async {
        final stream = service.watchIncoming();

        expect(stream.isBroadcast, isTrue);
        // Listen to the SAME instance twice: a regression to a
        // single-subscription stream would throw StateError on the
        // second listen. (Two separate instances would not catch it —
        // even single-subscription empty streams allow one listen
        // each.)
        await expectLater(stream, emitsDone);
        await expectLater(stream, emitsDone);
      });

      test('never throws', () {
        expect(service.watchIncoming, returnsNormally);
      });
    });
  });
}
