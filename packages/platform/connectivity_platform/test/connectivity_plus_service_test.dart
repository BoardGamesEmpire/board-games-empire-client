import 'dart:async';

import 'package:connectivity_platform/connectivity_platform.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';

/// Contract spec for [ConnectivityPlusService] (#9).
///
/// Drives the impl through the injectable seams ([connectivityChanges],
/// [connectivityCheck]) with synthetic events — `connectivity_plus`
/// itself is never mocked.
void main() {
  late StreamController<List<ConnectivityResult>> changes;

  setUp(() {
    changes = StreamController<List<ConnectivityResult>>.broadcast();
  });

  tearDown(() async {
    await changes.close();
  });

  /// A check that never completes: pins the service in its
  /// pre-correction window so the seed is observable.
  Future<List<ConnectivityResult>> pendingCheck() =>
      Completer<List<ConnectivityResult>>().future;

  ConnectivityPlusService build({
    Future<List<ConnectivityResult>> Function()? check,
  }) => ConnectivityPlusService(
    connectivityChanges: changes.stream,
    connectivityCheck: check ?? pendingCheck,
  );

  group('optimistic seed', () {
    test('current is online immediately at construction', () {
      final service = build();
      addTearDown(service.dispose);

      expect(service.current, ConnectivityState.online);
    });

    test('watch replays online to a subscriber before any events', () async {
      final service = build();
      addTearDown(service.dispose);

      expect(await service.watch().first, ConnectivityState.online);
    });
  });

  group('eager check correction', () {
    test('check resolving [none] corrects current to offline', () async {
      final service = build(check: () async => [ConnectivityResult.none]);
      addTearDown(service.dispose);

      await pumpEventQueue();

      expect(service.current, ConnectivityState.offline);
    });

    test('check resolving a live transport keeps current online', () async {
      final service = build(check: () async => [ConnectivityResult.wifi]);
      addTearDown(service.dispose);

      await pumpEventQueue();

      expect(service.current, ConnectivityState.online);
    });

    test('a throwing check is swallowed and the seed stands', () async {
      final service = build(
        check: () async => throw StateError('platform unavailable'),
      );
      addTearDown(service.dispose);

      await pumpEventQueue();

      expect(service.current, ConnectivityState.online);
    });

    test(
      'a stale check result does not override a newer change event',
      () async {
        final gate = Completer<List<ConnectivityResult>>();
        final service = build(check: () => gate.future);
        addTearDown(service.dispose);

        // Event arrives first: offline.
        changes.add([ConnectivityResult.none]);
        await pumpEventQueue();
        expect(service.current, ConnectivityState.offline);

        // Slow check resolves later claiming online; it is stale.
        gate.complete([ConnectivityResult.wifi]);
        await pumpEventQueue();

        expect(service.current, ConnectivityState.offline);
      },
    );
  });

  group('coarse mapping', () {
    Future<void> expectMapping(
      List<ConnectivityResult> event,
      ConnectivityState expected,
    ) async {
      final service = build();
      addTearDown(service.dispose);

      changes.add(event);
      await pumpEventQueue();

      expect(service.current, expected);
    }

    test('[none] maps to offline', () async {
      await expectMapping([ConnectivityResult.none], ConnectivityState.offline);
    });

    test('empty list maps to offline (defensive)', () async {
      await expectMapping(const [], ConnectivityState.offline);
    });

    test('[wifi] maps to online', () async {
      await expectMapping([ConnectivityResult.wifi], ConnectivityState.online);
    });

    test('[mobile] maps to online', () async {
      await expectMapping([
        ConnectivityResult.mobile,
      ], ConnectivityState.online);
    });

    test('any non-none transport in a mixed list maps to online', () async {
      await expectMapping([
        ConnectivityResult.none,
        ConnectivityResult.vpn,
      ], ConnectivityState.online);
    });
  });

  group('watch semantics', () {
    test('emits on each coarse-state change', () async {
      final service = build();
      addTearDown(service.dispose);

      final seen = <ConnectivityState>[];
      final sub = service.watch().listen(seen.add);
      addTearDown(sub.cancel);

      changes
        ..add([ConnectivityResult.none])
        ..add([ConnectivityResult.wifi]);
      await pumpEventQueue();

      expect(seen, [
        ConnectivityState.online, // replay of seed
        ConnectivityState.offline,
        ConnectivityState.online,
      ]);
    });

    test('deduplicates consecutive identical coarse states', () async {
      final service = build();
      addTearDown(service.dispose);

      final seen = <ConnectivityState>[];
      final sub = service.watch().listen(seen.add);
      addTearDown(sub.cancel);

      // wifi → ethernet: transport changed, coarse state did not.
      changes
        ..add([ConnectivityResult.wifi])
        ..add([ConnectivityResult.ethernet]);
      await pumpEventQueue();

      expect(seen, [ConnectivityState.online]);
    });

    test(
      'late subscriber receives only the latest state, not history',
      () async {
        final service = build();
        addTearDown(service.dispose);

        changes
          ..add([ConnectivityResult.none])
          ..add([ConnectivityResult.wifi])
          ..add([ConnectivityResult.none]);
        await pumpEventQueue();

        expect(await service.watch().first, ConnectivityState.offline);
      },
    );

    test('supports multiple concurrent subscribers', () async {
      final service = build();
      addTearDown(service.dispose);

      final a = <ConnectivityState>[];
      final b = <ConnectivityState>[];
      final subA = service.watch().listen(a.add);
      final subB = service.watch().listen(b.add);
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);

      changes.add([ConnectivityResult.none]);
      await pumpEventQueue();

      expect(a, [ConnectivityState.online, ConnectivityState.offline]);
      expect(b, [ConnectivityState.online, ConnectivityState.offline]);
    });
  });

  group('lifecycle', () {
    test('dispose completes watch streams', () async {
      final service = build();

      final done = Completer<void>();
      final sub = service.watch().listen(null, onDone: done.complete);
      addTearDown(sub.cancel);

      await service.dispose();

      await expectLater(done.future, completes);
    });

    test('dispose cancels the source subscription', () async {
      final onCancel = Completer<void>();
      final source = StreamController<List<ConnectivityResult>>(
        onCancel: onCancel.complete,
      );
      addTearDown(source.close);

      final service = ConnectivityPlusService(
        connectivityChanges: source.stream,
        connectivityCheck: pendingCheck,
      );

      await service.dispose();

      await expectLater(onCancel.future, completes);
    });

    test('events after dispose do not change current', () async {
      final service = build();
      await service.dispose();

      changes.add([ConnectivityResult.none]);
      await pumpEventQueue();

      expect(service.current, ConnectivityState.online);
    });

    test('dispose is idempotent', () async {
      final service = build();

      await service.dispose();
      await expectLater(service.dispose(), completes);
    });

    test('onDispose (Disposable) delegates to dispose — watch streams '
        'complete', () async {
      final service = build();

      final done = Completer<void>();
      final sub = service.watch().listen(null, onDone: done.complete);
      addTearDown(sub.cancel);

      await service.onDispose();

      await expectLater(done.future, completes);
      expect(service, isA<Disposable>());
    });
  });

  test('is a ConnectivityService', () {
    final service = build();
    addTearDown(service.dispose);

    expect(service, isA<ConnectivityService>());
  });
}
