import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

/// #135 shell wiring: the auth gate listener drives the [UserSessionScope]
/// resolved from the active server's container — activate on any transition
/// into authenticated, deactivate on any transition out — and tolerates a
/// container without the seam (web until #137). Sign-out lives in the home
/// navigation drawer (#129): open it with the menu icon first.

/// Records every [UserSessionScope] call in order so the tests can assert
/// the shell drives the seam symmetrically with the auth transitions.
class _RecordingUserSessionScope implements UserSessionScope {
  final calls = <String>[];
  String? _activeUserId;

  @override
  String? get activeUserId => _activeUserId;

  @override
  Future<void> activate(String userId) async {
    calls.add('activate:$userId');
    _activeUserId = userId;
  }

  @override
  Future<void> deactivate() async {
    calls.add('deactivate');
    _activeUserId = null;
  }
}

/// A seam that always fails: activation failure must sign the user out
/// (never strand an authenticated session without services), and
/// deactivation failure must be logged without breaking the sign-out
/// flow (#135 review).
class _ThrowingUserSessionScope implements UserSessionScope {
  @override
  String? get activeUserId => null;

  @override
  Future<void> activate(String userId) async =>
      throw StateError('activation boom');

  @override
  Future<void> deactivate() async => throw StateError('deactivation boom');
}

/// A seam whose [deactivate] completes only when the test releases it,
/// proving the gate routes away *before* the scope pop finishes — no live
/// home widget over disposed repositories (#135 review).
class _GatedUserSessionScope implements UserSessionScope {
  final deactivateGate = Completer<void>();
  var deactivateStarted = false;

  @override
  String? get activeUserId => null;

  @override
  Future<void> activate(String userId) async {}

  @override
  Future<void> deactivate() {
    deactivateStarted = true;
    return deactivateGate.future;
  }
}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

Household _household(String id) => Household(
  id: id,
  name: 'Sunday Crew',
  createdAt: DateTime.utc(2024),
  updatedAt: DateTime.utc(2024),
);

/// Counts the passes the shell's trigger asks for.
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

void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  AppBootstrapCubit buildCubit(
    FakeAuthRepository repo, {
    UserSessionScope? sessionScope,
  }) => AppBootstrapCubit(
    platformBootstrap: FakePlatformBootstrap(
      activeServerScope: FakeActiveServerScope(
        buildActiveServer(repo, userSessionScope: sessionScope),
      ),
    ),
    hydratedStorageInitializer: noopHydrated,
  );

  /// Sign-out lives in the navigation drawer (#129).
  Future<void> signOutFromDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
  }

  testWidgets('a restored session activates the user-session scope for the '
      'session user before home renders', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final sessionScope = _RecordingUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(sessionScope.calls, ['activate:u1']);
    expect(sessionScope.activeUserId, 'u1');
  });

  testWidgets('sign-out deactivates the user-session scope', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final sessionScope = _RecordingUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(sessionScope.calls, ['activate:u1']);

    await signOutFromDrawer(tester);

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(sessionScope.calls, ['activate:u1', 'deactivate']);
    expect(sessionScope.activeUserId, isNull);
  });

  testWidgets('the no-session startup path only issues an idempotent '
      'deactivate', (tester) async {
    final repo = FakeAuthRepository(); // no session
    final sessionScope = _RecordingUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    // The unauthenticated startup transition drives a deactivate; the seam
    // contract makes it a harmless no-op. No activation may occur.
    expect(sessionScope.calls, isNot(contains(startsWith('activate:'))));
  });

  testWidgets('a container without a UserSessionScope keeps the auth flow '
      'working (web until #137)', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final cubit = buildCubit(repo); // seam not registered
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    await signOutFromDrawer(tester);

    expect(find.byType(AuthScreen), findsOneWidget);
  });

  testWidgets('a failed activation signs the user out instead of stranding '
      'an authenticated session without services', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final cubit = buildCubit(repo, sessionScope: _ThrowingUserSessionScope());
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    // Activation threw → the gate never advanced; the dispatched sign-out
    // converged the session to unauthenticated. The deactivation on that
    // sign-out transition also threw and was logged — the flow survives
    // both.
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(AuthScreen), findsOneWidget);
  });

  testWidgets('sign-out routes away before the scope pop completes — no '
      'live home widget over disposed repositories', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final sessionScope = _GatedUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    await signOutFromDrawer(tester);

    // The pop is still held open by the gate, yet home is already gone.
    expect(sessionScope.deactivateStarted, isTrue);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(AuthScreen), findsOneWidget);

    sessionScope.deactivateGate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AuthScreen), findsOneWidget);
  });

  group('the #302 re-hydrate trigger', () {
    testWidgets('an app resume during an active session asks the session '
        'rehydrator for a pass', (tester) async {
      final repo = FakeAuthRepository(initialSession: sampleSession());
      final rehydrator = _SpyRehydrator();
      final cubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(
          activeServerScope: FakeActiveServerScope(
            buildActiveServer(repo, sessionRehydrator: rehydrator),
          ),
        ),
        hydratedStorageInitializer: noopHydrated,
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
      await cubit.initialize();
      await tester.pumpAndSettle();
      expect(rehydrator.passes, isZero, reason: 'mounting is not a trigger');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(rehydrator.passes, equals(1));
    });

    testWidgets('keeps triggering after the app navigates to a route outside '
        'the auth shell', (tester) async {
      // The household list and detail are top-level routes, NOT children of
      // the auth ShellRoute — and the list is the screen showing "couldn't
      // refresh". A trigger mounted inside that shell would be unmounted
      // here, so the one screen that needs the re-hydrate would never get
      // one. It lives above the router for this reason.
      final repo = FakeAuthRepository(initialSession: sampleSession());
      final rehydrator = _SpyRehydrator();
      final households = _MockHouseholdRepository();
      when(
        households.watchHouseholds,
      ).thenAnswer((_) => Stream<List<Household>>.value([_household('h-1')]));
      final cubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(
          activeServerScope: FakeActiveServerScope(
            buildActiveServer(
              repo,
              householdRepository: households,
              sessionRehydrator: rehydrator,
            ),
          ),
        ),
        hydratedStorageInitializer: noopHydrated,
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
      await cubit.initialize();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HomeScreen.entryKey('households')));
      await tester.pumpAndSettle();
      expect(find.byType(HouseholdListScreen), findsOneWidget);

      // The invariant, stated structurally rather than by walking to a
      // route that drops the shell: the trigger is an ANCESTOR of the
      // router's Navigator. Mounted inside the auth ShellRoute it would be
      // a descendant, and every `go` to a top-level route — the detail
      // screen's own back affordance, a restored route, a deep link —
      // would unmount it for the rest of the session.
      expect(
        find.ancestor(
          of: find.byType(Navigator).last,
          matching: find.byType(SessionRehydrateTrigger),
        ),
        findsOneWidget,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(rehydrator.passes, equals(1));
    });

    testWidgets('a composition with no rehydrator registered signs in '
        'normally', (tester) async {
      // Web registers no session scope (#137), and a resume there must not
      // fault the shell.
      final repo = FakeAuthRepository(initialSession: sampleSession());
      final cubit = buildCubit(repo);
      addTearDown(cubit.close);

      await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
      await cubit.initialize();
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
