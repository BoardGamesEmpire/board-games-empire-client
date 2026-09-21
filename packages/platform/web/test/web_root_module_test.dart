// Runs on the VM: this suite exercises the platform-neutral half of the
// composition root (`web.dart`). Tagged explicitly since #288 added a
// browser-only suite beside it — `melos run test:web` runs Chrome over the
// whole package, and a widget test has no business being re-run there.
@TestOn('vm')
library;

import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:web_platform/web.dart';

/// Tests for `registerWebRootModule`'s registrations: the resolved
/// `BuildInfo` read on web from Flutter's generated `version.json`
/// (#35), the in-memory `FeedbackSink` stand-in (#69/#63), the lazy
/// device-global `ConnectivityService` (#9), and the
/// `PushNotificationService` null object (#15) — same injected-seam
/// shapes as the native module.
class _StubBuildInfoReader implements BuildInfoReader {
  const _StubBuildInfoReader(this._info);
  final BuildInfo _info;

  @override
  Future<BuildInfo> read() async => _info;
}

class _FakeConnectivityService implements ConnectivityService, Disposable {
  bool disposed = false;

  @override
  ConnectivityState get current => ConnectivityState.online;

  @override
  Stream<ConnectivityState> watch() => Stream.value(ConnectivityState.online);

  @override
  Future<void> onDispose() async => disposed = true;
}

const _info = BuildInfo(
  version: '1.2.3',
  buildNumber: '42',
  appName: 'Board Games Empire',
  packageName: 'com.boardgamesempire.app',
);

