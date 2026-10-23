import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockInviteRemote extends Mock
    implements HouseholdInviteRemoteDataSource {}

Household _household(String id, String name) => Household(
  id: id,
  name: name,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdMember _owner(String householdId) => HouseholdMember(
  id: 'm-$householdId',
  userId: 'u-me',
  householdId: householdId,
  role: HouseholdRole.householdOwner,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdInvite _invite(
  String id, {
  String? inviteeName,
  String? householdId,
  String? householdName,
  HouseholdInviteStatus status = HouseholdInviteStatus.pending,
}) => HouseholdInvite(
  id: id,
  status: status,
  inviter: const UserSummary(id: 'u-other', username: 'bo'),
  role: HouseholdRole.householdMember,
  inviteeName: inviteeName,
  householdId: householdId,
  householdName: householdName,
  expiresAt: DateTime.utc(2026, 10, 26, 12),
  createdAt: DateTime.utc(2026, 10, 19),
);

PaginatedResult<HouseholdInvite> _page(List<HouseholdInvite> rows) =>
    PaginatedResult(
      items: rows,
      meta: PaginationMeta(
        page: 1,
        limit: 25,
        total: rows.length,
        totalPages: 1,
        hasMore: false,
      ),
    );

/// #455 through the real composition: the drawer entry and its gate, the
/// inbox, the household invite routes' builders, and the refresh after an
/// accept.
void main() {
  late _MockAppBootstrapCubit cubit;
  late _MockInviteRemote remote;
  late int refreshes;

  /// Tears down the session scope [pumpApp] built, as a sign-out does.
  late Future<void> Function() endSession;

  setUpAll(() => registerFallbackValue(HouseholdInviteStatus.pending));

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    remote = _MockInviteRemote();
    refreshes = 0;
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    when(
      () => remote.fetchInbox(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => _page([
        _invite('i_9', householdId: 'hh_9', householdName: 'Sunday Crew'),
      ]),
    );
    when(
      () => remote.fetchHouseholdInvites(
        any(),
        status: any(named: 'status'),
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((invocation) async {
      final householdId = invocation.positionalArguments.first as String;
      return _page([
        _invite('row_$householdId', inviteeName: 'For $householdId'),
      ]);
    });
  });

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    bool withInvites = true,
    void Function(HouseholdRepository repository)? stub,
  }) async {
    final repository = _MockHouseholdRepository();
    when(repository.watchHouseholds).thenAnswer(
      (_) => Stream.value([
        _household('hh_a', 'Alpha Crew'),
        _household('hh_b', 'Beta Crew'),
      ]),
    );
    when(() => repository.watchMembers(any())).thenAnswer((invocation) {
      final id = invocation.positionalArguments.first as String;
      return Stream.value([_owner(id)]);
    });
    when(() => repository.getCurrentUserMember(any())).thenAnswer(
      (invocation) async =>
          _owner(invocation.positionalArguments.first as String),
    );
    stub?.call(repository);

    final server = buildActiveServer(
      FakeAuthRepository(initialSession: sampleSession()),
      householdRepository: repository,
      householdInviteRemoteDataSource: withInvites ? remote : null,
      householdRefresher: HouseholdRefresher(() async => refreshes++),
    );
    endSession = server.container.dispose;
    when(() => cubit.activeServerScope)
        .thenReturn(FakeActiveServerScope(server));
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

  group('the drawer entry', () {
    testWidgets('shows with an invite client, and opens the inbox', (
      tester,
    ) async {
      await pumpApp(tester);
      await openDrawer(tester);

      await tester.tap(find.byKey(HomeScreen.entryKey('invites')));
      await tester.pumpAndSettle();

      expect(find.byType(InviteInboxScreen), findsOneWidget);
      expect(find.text('Sunday Crew'), findsOneWidget);
    });

    testWidgets('is hidden without one', (tester) async {
      await pumpApp(tester, withInvites: false);
      await openDrawer(tester);

      expect(find.byKey(HomeScreen.entryKey('invites')), findsNothing);
      expect(find.byKey(HomeScreen.entryKey('households')), findsOneWidget);
    });
  });

  testWidgets('accepting in the inbox refreshes the households', (
    tester,
  ) async {
    when(() => remote.accept('i_9')).thenAnswer(
      (_) async => (
        invite: _invite('i_9', status: HouseholdInviteStatus.accepted),
        householdId: 'hh_9',
      ),
    );
    final router = await pumpApp(tester);
    router.go(AppRoutes.invites);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(InviteInboxScreen.acceptKey('i_9')));
    await tester.pumpAndSettle();

    expect(refreshes, 1);
    expect(find.text('You joined Sunday Crew.'), findsOneWidget);
  });

  testWidgets('an accept that answers after the session ended refreshes the '
      'session that sent it', (tester) async {
    final accepted = Completer<AcceptedHouseholdInvite>();
    when(() => remote.accept('i_9')).thenAnswer((_) => accepted.future);
    final router = await pumpApp(tester);
    router.go(AppRoutes.invites);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(InviteInboxScreen.acceptKey('i_9')));
    await tester.pump();
    await endSession();
    accepted.complete((
      invite: _invite('i_9', status: HouseholdInviteStatus.accepted),
      householdId: 'hh_9',
    ));
    await tester.pumpAndSettle();

    expect(refreshes, 1);
  });

  testWidgets("going from one household's invites straight to another's "
      'shows the second (#466)', (tester) async {
    final router = await pumpApp(tester);

    router.go(AppRoutes.householdInvitesOf('hh_a'));
    await tester.pumpAndSettle();
    expect(find.text('For hh_a'), findsOneWidget);

    router.go(AppRoutes.householdInvitesOf('hh_b'));
    await tester.pumpAndSettle();

    expect(find.text('For hh_b'), findsOneWidget);
    expect(find.text('For hh_a'), findsNothing);
  });

  testWidgets("the household screen's entry opens its invites", (tester) async {
    final router = await pumpApp(tester);
    router.go(AppRoutes.householdDetailOf('hh_a'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(HouseholdDetailScreen.invitesKey));
    await tester.pumpAndSettle();

    expect(find.byType(HouseholdInviteListScreen), findsOneWidget);
    expect(find.text('For hh_a'), findsOneWidget);
  });

  testWidgets('the send form resolves who is looking before it shows', (
    tester,
  ) async {
    final router = await pumpApp(tester);

    router.go(AppRoutes.householdInviteSendOf('hh_a'));
    await tester.pumpAndSettle();

    expect(find.byType(SendHouseholdInviteScreen), findsOneWidget);
    expect(
      find.byKey(SendHouseholdInviteScreen.submitKey),
      findsOneWidget,
      reason: 'an owner gets the form, not the not-allowed note',
    );
  });

  testWidgets('a send form opened before the cache knows who is looking '
      'opens once it does', (tester) async {
    final roster = StreamController<List<HouseholdMember>>.broadcast();
    addTearDown(roster.close);
    HouseholdMember? cached;
    final router = await pumpApp(
      tester,
      stub: (repository) {
        when(() => repository.watchMembers('hh_a'))
            .thenAnswer((_) => roster.stream);
        when(() => repository.getCurrentUserMember('hh_a'))
            .thenAnswer((_) async => cached);
      },
    );

    router.go(AppRoutes.householdInviteSendOf('hh_a'));
    await tester.pumpAndSettle();
    expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);

    cached = _owner('hh_a');
    roster.add([_owner('hh_a')]);
    await tester.pumpAndSettle();

    expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);
  });

  testWidgets('the invite routes fall back without an invite client', (
    tester,
  ) async {
    final router = await pumpApp(tester, withInvites: false);

    router.go(AppRoutes.invites);
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });
}
