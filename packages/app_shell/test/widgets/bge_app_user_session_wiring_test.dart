import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:observability/observability.dart';

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

/// A seam whose [activate] completes only when the test releases it — the
/// window an auth loss has to land in to be raced against the bootstrap
/// gate (#176).
///
/// Serialized on one chain, like every real [UserSessionScope]
/// (`ContainerUserSessionScope`, `ServerContextImpl`): a [deactivate] the
/// unauthenticated listener queues while [activate] is parked must run
/// *behind* it, which is exactly what the shell relies on when it declines
/// to deactivate on the stale-auth path. A fake that let the two interleave
/// would end the test with a live scope for a signed-out user and never say
/// so.
class _GatedActivateUserSessionScope implements UserSessionScope {
  final activateGate = Completer<void>();
  final calls = <String>[];
  var activateStarted = false;

  Future<void> _ops = Future<void>.value();
  String? _activeUserId;

  @override
  String? get activeUserId => _activeUserId;

  @override
  Future<void> activate(String userId) => _enqueue(() async {
    activateStarted = true;
    calls.add('activate:$userId');
    await activateGate.future;
    _activeUserId = userId;
  });

  @override
  Future<void> deactivate() => _enqueue(() async {
    calls.add('deactivate');
    _activeUserId = null;
  });