void main() {
  test('registers the resolved BuildInfo into the container', () async {
    final container = DependencyContainerImpl();
    addTearDown(container.dispose);

    await registerWebRootModule(
      container,
      buildInfoReader: const _StubBuildInfoReader(_info),
    );

    expect(container.get<BuildInfo>(), _info);
  });

  group('FeedbackSink registration (#69, #292)', () {
    test('falls back to the in-memory stand-in when the caller supplies no '
        'durable sink', () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
      );

      expect(container.isRegistered<FeedbackSink>(), isTrue);
      expect(container.get<FeedbackSink>(), isA<MemoryFeedbackSink>());
    });

    test(
      'registers the durable sink the composition root supplies (#292) — '
      'this library cannot name its type, so it must not construct one',
      () async {
        final container = DependencyContainerImpl();
        addTearDown(container.dispose);
        final durable = _DisposableSink();

        await registerWebRootModule(
          container,
          buildInfoReader: const _StubBuildInfoReader(_info),
          feedbackSink: Future.value(durable),
        );

        expect(container.get<FeedbackSink>(), same(durable));
      },
    );

    test('overlaps the sink open with the build-info read rather than queueing '
        'them — two bounded platform reads should not stack their worst '
        'cases in front of a blank page', () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);
      final readStarted = Completer<void>();
      final durable = _DisposableSink();

      // The sink resolves only once `read()` has actually been entered, so the
      // two orderings have different *outcomes* rather than merely different
      // timings: a module that awaited the sink first would never start the
      // read, and would wait here forever.
      //
      // That distinction is the point. Gating on elapsed time instead — the
      // first version of this test — passes on a serialized implementation,
      // because both orderings finish at the same wall-clock moment when the
      // slower operation is the one being waited on.
      await registerWebRootModule(
        container,
        buildInfoReader: _SignallingBuildInfoReader(_info, readStarted),
        feedbackSink: readStarted.future.then((_) => durable),
      ).timeout(
        const Duration(seconds: 2),
        onTimeout: () =>
            fail('the module awaited the sink before starting its own read'),
      );

      expect(container.get<FeedbackSink>(), same(durable));
    });

    test('disposes a sink that holds a connection when the root container '
        'tears down', () async {
      final container = DependencyContainerImpl();
      final durable = _DisposableSink();

      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        feedbackSink: Future.value(durable),
      );
      await container.dispose();

      expect(durable.disposals, 1);
    });

    test('disposing a stand-in that holds nothing is not an error — the '
        'module does not know which kind it got', () async {
      final container = DependencyContainerImpl();

      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
      );

      await expectLater(container.dispose(), completes);
    });
  });

  group('ConnectivityService registration (#9)', () {
    test('registers lazily — no construction at registration, singleton '
        'on resolution', () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);
      var constructions = 0;

      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        connectivityFactory: () {
          constructions++;
          return _FakeConnectivityService();
        },
      );

      expect(container.isRegistered<ConnectivityService>(), isTrue);
      expect(
        constructions,
        0,
        reason:
            'the plugin-touching constructor must not run at '
            'registration (defensive-module contract)',
      );

      final first = container.get<ConnectivityService>();
      final second = container.get<ConnectivityService>();

      expect(constructions, 1);
      expect(second, same(first));
    });

    test('container dispose drives Disposable.onDispose on the resolved '
        'service', () async {
      final container = DependencyContainerImpl();
      final service = _FakeConnectivityService();

      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        connectivityFactory: () => service,
      );

      container.get<ConnectivityService>();
      await container.dispose();

      expect(service.disposed, isTrue);
    });

    test('an unresolved lazy registration is not constructed just to be '
        'disposed', () async {
      final container = DependencyContainerImpl();
      var constructions = 0;

      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        connectivityFactory: () {
          constructions++;
          return _FakeConnectivityService();
        },
      );

      await container.dispose();

      expect(constructions, 0);
    });

    test('registers VersionNegotiator (pure; needed for #87 refresh-time '
        're-check on web)', () async {
      final container = DependencyContainerImpl();

      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        connectivityFactory: _FakeConnectivityService.new,
      );

      expect(container.isRegistered<VersionNegotiator>(), isTrue);
      expect(container.get<VersionNegotiator>(), isA<VersionNegotiatorImpl>());
    });

    test('does not register WellKnownClient — web is same-origin, '
        '/server-add is unreachable, and no web impl exists', () async {
      final container = DependencyContainerImpl();

      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        connectivityFactory: _FakeConnectivityService.new,
      );

      expect(container.isRegistered<WellKnownClient>(), isFalse);
    });
  });

  test('registers the PushNotificationService null object (#15) — '
      'possibly permanent on web (#113 decides)', () async {
    final container = DependencyContainerImpl();
    addTearDown(container.dispose);

    await registerWebRootModule(
      container,
      buildInfoReader: const _StubBuildInfoReader(_info),
      connectivityFactory: _FakeConnectivityService.new,
    );

    expect(container.isRegistered<PushNotificationService>(), isTrue);

    final service = container.get<PushNotificationService>();
    expect(service, isA<UnsupportedPushNotificationService>());
    expect(service.isPlatformSupported, isFalse);
  });
}

/// Stands in for `IndexedDbFeedbackSink` here: the real one reaches
/// `dart:js_interop` and cannot be named on the VM, and what this suite is
/// asserting is the module's routing and disposal, not the store.
class _DisposableSink implements FeedbackSink, Disposable {
  int disposals = 0;

  @override
  Future<void> onDispose() async => disposals++;

  @override
  Future<void> persist(QueuedFeedbackReport record) async {}

  @override
  Future<void> update(QueuedFeedbackReport record) async {}

  @override
  Future<List<QueuedFeedbackReport>> pending() async => const [];

  @override
  Future<void> remove(String storageKey) async {}
}

/// A reader that announces when it has been entered, so a suite can make the
/// sink's readiness depend on the read having started.
class _SignallingBuildInfoReader implements BuildInfoReader {
  const _SignallingBuildInfoReader(this._info, this._started);

  final BuildInfo _info;
  final Completer<void> _started;

  @override
  Future<BuildInfo> read() async {
    if (!_started.isCompleted) _started.complete();
    return _info;
  }
}
