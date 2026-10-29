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

class _MockUserRemote extends Mock implements UserRemoteDataSource {}

Household _household(String id, String name, {MemberInvitePolicy? policy}) =>
    Household(
      id: id,
      name: name,
      settings: policy == null
          ? null
          : HouseholdSettings(memberInvitePolicy: policy),
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

HouseholdMember _owner(String householdId) =>
    _viewer(householdId, HouseholdRole.householdOwner);

HouseholdMember _member(String householdId) =>
    _viewer(householdId, HouseholdRole.householdMember);

HouseholdMember _viewer(String householdId, HouseholdRole role) =>
    HouseholdMember(
      id: 'm-$householdId',
      userId: 'u-me',
      householdId: householdId,
      role: role,
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
  late _MockUserRemote users;
  late int refreshes;

  /// Tears down the session scope [pumpApp] built, as a sign-out does.
  late Future<void> Function() endSession;

  setUpAll(() {
    registerFallbackValue(HouseholdInviteStatus.pending);
    registerFallbackValue(HouseholdInviteDraft(invitee: InviteeEmail('a@b.c')));
  });

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    remote = _MockInviteRemote();
    users = _MockUserRemote();
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
    bool withUsers = true,
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
      userRemoteDataSource: withUsers ? users : null,
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

  /// Makes the viewer a member of every household, with hh_a under
  /// [policy].
  void Function(HouseholdRepository) asMember(MemberInvitePolicy policy) =>
      (repository) {
        when(repository.watchHouseholds).thenAnswer(
          (_) => Stream.value([
            _household('hh_a', 'Alpha Crew', policy: policy),
            _household('hh_b', 'Beta Crew'),
          ]),
        );
        when(() => repository.watchMembers(any())).thenAnswer(
          (invocation) => Stream.value([
            _member(invocation.positionalArguments.first as String),
          ]),
        );
        when(() => repository.getCurrentUserMember(any())).thenAnswer(
          (invocation) async =>
              _member(invocation.positionalArguments.first as String),
        );
      };

  Future<void> sendTo(WidgetTester tester, String email) async {
    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.emailKey),
      email,
    );
    await tester.ensureVisible(find.byKey(SendHouseholdInviteScreen.submitKey));
    await tester.tap(find.byKey(SendHouseholdInviteScreen.submitKey));
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

    testWidgets('does not need a user search client, which only the send '
        'form uses', (tester) async {
      await pumpApp(tester, withUsers: false);
      await openDrawer(tester);

      expect(find.byKey(HomeScreen.entryKey('invites')), findsOneWidget);
    });
  });

  testWidgets('the inbox opens the sent invites', (tester) async {
    when(
      () => remote.fetchSent(
        status: any(named: 'status'),
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => _page([
        _invite('i_s', householdId: 'hh_9', householdName: 'Sunday Crew'),
      ]),
    );
    await pumpApp(tester);
    await openDrawer(tester);
    await tester.tap(find.byKey(HomeScreen.entryKey('invites')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(InviteInboxScreen.sentKey));
    await tester.pumpAndSettle();

    expect(find.byType(SentInvitesScreen), findsOneWidget);
    expect(find.text('Sunday Crew'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(InviteInboxScreen), findsOneWidget);
    expect(find.byType(SentInvitesScreen), findsNothing);
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

  group('the send form beside the household (#569)', () {
    setUp(() {
      when(() => remote.send(any(), any()))
          .thenAnswer((_) async => _invite('i_new'));
      when(
        () => remote.fetchSent(
          status: any(named: 'status'),
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => _page([
          _invite('i_new', householdId: 'hh_a', householdName: 'Alpha Crew'),
        ]),
      );
    });

    testWidgets('a member under Direct sends from the form and lands on '
        'Sent', (tester) async {
      final router = await pumpApp(
        tester,
        stub: asMember(MemberInvitePolicy.direct),
      );
      router.go(AppRoutes.householdDetailOf('hh_a'));
      await tester.pumpAndSettle();
      unawaited(router.push<void>(AppRoutes.householdInviteSendOf('hh_a')));
      await tester.pumpAndSettle();

      await sendTo(tester, 'ana@example.com');

      expect(find.byType(SentInvitesScreen), findsOneWidget);
      expect(find.byType(SendHouseholdInviteScreen), findsNothing);
      verify(() => remote.send('hh_a', any())).called(1);
      verifyNever(
        () => remote.fetchHouseholdInvites(
          any(),
          status: any(named: 'status'),
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      );

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(find.byType(SentInvitesScreen), findsNothing);
    });

    testWidgets("the household screen's Invite row opens the send form", (
      tester,
    ) async {
      final router = await pumpApp(
        tester,
        stub: asMember(MemberInvitePolicy.direct),
      );
      router.go(AppRoutes.householdDetailOf('hh_a'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(HouseholdDetailScreen.inviteKey));
      await tester.pumpAndSettle();

      expect(router.state.uri.path, AppRoutes.householdInviteSendOf('hh_a'));
      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);
    });

    testWidgets("an owner's send goes back to the invites", (tester) async {
      final router = await pumpApp(tester);
      router.go(AppRoutes.householdInvitesOf('hh_a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HouseholdInviteListScreen.inviteKey));
      await tester.pumpAndSettle();
      expect(find.byType(SendHouseholdInviteScreen), findsOneWidget);

      await sendTo(tester, 'ana@example.com');

      expect(find.byType(HouseholdInviteListScreen), findsOneWidget);
      expect(find.byType(SendHouseholdInviteScreen), findsNothing);
      expect(find.byType(SentInvitesScreen), findsNothing);
    });

    // #465: pages animate now, so a form the user left is still mounted for
    // its exit transition, and a send can answer inside it.
    testWidgets('a send that answers after the user went back leaves the '
        'invites open', (tester) async {
      final sent = Completer<HouseholdInvite>();
      when(() => remote.send(any(), any())).thenAnswer((_) => sent.future);
      final router = await pumpApp(tester);
      router.go(AppRoutes.householdInvitesOf('hh_a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HouseholdInviteListScreen.inviteKey));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(SendHouseholdInviteScreen.emailKey),
        'ana@example.com',
      );
      await tester.ensureVisible(
        find.byKey(SendHouseholdInviteScreen.submitKey),
      );
      await tester.tap(find.byKey(SendHouseholdInviteScreen.submitKey));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byType(SendHouseholdInviteScreen, skipOffstage: false),
        findsOneWidget,
        reason: 'the form is still on its way out',
      );

      sent.complete(_invite('i_new'));
      await tester.pumpAndSettle();

      expect(find.byType(SendHouseholdInviteScreen), findsNothing);
      expect(find.byType(HouseholdInviteListScreen), findsOneWidget);
    });

    testWidgets("a member's send that answers after they went back leaves "
        'the household open', (tester) async {
      final sent = Completer<HouseholdInvite>();
      when(() => remote.send(any(), any())).thenAnswer((_) => sent.future);
      final router = await pumpApp(
        tester,
        stub: asMember(MemberInvitePolicy.direct),
      );
      router.go(AppRoutes.householdDetailOf('hh_a'));
      await tester.pumpAndSettle();
      unawaited(router.push<void>(AppRoutes.householdInviteSendOf('hh_a')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(SendHouseholdInviteScreen.emailKey),
        'ana@example.com',
      );
      await tester.ensureVisible(
        find.byKey(SendHouseholdInviteScreen.submitKey),
      );
      await tester.tap(find.byKey(SendHouseholdInviteScreen.submitKey));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      sent.complete(_invite('i_new'));
      await tester.pumpAndSettle();

      expect(find.byType(SentInvitesScreen), findsNothing);
      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    });

    testWidgets('a viewer made a member under a form opened from the invites '
        'lands on Sent with the household beneath', (tester) async {
      var role = HouseholdRole.householdOwner;
      final members = StreamController<List<HouseholdMember>>.broadcast();
      addTearDown(members.close);
      final router = await pumpApp(
        tester,
        stub: (repository) {
          asMember(MemberInvitePolicy.direct)(repository);
          when(() => repository.watchMembers(any())).thenAnswer((_) async* {
            yield [_viewer('hh_a', role)];
            yield* members.stream;
          });
          when(() => repository.getCurrentUserMember(any()))
              .thenAnswer((_) async => _viewer('hh_a', role));
        },
      );
      router.go(AppRoutes.householdInvitesOf('hh_a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HouseholdInviteListScreen.inviteKey));
      await tester.pumpAndSettle();

      role = HouseholdRole.householdMember;
      members.add([_viewer('hh_a', role)]);
      await tester.pumpAndSettle();

      await sendTo(tester, 'ana@example.com');

      expect(find.byType(SentInvitesScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(
        find.byType(HouseholdInviteListScreen, skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('a policy switch to Off replaces an open form', (tester) async {
      var households = [
        _household('hh_a', 'Alpha Crew', policy: MemberInvitePolicy.direct),
      ];
      final updates = StreamController<List<Household>>.broadcast();
      addTearDown(updates.close);
      final router = await pumpApp(
        tester,
        stub: (repository) {
          asMember(MemberInvitePolicy.direct)(repository);
          when(repository.watchHouseholds).thenAnswer((_) async* {
            yield households;
            yield* updates.stream;
          });
        },
      );
      router.go(AppRoutes.householdInviteSendOf('hh_a'));
      await tester.pumpAndSettle();
      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);

      households = [
        _household('hh_a', 'Alpha Crew', policy: MemberInvitePolicy.off),
      ];
      updates.add(households);
      await tester.pumpAndSettle();

      expect(
        find.byKey(SendHouseholdInviteScreen.notAllowedKey),
        findsOneWidget,
      );
      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
    });

    testWidgets("trying again on the can't-tell text refreshes the household, "
        'and the form opens once the policy arrives', (tester) async {
      var households = [_household('hh_a', 'Alpha Crew')];
      final updates = StreamController<List<Household>>.broadcast();
      addTearDown(updates.close);
      final router = await pumpApp(
        tester,
        stub: (repository) {
          asMember(MemberInvitePolicy.direct)(repository);
          when(repository.watchHouseholds).thenAnswer((_) async* {
            yield households;
            yield* updates.stream;
          });
        },
      );
      router.go(AppRoutes.householdInviteSendOf('hh_a'));
      await tester.pumpAndSettle();
      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);

      await tester.tap(find.byKey(SendHouseholdInviteScreen.refreshKey));
      await tester.pumpAndSettle();
      expect(refreshes, 1);

      households = [
        _household('hh_a', 'Alpha Crew', policy: MemberInvitePolicy.direct),
      ];
      updates.add(households);
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);
    });

    testWidgets('a refused send refreshes the household', (tester) async {
      when(() => remote.send(any(), any())).thenAnswer(
        (_) async =>
            throw const HouseholdInviteRefusedException('off', statusCode: 403),
      );
      final router = await pumpApp(
        tester,
        stub: asMember(MemberInvitePolicy.direct),
      );
      router.go(AppRoutes.householdInviteSendOf('hh_a'));
      await tester.pumpAndSettle();

      await sendTo(tester, 'ana@example.com');

      expect(refreshes, 1);
      expect(find.byKey(SendHouseholdInviteScreen.errorKey), findsOneWidget);
    });
  });

  testWidgets('the invite routes fall back without an invite client', (
    tester,
  ) async {
    final router = await pumpApp(tester, withInvites: false);

    router.go(AppRoutes.invites);
    await tester.pumpAndSettle();
    expect(find.byType(NotYetAvailableScreen), findsOneWidget);

    router.go(AppRoutes.invitesSent);
    await tester.pumpAndSettle();
    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });

  testWidgets('the send form falls back without a user search client', (
    tester,
  ) async {
    final router = await pumpApp(tester, withUsers: false);

    router.go(AppRoutes.householdInviteSendOf('hh_a'));
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    expect(find.byType(SendHouseholdInviteScreen), findsNothing);
  });

  // Every way in shares the form's gate, so none leads to the fallback.
  testWidgets('without a user search client the household screen offers no '
      'Invite row', (tester) async {
    // A member under Direct, who is offered the row where the form builds.
    final router = await pumpApp(
      tester,
      withUsers: false,
      stub: asMember(MemberInvitePolicy.direct),
    );

    router.go(AppRoutes.householdDetailOf('hh_a'));
    await tester.pumpAndSettle();

    expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    expect(find.byKey(HouseholdDetailScreen.roleKey), findsOneWidget);
    expect(find.byKey(HouseholdDetailScreen.inviteKey), findsNothing);
  });

  testWidgets('without a user search client the invites offer no Invite '
      'button', (tester) async {
    // An owner, who is offered the button where the form builds.
    final router = await pumpApp(tester, withUsers: false);

    router.go(AppRoutes.householdInvitesOf('hh_a'));
    await tester.pumpAndSettle();

    expect(find.text('For hh_a'), findsOneWidget);
    expect(find.byKey(HouseholdInviteListScreen.inviteKey), findsNothing);
  });
}
