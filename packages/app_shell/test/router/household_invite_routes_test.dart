import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

const _inboxKey = Key('invite_inbox_route_marker');
const _sentKey = Key('sent_invites_route_marker');
const _invitesKey = Key('household_invites_route_marker');
const _sendKey = Key('household_invite_send_route_marker');
const _detailKey = Key('household_detail_route_marker');
const _createKey = Key('household_create_route_marker');

/// #455: the invite routes. The inbox is top-level; a household's invites
/// and its send form are children of the household's detail route, so a
/// `go` to either builds the detail screen beneath it and leaving is a
/// plain pop.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() => cubit = _MockAppBootstrapCubit());

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    InviteInboxScreenBuilder? inviteInboxBuilder,
    SentInvitesScreenBuilder? sentInvitesBuilder,
    HouseholdInvitesScreenBuilder? householdInvitesBuilder,
    SendHouseholdInviteScreenBuilder? sendHouseholdInviteBuilder,
    HouseholdDetailScreenBuilder? householdDetailBuilder,
    CreateHouseholdScreenBuilder? createHouseholdBuilder,
  }) async {
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    final listenable = BootstrapStreamListenable(cubit.stream);
    final router = buildAppRouter(
      bootstrapCubit: cubit,
      refreshListenable: listenable,
      inviteInboxBuilder: inviteInboxBuilder,
      sentInvitesBuilder: sentInvitesBuilder,
      householdInvitesBuilder: householdInvitesBuilder,
      sendHouseholdInviteBuilder: sendHouseholdInviteBuilder,
      householdDetailBuilder: householdDetailBuilder,
      createHouseholdBuilder: createHouseholdBuilder,
    );
    addTearDown(() {
      router.dispose();
      listenable.dispose();
    });
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: ShellLocalizations.localizationsDelegates,
        supportedLocales: ShellLocalizations.supportedLocales,
      ),
    );
    await tester.pump();
    return router;
  }

  Widget marker(Key key) => Scaffold(body: SizedBox(key: key));

  testWidgets('the inbox is its own route', (tester) async {
    final router = await pumpRouter(
      tester,
      inviteInboxBuilder: (_) => marker(_inboxKey),
    );

    router.go(AppRoutes.invites);
    await tester.pumpAndSettle();

    expect(find.byKey(_inboxKey), findsOneWidget);
  });

  testWidgets('the sent invites are their own route, under the inbox', (
    tester,
  ) async {
    final router = await pumpRouter(
      tester,
      inviteInboxBuilder: (_) => marker(_inboxKey),
      sentInvitesBuilder: (_) => marker(_sentKey),
    );

    router.go(AppRoutes.invitesSent);
    await tester.pumpAndSettle();

    expect(find.byKey(_sentKey), findsOneWidget);
    expect(find.byKey(_inboxKey, skipOffstage: false), findsOneWidget);
  });

  testWidgets("a household's invites get its id, over its detail screen", (
    tester,
  ) async {
    String? seen;
    final router = await pumpRouter(
      tester,
      householdDetailBuilder: (_, _) => marker(_detailKey),
      householdInvitesBuilder: (_, id) {
        seen = id;
        return marker(_invitesKey);
      },
    );

    router.go(AppRoutes.householdInvitesOf('hh 1/a'));
    await tester.pumpAndSettle();

    expect(find.byKey(_invitesKey), findsOneWidget);
    expect(seen, 'hh 1/a');
    expect(find.byKey(_detailKey, skipOffstage: false), findsOneWidget);
  });

  testWidgets('the send form gets the id, over the invites', (tester) async {
    String? seen;
    final router = await pumpRouter(
      tester,
      householdInvitesBuilder: (_, _) => marker(_invitesKey),
      sendHouseholdInviteBuilder: (_, id) {
        seen = id;
        return marker(_sendKey);
      },
    );

    router.go(AppRoutes.householdInviteSendOf('hh_1'));
    await tester.pumpAndSettle();

    expect(find.byKey(_sendKey), findsOneWidget);
    expect(seen, 'hh_1');
    expect(find.byKey(_invitesKey, skipOffstage: false), findsOneWidget);
  });

  testWidgets('create still reaches create', (tester) async {
    final router = await pumpRouter(
      tester,
      createHouseholdBuilder: (_) => marker(_createKey),
      householdDetailBuilder: (_, _) => marker(_detailKey),
    );

    router.go(AppRoutes.householdCreate);
    await tester.pumpAndSettle();

    expect(find.byKey(_createKey), findsOneWidget);
    expect(find.byKey(_detailKey), findsNothing);
  });

  testWidgets('each falls back to NotYetAvailable with no builder', (
    tester,
  ) async {
    final router = await pumpRouter(tester);

    for (final location in [
      AppRoutes.invites,
      AppRoutes.invitesSent,
      AppRoutes.householdInvitesOf('hh_1'),
      AppRoutes.householdInviteSendOf('hh_1'),
    ]) {
      router.go(location);
      await tester.pumpAndSettle();
      expect(
        find.byType(NotYetAvailableScreen),
        findsOneWidget,
        reason: location,
      );
    }
  });
}
