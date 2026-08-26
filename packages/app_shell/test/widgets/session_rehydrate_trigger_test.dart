import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:di/di.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';

import '../support/active_server_fakes.dart';

/// A connectivity service whose stream the test drives, with the replay
/// semantics the real one has: [watch] hands every subscriber the current
/// state before any change.
class _FakeConnectivityService implements ConnectivityService {
  final _changes = StreamController<ConnectivityState>.broadcast();
  ConnectivityState _current = ConnectivityState.online;

  @override
  ConnectivityState get current => _current;

  @override
  Stream<ConnectivityState> watch() async* {
    yield _current;
    yield* _changes.stream;
  }

  void emit(ConnectivityState state) {
    _current = state;
    _changes.add(state);
  }

  Future<void> dispose() => _changes.close();
}

/// A container that refuses use after disposal, the way the per-server
/// facade does — `DependencyContainerImpl` returns false instead.
class _DisposedContainer implements DependencyContainer {
  @override
  bool isRegistered<T extends Object>() =>
      throw StateError('DependencyContainer has been disposed');

  @override
  T get<T extends Object>() =>
      throw StateError('DependencyContainer has been disposed');

  @override
  void registerFactory<T extends Object>(T Function() factory) {}

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) {}

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) {}

  @override
  Future<void> dispose() async {}
}

/// Counts the passes the trigger asks for.
class _SpyRehydrator implements SessionRehydrator {
  int passes = 0;

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {}

  @override
  Future<void> rehydrateStale() async => passes++;
}

/// A rehydrator that throws **synchronously**, before returning a future.
/// `rehydrateStale` is not an `async` method on the shipped impl, so this
/// is the shape a future one could take — and `catchError` cannot see it.
class _SyncThrowingRehydrator implements SessionRehydrator {
  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {}

  @override
  Future<void> rehydrateStale() => throw StateError('boom');
}

/// A rehydrator that fails, standing in for a seam whose entries throw.
class _ThrowingRehydrator implements SessionRehydrator {
  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {}

  @override
  Future<void> rehydrateStale() async => throw StateError('boom');
}

