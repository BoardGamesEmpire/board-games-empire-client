import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

/// #142 shell wiring: a session the user didn't end leaves a notice on the
/// sign-in screen when they have changes waiting; one they ended doesn't.
///
/// The shell records the session's user when it starts and retires them on
/// a deliberate sign-out; the count is the per-server repository's. Its
/// shared-device rules are pinned in drift_storage, so the fake here keeps
/// only the record and the counts.
class _FakeUnsentChangesNotice implements UnsentChangesNoticeRepository {
  _FakeUnsentChangesNotice({this.recorded, Map<String, int>? unsent})
    : unsent = unsent ?? {};

  String? recorded;
  final Map<String, int> unsent;

  /// When set, a record call lands only once this completes, while a count
  /// answers straight away: a database that doesn't run statements in the
  /// order they were issued.
  Completer<void>? holdWrites;

  /// A count that never comes back.
  bool countHangs = false;

  @override
  Future<void> recordSessionStarted(String userId) async {
    await holdWrites?.future;
    recorded = userId;
  }

  @override
  Future<void> recordSignedOut(String userId) async {
    await holdWrites?.future;
    if (recorded == userId) recorded = null;
  }

  @override
  Future<int> unsentChangesCount() async =>
      countHangs ? Completer<int>().future : unsent[recorded] ?? 0;
}

/// Activation always fails, so the shell signs out to recover.
class _ThrowingUserSessionScope implements UserSessionScope {
  @override
  String? get activeUserId => null;

  @override
  Future<void> activate(String userId) async =>
      throw StateError('activation boom');

  @override
  Future<void> deactivate() async {}
}

const _twoWaiting =
    "2 changes haven't reached the server yet. Sign in with the same account "
    'to send them.';

void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  AppBootstrapCubit buildCubit(
    FakeAuthRepository repo,
    UnsentChangesNoticeRepository notice, {
    UserSessionScope? sessionScope,
  }) => AppBootstrapCubit(
    platformBootstrap: FakePlatformBootstrap(
      activeServerScope: FakeActiveServerScope(
        buildActiveServer(
          repo,
          userSessionScope: sessionScope,
          unsentChangesNotice: notice,
        ),
      ),
    ),
    hydratedStorageInitializer: noopHydrated,
  );

  Future<void> startApp(WidgetTester tester, AppBootstrapCubit cubit) async {
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
  }

  /// Sign-out lives in the navigation drawer (#129).
  Future<void> signOutFromDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
  }

  testWidgets('a session the server ends mid-session leaves the notice on '
      'the sign-in screen', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final notice = _FakeUnsentChangesNotice(unsent: {'u1': 2});
    final cubit = buildCubit(repo, notice);
    addTearDown(cubit.close);
    await startApp(tester, cubit);
    expect(find.byType(HomeScreen), findsOneWidget);

    // An interceptor or drain 401, as the repository reports it.
    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.text(_twoWaiting), findsOneWidget);
  });

  testWidgets('a deliberate sign-out leaves no notice', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final notice = _FakeUnsentChangesNotice(unsent: {'u1': 2});
    final cubit = buildCubit(repo, notice);
    addTearDown(cubit.close);
    await startApp(tester, cubit);

    await signOutFromDrawer(tester);

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byKey(AuthScreen.unsentChangesNoticeKey), findsNothing);
  });

  testWidgets('the sign-out the app runs after a failed scope activation '
      'leaves the notice — the user did not ask for it', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final notice = _FakeUnsentChangesNotice(unsent: {'u1': 2});
    final cubit = buildCubit(
      repo,
      notice,
      sessionScope: _ThrowingUserSessionScope(),
    );
    addTearDown(cubit.close);
    await startApp(tester, cubit);

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.text(_twoWaiting), findsOneWidget);
  });

  testWidgets('and the same after a sign-in from the sign-in screen, when '
      'the activation fails before the next frame', (tester) async {
    // u1 signed out on purpose earlier, so the screen opens with no notice.
    final repo = FakeAuthRepository();
    final notice = _FakeUnsentChangesNotice(unsent: {'u1': 2});
    final cubit = buildCubit(
      repo,
      notice,
      sessionScope: _ThrowingUserSessionScope(),
    );
    addTearDown(cubit.close);
    await startApp(tester, cubit);
    expect(find.byKey(AuthScreen.unsentChangesNoticeKey), findsNothing);

    // Dispatched rather than typed, so nothing pumps a frame between the
    // session starting and the recovery ending it: the gate never shows its
    // splash, and the sign-in screen stays up throughout.
    BlocProvider.of<AuthBloc>(
      tester.element(find.byType(AuthLifecycleRevalidationTrigger)),
    ).add(const AuthSignInRequested(email: 'u1@example.com', password: 'pw'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.text(_twoWaiting), findsOneWidget);
  });

  testWidgets('a session rejected at the next launch leaves the notice, '
      'though nothing in memory knows whose it was', (tester) async {
    // Recorded by the previous run's session start; the server has since
    // rejected the stored session, which this fake models as no session.
    final repo = FakeAuthRepository();
    final notice = _FakeUnsentChangesNotice(recorded: 'u1', unsent: {'u1': 2});
    final cubit = buildCubit(repo, notice);
    addTearDown(cubit.close);

    await startApp(tester, cubit);

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.text(_twoWaiting), findsOneWidget);
  });

  testWidgets('no notice when the lost session had nothing waiting', (
    tester,
  ) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final notice = _FakeUnsentChangesNotice();
    final cubit = buildCubit(repo, notice);
    addTearDown(cubit.close);
    await startApp(tester, cubit);

    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byKey(AuthScreen.unsentChangesNoticeKey), findsNothing);
  });

  // The record writes don't hold up routing, so the sign-in screen can ask
  // for the count before they land. It mustn't read around them.
  group('when the record is slow to land', () {
    /// Past the route transition, well inside the count's budget.
    Future<void> settleRoute(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('a deliberate sign-out still leaves no notice', (tester) async {
      final repo = FakeAuthRepository(initialSession: sampleSession());
      final notice = _FakeUnsentChangesNotice(unsent: {'u1': 2});
      final cubit = buildCubit(repo, notice);
      addTearDown(cubit.close);
      await startApp(tester, cubit);

      final retire = notice.holdWrites = Completer<void>();
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.logout));
      await settleRoute(tester);
      retire.complete();
      await tester.pumpAndSettle();

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byKey(AuthScreen.unsentChangesNoticeKey), findsNothing);
    });

    testWidgets("the recovery sign-out still leaves the notice, though the "
        "session's record hadn't landed when it ran", (tester) async {
      final repo = FakeAuthRepository(initialSession: sampleSession());
      final record = Completer<void>();
      final notice = _FakeUnsentChangesNotice(unsent: {'u1': 2})
        ..holdWrites = record;
      final cubit = buildCubit(
        repo,
        notice,
        sessionScope: _ThrowingUserSessionScope(),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
      await cubit.initialize();
      await settleRoute(tester);
      record.complete();
      await tester.pumpAndSettle();

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text(_twoWaiting), findsOneWidget);
    });
  });

  testWidgets('a count that never comes back holds the sign-in screen only '
      'for its budget, then shows it without the notice', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final notice = _FakeUnsentChangesNotice(unsent: {'u1': 2});
    final cubit = buildCubit(repo, notice);
    addTearDown(cubit.close);
    await startApp(tester, cubit);

    notice.countHangs = true;
    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(SplashScreen), findsOneWidget, reason: 'held');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.byType(SplashScreen), findsNothing);
    expect(find.byKey(AuthScreen.unsentChangesNoticeKey), findsNothing);
  });
}
