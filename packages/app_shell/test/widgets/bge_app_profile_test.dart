import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:profile/profile.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

/// Answers the owner's profile and nothing else; the screen's own tests cover
/// editing.
class _FakeProfileRemote implements UserProfileRemoteDataSource {
  @override
  Future<UserProfile> fetchOwn() async => const UserProfile(
    userId: 'u-me',
    username: 'me',
    willingToTeach: false,
    openToNewPlayers: false,
    hostingCapability: false,
    reach: Reach.friends,
    isSearchable: true,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A user scope that holds whoever the shell last activated.
class _UserSessionScope implements UserSessionScope {
  @override
  String? activeUserId;

  @override
  Future<void> activate(String userId) async => activeUserId = userId;

  @override
  Future<void> deactivate() async => activeUserId = null;
}

/// A session guard that gives [answer] and records whom it was asked about.
class _RecordingGuard implements SessionIdentityGuard {
  _RecordingGuard(this.answer);

  final SessionConfirmation answer;
  final asked = <String>[];

  @override
  Future<SessionConfirmation> confirm(String userId) async {
    asked.add(userId);
    return answer;
  }
}

/// #547 through the real composition: the menu entry, its gate, and the route.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    bool withProfile = true,
    bool withSession = true,
    SessionIdentityGuard? guard,
  }) async {
    final repository = _MockHouseholdRepository();
    when(repository.watchHouseholds).thenAnswer((_) => Stream.value([]));

    final server = buildActiveServer(
      FakeAuthRepository(initialSession: testAuthResponse()),
      householdRepository: withSession ? repository : null,
      userProfileRemoteDataSource: withProfile ? _FakeProfileRemote() : null,
      userSessionScope: guard == null ? null : _UserSessionScope(),
      sessionIdentityGuard: guard,
    );
    addTearDown(server.container.dispose);
    when(
      () => cubit.activeServerScope,
    ).thenReturn(FakeActiveServerScope(server));
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pumpAndSettle();
    return tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
        as GoRouter;
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  testWidgets('the menu offers Your profile first of its entries while a '
      'session is active', (tester) async {
    await pumpApp(tester);
    await openDrawer(tester);

    final entry = find.byKey(MenuDrawer.entryKey('profile'));
    expect(entry, findsOneWidget);
    expect(
      find.descendant(of: entry, matching: find.text('Your profile')),
      findsOneWidget,
    );

    // Every other entry the menu gives, sign out included, sits below it.
    // Each is a ListTile; the shell's destinations, which the drawer lists
    // above the entries only where no bar or rail shows them, are not.
    final tiles = find.descendant(
      of: find.byKey(MenuDrawer.drawerKey),
      matching: find.byType(ListTile),
    );
    final others = [
      for (final element in tiles.evaluate())
        if (element.widget.key != MenuDrawer.entryKey('profile'))
          element.widget,
    ];
    // The drawer built them all, the last one too.
    expect(
      others.map((tile) => tile.key),
      containsAll([
        MenuDrawer.entryKey('households'),
        MenuDrawer.entryKey('send_feedback'),
        MenuDrawer.entryKey('settings'),
        MenuDrawer.entryKey('sign_out'),
      ]),
    );
    final top = tester.getTopLeft(entry).dy;
    for (final tile in others) {
      expect(
        tester.getTopLeft(find.byWidget(tile)).dy,
        greaterThan(top),
        reason: '${tile.key}',
      );
    }
  });

  testWidgets('no session, no entry', (tester) async {
    await pumpApp(tester, withSession: false);
    await openDrawer(tester);

    expect(find.byKey(MenuDrawer.entryKey('profile')), findsNothing);
  });

  testWidgets('the entry opens the profile screen', (tester) async {
    await pumpApp(tester);
    await openDrawer(tester);

    await tester.tap(find.byKey(MenuDrawer.entryKey('profile')));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileScreen), findsOneWidget);
  });

  testWidgets("the screen confirms the session with the server's guard, as "
      "the scope's user, before a save (#432)", (tester) async {
    final guard = _RecordingGuard(SessionConfirmation.notThisUser);
    final router = await pumpApp(tester, guard: guard);

    router.go(AppRoutes.profile);
    await tester.pumpAndSettle();

    final confirm = tester
        .widget<ProfileScreen>(find.byType(ProfileScreen))
        .confirmSession!;
    expect(await confirm(), isFalse);
    expect(guard.asked, ['u1']);
  });

  testWidgets('without a guard, as on native, the screen has no session '
      'check', (tester) async {
    final router = await pumpApp(tester);

    router.go(AppRoutes.profile);
    await tester.pumpAndSettle();

    expect(
      tester.widget<ProfileScreen>(find.byType(ProfileScreen)).confirmSession,
      isNull,
    );
  });

  testWidgets('/profile without the remote shows Not yet available', (
    tester,
  ) async {
    final router = await pumpApp(tester, withProfile: false);

    router.go(AppRoutes.profile);
    await tester.pumpAndSettle();

    expect(find.byType(ProfileScreen), findsNothing);
    expect(find.text('Not yet available'), findsOneWidget);
  });

  testWidgets('/profile without a session shows Not yet available, as the '
      'menu offers no entry', (tester) async {
    final router = await pumpApp(tester, withSession: false);

    router.go(AppRoutes.profile);
    await tester.pumpAndSettle();

    expect(find.byType(ProfileScreen), findsNothing);
    expect(find.text('Not yet available'), findsOneWidget);
  });
}