void main() {
  late DependencyContainerImpl container;
  late _FakeConnectivityService connectivity;
  late _SpyRehydrator rehydrator;

  setUp(() {
    container = DependencyContainerImpl();
    connectivity = _FakeConnectivityService();
    rehydrator = _SpyRehydrator();
  });

  tearDown(() async {
    await connectivity.dispose();
    await container.dispose();
  });

  /// The active-server scope shape the shell hands the trigger.
  ActiveServerScope? Function() scopeOf(DependencyContainer container) {
    final scope = FakeActiveServerScope(
      ActiveServer(
        serverId: 'server-uuid-1',
        displayName: 'My Server',
        identity: serverIdentity(),
        container: container,
      ),
    );
    return () => scope;
  }

  Future<void> pump(
    WidgetTester tester, {
    ConnectivityService? service,
    bool registerRehydrator = true,
    ActiveServerScope? Function()? scopeSource,
  }) async {
    if (registerRehydrator) {
      container.registerSingleton<SessionRehydrator>(rehydrator);
    }
    await tester.pumpWidget(
      SessionRehydrateTrigger(
        scopeSource: scopeSource ?? scopeOf(container),
        connectivity: service ?? connectivity,
        child: const SizedBox.shrink(),
      ),
    );
  }

  group('SessionRehydrateTrigger — the connectivity edge (#302 D1)', () {
    testWidgets('an offline → online transition asks for a pass', (
      tester,
    ) async {
      await pump(tester);

      connectivity.emit(ConnectivityState.offline);
      await tester.pump();
      connectivity.emit(ConnectivityState.online);
      await tester.pump();

      expect(rehydrator.passes, equals(1));
    });

    testWidgets('mounting is not itself a transition', (tester) async {
      // watch() replays the current state to every subscriber. Treating
      // that replay as an edge would re-hydrate on every mount and on
      // every server switch, neither of which is connectivity returning.
      await pump(tester);
      await tester.pump();

      expect(rehydrator.passes, isZero);
    });

    testWidgets('going offline asks for nothing', (tester) async {
      await pump(tester);

      connectivity.emit(ConnectivityState.offline);
      await tester.pump();

      expect(rehydrator.passes, isZero);
    });

    testWidgets('an edge after the trigger unmounts asks for nothing', (
      tester,
    ) async {
      await pump(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      connectivity.emit(ConnectivityState.offline);
      connectivity.emit(ConnectivityState.online);
      await tester.pump();

      expect(rehydrator.passes, isZero);
    });

    testWidgets('a composition without connectivity mounts and does nothing', (
      tester,
    ) async {
      await pump(tester, service: null);
      await tester.pump();

      expect(rehydrator.passes, isZero);
    });
  });

  group('SessionRehydrateTrigger — app resume (#302 D1)', () {
    /// The lifecycle transition the shell's resume trigger listens for.
    Future<void> resume(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }

    testWidgets('a return to the foreground asks for a pass', (tester) async {
      // The connectivity edge cannot see a device suspended offline and
      // resumed online: the service suppresses consecutive duplicate
      // coarse states, and the platform stream can deliver nothing across
      // the boundary (#141 documents the same gap for auth).
      await pump(tester);

      await resume(tester);

      expect(rehydrator.passes, equals(1));
    });

    testWidgets('resume works without a connectivity service', (tester) async {
      await pump(tester, service: null);

      await resume(tester);

      expect(rehydrator.passes, equals(1));
    });

    testWidgets('a resume after unmount asks for nothing', (tester) async {
      await pump(tester);
      await tester.pumpWidget(const SizedBox.shrink());

      await resume(tester);

      expect(rehydrator.passes, isZero);
    });
  });

  group('SessionRehydrateTrigger — no active user session', () {
    testWidgets('an edge with no rehydrator registered does nothing', (
      tester,
    ) async {
      // The registry lives in the user-session scope, so its absence IS
      // "no session is active" (#302 D2) — after sign-out there is
      // nothing to call, with no separate gate to keep in step.
      await pump(tester, registerRehydrator: false);

      connectivity.emit(ConnectivityState.offline);
      await tester.pump();
      connectivity.emit(ConnectivityState.online);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('a resume with no rehydrator registered does nothing', (
      tester,
    ) async {
      await pump(tester, registerRehydrator: false);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('SessionRehydrateTrigger — no server to re-hydrate', () {
    testWidgets('a composition with no active-server scope does nothing', (
      tester,
    ) async {
      // Web has no orchestration (#96), and the scope is null before
      // bootstrap succeeds on every platform.
      await pump(tester, scopeSource: () => null);

      connectivity.emit(ConnectivityState.offline);
      await tester.pump();
      connectivity.emit(ConnectivityState.online);
      await tester.pump();

      expect(rehydrator.passes, isZero);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a container disposed under the trigger does not fault', (
      tester,
    ) async {
      // The per-server container throws from isRegistered once its context
      // is disposed, and this callback can land in the window between that
      // disposal and the shell noticing.
      await pump(
        tester,
        registerRehydrator: false,
        scopeSource: scopeOf(_DisposedContainer()),
      );

      connectivity.emit(ConnectivityState.offline);
      await tester.pump();
      connectivity.emit(ConnectivityState.online);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('SessionRehydrateTrigger — a failing pass', () {
    testWidgets('that throws synchronously does not surface as an unhandled '
        'error', (tester) async {
      container.registerSingleton<SessionRehydrator>(_SyncThrowingRehydrator());
      await tester.pumpWidget(
        SessionRehydrateTrigger(
          scopeSource: scopeOf(container),
          connectivity: connectivity,
          child: const SizedBox.shrink(),
        ),
      );

      connectivity.emit(ConnectivityState.offline);
      await tester.pump();
      connectivity.emit(ConnectivityState.online);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('does not surface as an unhandled error', (tester) async {
      // The pass is fire-and-forget: there is no caller to report to, and
      // an unhandled async error here would raise a crash-report prompt
      // (#34) for a refresh nobody asked for.
      container.registerSingleton<SessionRehydrator>(_ThrowingRehydrator());
      await tester.pumpWidget(
        SessionRehydrateTrigger(
          scopeSource: scopeOf(container),
          connectivity: connectivity,
          child: const SizedBox.shrink(),
        ),
      );

      connectivity.emit(ConnectivityState.offline);
      await tester.pump();
      connectivity.emit(ConnectivityState.online);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('renders its child unchanged', (tester) async {
    container.registerSingleton<SessionRehydrator>(rehydrator);
    await tester.pumpWidget(
      SessionRehydrateTrigger(
        scopeSource: scopeOf(container),
        connectivity: connectivity,
        child: const Text('home', textDirection: TextDirection.ltr),
      ),
    );

    expect(find.text('home'), findsOneWidget);
  });
}