  Future<void> _enqueue(Future<void> Function() op) {
    final result = _ops.then((_) => op());
    _ops = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// A seam whose [deactivate] completes only when the test releases it,
/// proving the gate routes away *before* the scope pop finishes — no live
/// home widget over disposed repositories (#135 review).
class _GatedUserSessionScope implements UserSessionScope {
  final deactivateGate = Completer<void>();
  var deactivateStarted = false;
  String? _activeUserId;

  // Reported truthfully, like every real implementation: the shell reads it
  // back after activation to confirm the scope it asked for is the one that
  // is live before advancing the gate (#176). A fake hardcoding null here
  // would keep this test on the auth screen and never say why.
  @override
  String? get activeUserId => _activeUserId;

  @override
  Future<void> activate(String userId) async => _activeUserId = userId;

  @override
  Future<void> deactivate() {
    deactivateStarted = true;
    _activeUserId = null;
    return deactivateGate.future;
  }
}

/// An [ActiveServerScope] the test can switch, so a server change can land
/// *during* a user-session activation.
///
/// The shell keys the auth bloc on `serverId`, so a switch disposes the
/// bloc the in-flight handler captured — after which that bloc still
/// answers `state` with the session it last emitted (#176).
class _SwitchableActiveServerScope implements ActiveServerScope {
  _SwitchableActiveServerScope(this._active);

  ActiveServer _active;
  final _controller = StreamController<ActiveServer?>.broadcast();

  @override
  ActiveServer? get active => _active;

  @override
  Stream<ActiveServer?> watchActive() => Stream.multi((controller) {
    controller.add(_active);
    final sub = _controller.stream.listen(
      controller.add,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  void switchTo(ActiveServer next) {
    _active = next;
    _controller.add(next);
  }
}

/// A repository whose [signIn] never answers, so the bloc parks in
/// [AuthLoading] — a state the shell's auth listener deliberately ignores,
/// and therefore one that queues no session-scope teardown.
class _HangingSignInAuthRepository extends FakeAuthRepository {
  _HangingSignInAuthRepository({super.initialSession});

  @override
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) => Completer<AuthResponse>().future;
}

/// Counts the sign-outs the shell drives through the repository.
class _SignOutCountingAuthRepository extends FakeAuthRepository {
  _SignOutCountingAuthRepository({super.initialSession});

  int signOutCalls = 0;

  @override
  Future<void> signOut() {
    signOutCalls++;
    return super.signOut();
  }
}

/// A seam whose [activate] parks until released and then **fails** — the
/// recovery leg, raced against an auth loss that already converged.
class _GatedFailingUserSessionScope implements UserSessionScope {
  final activateGate = Completer<void>();
  final calls = <String>[];
  var activateStarted = false;

  Future<void> _ops = Future<void>.value();

  @override
  String? get activeUserId => null;

  @override
  Future<void> activate(String userId) => _enqueue(() async {
    activateStarted = true;
    calls.add('activate:$userId');
    await activateGate.future;
    throw StateError('activation boom');
  });

  @override
  Future<void> deactivate() => _enqueue(() async => calls.add('deactivate'));

  Future<void> _enqueue(Future<void> Function() op) {
    final result = _ops.then((_) => op());
    _ops = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

Household _household(String id) => Household(
  id: id,
  name: 'Sunday Crew',
  createdAt: DateTime.utc(2024),
  updatedAt: DateTime.utc(2024),
);

/// Counts the queued-feedback drains the gate callback would trigger.
///
/// The stale-auth path must not reach the drain at all: it posts queued
/// reports to a server that has just disowned this session (#176).
class _CountingFeedbackService implements FeedbackService {
  int drainCalls = 0;

  @override
  Future<int> drainPending() async {
    drainCalls++;
    return 0;
  }

  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? clientRequestId,
  }) => throw UnimplementedError();

  @override
  Future<FeedbackSubmitResult> submit(FeedbackReport report) =>
      throw UnimplementedError();
}

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
    FeedbackService? feedbackService,
  }) => AppBootstrapCubit(
    platformBootstrap: FakePlatformBootstrap(
      activeServerScope: FakeActiveServerScope(
        buildActiveServer(repo, userSessionScope: sessionScope),
      ),
    ),
    hydratedStorageInitializer: noopHydrated,
    feedbackService: feedbackService,
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

  testWidgets('an auth loss during session-scope activation keeps the gate '
      'on the auth leg instead of routing to home', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final sessionScope = _GatedActivateUserSessionScope();
    final feedback = _CountingFeedbackService();
    final cubit = buildCubit(
      repo,
      sessionScope: sessionScope,
      feedbackService: feedback,
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pump();
    expect(
      sessionScope.activateStarted,
      isTrue,
      reason: 'activation must be parked inside the gate',
    );

    // The repository disowns the session mid-activation — #98/#141
    // revalidation rejecting the restored token.
    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pump();

    sessionScope.activateGate.complete();
    await tester.pumpAndSettle();

    expect(cubit.state, const AppBootstrapNeedsAuth());
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(
      feedback.drainCalls,
      0,
      reason: 'the stale path must not drain against a disowned session',
    );
    // The reason the stale path deactivates nothing itself: the
    // unauthenticated listener already queued one, and the scope ran it
    // behind the activation it was racing.
    expect(sessionScope.calls, ['activate:u1', 'deactivate']);
    expect(sessionScope.activeUserId, isNull);
  });

  testWidgets('a sign-out and sign-back-in during activation leaves the gate '
      'to the handler whose scope is actually live', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final sessionScope = _GatedActivateUserSessionScope();
    final feedback = _CountingFeedbackService();
    final cubit = buildCubit(
      repo,
      sessionScope: sessionScope,
      feedbackService: feedback,
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pump();
    expect(sessionScope.activateStarted, isTrue);

    // Rejected, then signed straight back in as the SAME user while the
    // first activation is still parked. Both a deactivate and a second
    // activate queue behind it, so when the first handler resumes the auth
    // state reads "authenticated, same user" while its own scope has been
    // torn down and not yet rebuilt — a user-id comparison alone cannot
    // tell this apart from the ordinary happy path (#176).
    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pump();
    repo.emitAuthState(AuthStateAuthenticated(session: sampleSession()));
    await tester.pump();

    sessionScope.activateGate.complete();
    await tester.pumpAndSettle();

    expect(sessionScope.calls, ['activate:u1', 'deactivate', 'activate:u1']);
    expect(sessionScope.activeUserId, 'u1');
    // The system still converges — the second handler owns the gate.
    expect(find.byType(HomeScreen), findsOneWidget);
    // ...and it got there once. The drain fires on every invocation that
    // reaches the callback, so this counts the handlers that advanced the
    // gate: two means the stale one advanced it too, on the strength of a
    // session whose scope no longer existed.
    expect(
      feedback.drainCalls,
      1,
      reason: 'only the handler whose activation is live may advance the gate',
    );
  });

  testWidgets('a server switch during activation leaves the gate alone — the '
      'disposed bloc still reports the departed session', (tester) async {
    final repoA = FakeAuthRepository(initialSession: sampleSession());
    final sessionScope = _GatedActivateUserSessionScope();
    final feedback = _CountingFeedbackService();

    final scope = _SwitchableActiveServerScope(
      buildActiveServer(repoA, userSessionScope: sessionScope),
    );
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(activeServerScope: scope),
      hydratedStorageInitializer: noopHydrated,
      feedbackService: feedback,
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pump();
    expect(sessionScope.activateStarted, isTrue);

    // The user switches servers while the first server's activation is
    // parked. The keyed BlocProvider disposes server A's bloc; server B
    // has no session.
    scope.switchTo(
      buildActiveServer(FakeAuthRepository(), serverId: 'server-uuid-2'),
    );
    await tester.pumpAndSettle();

    sessionScope.activateGate.complete();
    await tester.pumpAndSettle();

    // Server A's scope is still live for u1 — nothing deactivated it — and
    // A's bloc still answers AuthAuthenticated(u1) *and* isClosed == false,
    // because `AuthBloc.close` awaits its subscriptions and the unmount
    // has not finished landing. Both of the other clauses read "fine";
    // only the active-server check stands this handler down.
    expect(sessionScope.activeUserId, 'u1');
    expect(cubit.state, const AppBootstrapNeedsAuth());
    expect(find.byType(HomeScreen), findsNothing);
    expect(
      feedback.drainCalls,
      0,
      reason: 'the departed server\'s handler must not advance the gate',
    );
  });

  testWidgets('a fresh sign-in attempt during activation keeps the gate on '
      'the auth leg — AuthLoading queues no teardown', (tester) async {
    final repo = _HangingSignInAuthRepository(initialSession: sampleSession());
    final sessionScope = _GatedActivateUserSessionScope();
    final feedback = _CountingFeedbackService();
    final cubit = buildCubit(
      repo,
      sessionScope: sessionScope,
      feedbackService: feedback,
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    // Fixed pumps throughout: the auth screen animates a progress
    // indicator, so pumpAndSettle never returns on this leg.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sessionScope.activateStarted, isTrue);

    // The auth screen is on display precisely *because* the gate is still
    // behind this activation, so the user can start a sign-in from it. The
    // bloc leaves the authenticated state for AuthLoading, which the
    // listener ignores — no deactivate is queued, so the session scope
    // stays live for u1 and only the auth predicate can catch this.
    // Anchored on the trigger rather than the auth screen: it sits
    // directly under the BlocProvider and is present for the whole auth
    // leg, screen transitions included.
    BlocProvider.of<AuthBloc>(
      tester.element(find.byType(AuthLifecycleRevalidationTrigger)),
    ).add(const AuthSignInRequested(email: 'u1@example.com', password: 'pw'));
    await tester.pump();

    sessionScope.activateGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(sessionScope.activeUserId, 'u1');
    expect(cubit.state, const AppBootstrapNeedsAuth());
    expect(find.byType(HomeScreen), findsNothing);
    expect(feedback.drainCalls, 0);
  });

  testWidgets('an activation that fails after auth already ended drives no '
      'second sign-out', (tester) async {
    final repo = _SignOutCountingAuthRepository(
      initialSession: sampleSession(),
    );
    final sessionScope = _GatedFailingUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pump();
    expect(sessionScope.activateStarted, isTrue);

    // The token is rejected while the activation is parked: the
    // unauthenticated listener has already converged the system.
    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pump();

    sessionScope.activateGate.complete();
    await tester.pumpAndSettle();

    // The recovery sign-out exists to stop an authenticated session being
    // stranded without services. There is no such session left to strand,
    // and dispatching anyway costs a network round trip plus a second
    // onSignedOut/deactivate pair for a session the server already
    // rejected (#176).
    expect(repo.signOutCalls, 0);
    expect(sessionScope.calls, ['activate:u1', 'deactivate']);
    expect(cubit.state, const AppBootstrapNeedsAuth());
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

      // A delta rather than a total: this test walks to the household list,
      // and entering it is itself a trigger now (#300 D13). What is being
      // pinned here is that the *resume* still reaches the rehydrator from
      // outside the auth shell, which the absolute count would conflate.
      final before = rehydrator.passes;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(rehydrator.passes - before, equals(1));
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
