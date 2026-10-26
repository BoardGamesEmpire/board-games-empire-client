import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_household_invite_remote.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

const _id = 'h-1';

Household _household(
  String id, {
  String name = 'Sunday Crew',
  String? description,
}) => Household(
  id: id,
  name: name,
  description: description,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdMember _member(
  String userId, {
  HouseholdRole? role = HouseholdRole.householdMember,
  String? username,
  String? displayName,
}) => HouseholdMember(
  id: 'm-$userId',
  userId: userId,
  householdId: _id,
  role: role,
  username: username,
  displayName: displayName,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

const _notFoundCopy = "We couldn't find this household";
const _refreshFailedCopy = "This may be out of date — we couldn't refresh it.";
const _retryCopy = 'Try again';
const _refreshingCopy = 'Refreshing\u2026';
const _errorCopy = "We couldn't open this household.";
const _unknownRoleCopy = "A role this app doesn't recognise";

/// Pins the #270 detail screen against a mocked repository and hand-driven
/// streams: the four surfaces, the role rendering D4 specifies, the
/// staleness banner, and the reserved-`create`-id guard.
void main() {
  late _MockHouseholdRepository repository;
  late StreamController<List<Household>> households;
  late StreamController<List<HouseholdMember>> members;
  late StreamController<HouseholdHydrationState> hydration;

  /// [text] inside the "Your role" block. The user's own roster row says
  /// their role too (#304).
  Finder inRoleBlock(String text) => find.descendant(
    of: find.byKey(HouseholdDetailScreen.roleKey),
    matching: find.text(text),
  );

  setUp(() {
    repository = _MockHouseholdRepository();
    households = StreamController<List<Household>>.broadcast();
    members = StreamController<List<HouseholdMember>>.broadcast();
    hydration = StreamController<HouseholdHydrationState>.broadcast();
    when(repository.watchHouseholds).thenAnswer((_) => households.stream);
    when(() => repository.watchMembers(any()))
        .thenAnswer((_) => members.stream);
    when(() => repository.getCurrentUserMember(any()))
        .thenAnswer((_) async => _member('u-me'));
  });

  tearDown(() {
    unawaited(households.close());
    unawaited(members.close());
    unawaited(hydration.close());
  });

  Widget harness({
    String householdId = _id,
    void Function(BuildContext context)? onBack,
    Future<void> Function()? onRetry,
    TextScaler textScaler = TextScaler.noScaling,
    HouseholdInviteRemoteDataSource? invites,
    void Function(BuildContext context, String householdId)? onOpenInvites,
    void Function(BuildContext context, String householdId)? onEdit,
    void Function(BuildContext context, String householdId)? onInvite,
  }) => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: HouseholdDetailScreen(
      householdId: householdId,
      repository: repository,
      hydration: hydration.stream,
      onBack: onBack,
      onRetry: onRetry,
      invites: invites,
      onOpenInvites: onOpenInvites,
      onEdit: onEdit,
      onInvite: onInvite,
    ),
  );

  /// Lands the household plus its roster and lets the identity future
  /// resolve, which is the ordinary "screen has loaded" position.
  Future<void> settleWith(
    WidgetTester tester, {
    Household? household,
    List<HouseholdMember>? roster,
  }) async {
    households.add([household ?? _household(_id)]);
    members.add(roster ?? [_member('u-me')]);
    await tester.pumpAndSettle();
  }

  group('while the cache is filling', () {
    testWidgets('shows a spinner rather than a not-found', (tester) async {
      // A deep link can arrive before the drain has filled the cache. "We
      // couldn't find this household" shown to someone who has it is the
      // failure #267 exists to fix.
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.running);
      households.add(const []);
      await tester.pump();

      expect(find.byKey(HouseholdDetailScreen.loadingKey), findsOneWidget);
      expect(find.text(_notFoundCopy), findsNothing);
    });

    testWidgets('waits for the roster before claiming a member count', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      households.add([_household(_id)]);
      // Two pumps rather than pumpAndSettle: the expected end state holds
      // a spinner, which never settles.
      await tester.pump();
      await tester.pump();

      expect(find.byKey(HouseholdDetailScreen.loadingKey), findsOneWidget);
      expect(find.text('No members'), findsNothing);
    });
  });

  group('the household', () {
    testWidgets('titles the page with its name', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(tester);

      expect(find.text('Sunday Crew'), findsOneWidget);
    });

    testWidgets('shows the description when there is one', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        household: _household(_id, description: 'Board games, every Sunday.'),
      );

      expect(find.text('Board games, every Sunday.'), findsOneWidget);
    });

    testWidgets('shows nothing in its place when there is not', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(tester, household: _household(_id));

      // No placeholder, no empty paragraph — the count moves up.
      expect(find.byKey(HouseholdDetailScreen.memberCountKey), findsOneWidget);
    });

    testWidgets('counts the roster, pluralised', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [_member('u-me'), _member('u-2'), _member('u-3')],
      );

      expect(find.text('3 members'), findsOneWidget);
    });

    testWidgets('says "1 member" rather than "1 members"', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(tester, roster: [_member('u-me')]);

      expect(find.text('1 member'), findsOneWidget);
    });
  });

  group('the current user role (D4)', () {
    testWidgets('names a known role', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.roleKey), findsOneWidget);
      expect(inRoleBlock('Owner'), findsOneWidget);
    });

    testWidgets('says an unknown role is unrecognised, not absent', (
      tester,
    ) async {
      // Post-#266 D2 this is real data about a custom-role deployment —
      // the adapter throws on a malformed role rather than degrading into
      // `unknown` — so the screen reports it instead of hiding it.
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.unknown)],
      );

      expect(inRoleBlock(_unknownRoleCopy), findsOneWidget);
    });

    testWidgets('appears on the deep-link path, where the cache was cold', (
      tester,
    ) async {
      // The symptom the one-shot identity lookup produced: open the screen
      // cold, the hydrate lands the roster, and "Your role" was never
      // shown because the first (correct) answer to "who are you" was null.
      HouseholdMember? cached;
      when(() => repository.getCurrentUserMember(any()))
          .thenAnswer((_) async => cached);

      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      cached = _member('u-me', role: HouseholdRole.householdOwner);
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.roleKey), findsOneWidget);
      expect(inRoleBlock('Owner'), findsOneWidget);
    });

    testWidgets('omits the block entirely for a null binding', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(tester, roster: [_member('u-me', role: null)]);

      expect(find.byKey(HouseholdDetailScreen.roleKey), findsNothing);
      expect(find.text('Your role'), findsNothing);
      // The rest of the screen is unaffected.
      expect(find.byKey(HouseholdDetailScreen.memberCountKey), findsOneWidget);
    });

    testWidgets('omits it when the current user could not be identified', (
      tester,
    ) async {
      when(() => repository.getCurrentUserMember(any()))
          .thenAnswer((_) async => null);

      await tester.pumpWidget(harness());
      await settleWith(tester, roster: [_member('u-other')]);

      expect(find.byKey(HouseholdDetailScreen.roleKey), findsNothing);
      expect(find.text('1 member'), findsOneWidget);
    });
  });

  group('the roster (#304)', () {
    Finder inRow(String userId, String text) => find.descendant(
      of: find.byKey(HouseholdDetailScreen.memberKey(userId)),
      matching: find.text(text),
    );

    testWidgets('names each member with their role', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [
          _member('u-me', displayName: 'Alex'),
          _member(
            'u-2',
            role: HouseholdRole.householdOwner,
            displayName: 'Zed',
            username: 'zed99',
          ),
        ],
      );

      expect(inRow('u-2', 'Zed'), findsOneWidget);
      expect(inRow('u-2', 'Owner'), findsOneWidget);
      expect(find.text('zed99'), findsNothing);
    });

    testWidgets('names a member by username when they set no display name', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [
          _member('u-me'),
          _member('u-2', username: 'zed99'),
        ],
      );

      expect(inRow('u-2', 'zed99'), findsOneWidget);
    });

    testWidgets('lists them in the order the bloc gives', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [
          _member('u-me', username: 'alexd'),
          _member('u-2', role: HouseholdRole.householdOwner, username: 'zed'),
        ],
      );

      final owner = tester.getTopLeft(
        find.byKey(HouseholdDetailScreen.memberKey('u-2')),
      );
      final me = tester.getTopLeft(
        find.byKey(HouseholdDetailScreen.memberKey('u-me')),
      );
      expect(owner.dy, lessThan(me.dy));
    });

    testWidgets("marks the current user's own row", (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(tester, roster: [_member('u-me', displayName: 'Alex')]);

      expect(inRow('u-me', 'Alex (you)'), findsOneWidget);
    });

    testWidgets("the current user's row without a name reads You", (
      tester,
    ) async {
      // The owner row a local create synthesizes, until a hydrate replaces
      // it with the server's.
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(inRow('u-me', 'You'), findsOneWidget);
      expect(inRow('u-me', 'Owner'), findsOneWidget);
    });

    testWidgets('another member without a name reads as their role alone', (
      tester,
    ) async {
      // "Member" over a role of member would say it twice.
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [
          _member('u-me', username: 'alexd'),
          _member('u-2', role: HouseholdRole.householdAdmin),
          _member('u-3'),
        ],
      );

      expect(inRow('u-2', 'Admin'), findsOneWidget);
      expect(inRow('u-2', 'Member'), findsNothing);
      expect(inRow('u-3', 'Member'), findsOneWidget);
    });

    testWidgets('another member with neither a name nor a role reads Member', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [
          _member('u-me', username: 'alexd'),
          _member('u-2', role: null),
        ],
      );

      expect(inRow('u-2', 'Member'), findsOneWidget);
    });

    testWidgets('every member has a row, named or not', (tester) async {
      // The list is as long as the count beside it.
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [
          _member('u-me'),
          _member('u-2', username: 'zed'),
          _member('u-3'),
        ],
      );

      expect(find.text('3 members'), findsOneWidget);
      for (final userId in ['u-me', 'u-2', 'u-3']) {
        expect(
          find.byKey(HouseholdDetailScreen.memberKey(userId)),
          findsOneWidget,
          reason: userId,
        );
      }
      expect(inRow('u-me', 'You'), findsOneWidget);
    });

    testWidgets('the count heads the list', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(tester);

      expect(
        tester.getSemantics(find.byKey(HouseholdDetailScreen.memberCountKey)),
        isSemantics(isHeader: true),
      );
    });

    testWidgets('each row is one semantics node', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [
          _member('u-me', username: 'alexd'),
          _member(
            'u-2',
            role: HouseholdRole.householdOwner,
            displayName: 'Zed',
          ),
        ],
      );

      final label = tester
          .getSemantics(find.byKey(HouseholdDetailScreen.memberKey('u-2')))
          .label;
      expect(label, contains('Zed'));
      expect(label, contains('Owner'));
    });

    testWidgets('a member without a role shows no role line', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [
          _member('u-me', username: 'alexd'),
          _member('u-2', role: null, displayName: 'Zed'),
        ],
      );

      expect(
        find.descendant(
          of: find.byKey(HouseholdDetailScreen.memberKey('u-2')),
          matching: find.byType(Text),
        ),
        findsOneWidget,
      );
      expect(inRow('u-2', 'Zed'), findsOneWidget);
    });
  });

  testWidgets('never flashes "No members" before the roster arrives', (
    tester,
  ) async {
    // The household and its roster arrive on separate streams, so the
    // household can briefly be on screen with an empty roster.
    await tester.pumpWidget(harness());
    hydration.add(HouseholdHydrationState.running);
    members.add(const []);
    households.add([_household(_id)]);
    await tester.pump();
    await tester.pump();

    expect(find.text('No members'), findsNothing);
    expect(find.byKey(HouseholdDetailScreen.loadingKey), findsOneWidget);

    members.add([_member('u-me'), _member('u-2')]);
    await tester.pumpAndSettle();

    expect(find.text('2 members'), findsOneWidget);
  });

  testWidgets('keeps the household on screen when a reconcile moves it to '
      "the server's id (#306)", (tester) async {
    // A household created offline, open under its local id when the server
    // confirms it. The reconcile deletes the local row, so the list loses
    // it and its roster empties; the repository records where it went.
    String? reconciledTo;
    when(() => repository.reconciledHouseholdId(_id))
        .thenAnswer((_) => reconciledTo);
    await tester.pumpWidget(harness());
    hydration.add(HouseholdHydrationState.refreshed);
    await settleWith(tester);
    expect(find.text('Sunday Crew'), findsOneWidget);

    void expectStillShown() {
      expect(find.text('Sunday Crew'), findsOneWidget);
      expect(find.text('1 member'), findsOneWidget);
      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsNothing);
      expect(find.byKey(HouseholdDetailScreen.loadingKey), findsNothing);
    }

    reconciledTo = 'hh_server';
    members.add(const []);
    await tester.pump();
    expectStillShown();

    households.add([_household('hh_server')]);
    await tester.pump();
    expectStillShown();

    members.add([_member('u-me')]);
    await tester.pumpAndSettle();
    expectStillShown();
  });

  group('not found', () {
    testWidgets('renders once the hydrate has settled', (tester) async {
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.refreshed);
      households.add(const []);
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsOneWidget);
      expect(find.text(_notFoundCopy), findsOneWidget);
    });

    testWidgets('offers a way back to the list', (tester) async {
      // The body's own button, beside the app bar's back: on this surface
      // leaving is the likely intent.
      var backs = 0;
      await tester.pumpWidget(harness(onBack: (_) => backs++));
      hydration.add(HouseholdHydrationState.refreshed);
      households.add(const []);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(HouseholdDetailScreen.notFoundBackKey));
      await tester.pump();

      expect(backs, 1);
    });

    testWidgets('drops the way back where the caller offers none', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.refreshed);
      households.add(const []);
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdDetailScreen.notFoundBackKey), findsNothing);
      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsOneWidget);
    });

    testWidgets('says it could not check when the refresh failed too', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.failed);
      households.add(const []);
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsOneWidget);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
    });

    testWidgets('answers a literal `create` id without asking the repository', (
      tester,
    ) async {
      // Belt to the route table's braces (#270 D6). `create` is a route of
      // its own; if it ever resolves as an id, it must not become a query.
      await tester.pumpWidget(harness(householdId: 'create'));
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsOneWidget);
      verifyNever(repository.watchHouseholds);
      verifyNever(() => repository.watchMembers(any()));
    });
  });

  group('staleness', () {
    testWidgets('banners a failed refresh over the household', (tester) async {
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.failed);
      await settleWith(tester);

      expect(
        find.byKey(HouseholdDetailScreen.refreshBannerKey),
        findsOneWidget,
      );
      expect(find.text(_refreshFailedCopy), findsOneWidget);
      // Annotated, not hidden.
      expect(find.text('Sunday Crew'), findsOneWidget);
    });

    testWidgets('says nothing when the refresh succeeded', (tester) async {
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.refreshed);
      await settleWith(tester);

      expect(find.byKey(HouseholdDetailScreen.refreshBannerKey), findsNothing);
    });
  });

  group('when the read fails', () {
    testWidgets('shows the error surface and no household', (tester) async {
      await tester.pumpWidget(harness());
      households.addError(StateError('unauthenticated'));
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdDetailScreen.errorKey), findsOneWidget);
      expect(find.text(_errorCopy), findsOneWidget);
    });

    testWidgets('recovers when the stream delivers rows again', (tester) async {
      await tester.pumpWidget(harness());
      households.addError(StateError('unauthenticated'));
      await tester.pumpAndSettle();
      expect(find.byKey(HouseholdDetailScreen.errorKey), findsOneWidget);

      await settleWith(tester);

      expect(find.byKey(HouseholdDetailScreen.errorKey), findsNothing);
      expect(find.text('Sunday Crew'), findsOneWidget);
    });
  });

  group('pushed over another route, every surface has a way back', () {
    // The app's route table always puts the list beneath this screen
    // (#308), and the app bar's back button is the way back to it. Every
    // surface is titled so that it has one. The error surface is the case
    // that matters most: it can replace a household that already rendered,
    // and on desktop there is nothing else to press.
    Future<void> pushDetail(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
          supportedLocales: HouseholdLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => HouseholdDetailScreen(
                        householdId: _id,
                        repository: repository,
                        hydration: hydration.stream,
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // Fixed pumps, not pumpAndSettle: the first-read spinner animates
      // forever. One second covers the push transition.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> expectBackLeaves(WidgetTester tester) async {
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdDetailScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    }

    testWidgets('while the first read has not answered', (tester) async {
      await pushDetail(tester);
      expect(find.byKey(HouseholdDetailScreen.loadingKey), findsOneWidget);

      await expectBackLeaves(tester);
    });

    testWidgets('once the household has rendered', (tester) async {
      await pushDetail(tester);
      await settleWith(tester);
      expect(find.text('Sunday Crew'), findsOneWidget);

      await expectBackLeaves(tester);
    });

    testWidgets('after a read fails under a household that had rendered', (
      tester,
    ) async {
      await pushDetail(tester);
      await settleWith(tester);
      expect(find.text('Sunday Crew'), findsOneWidget);

      households.addError(StateError('the cache read broke'));
      await tester.pumpAndSettle();
      expect(find.byKey(HouseholdDetailScreen.errorKey), findsOneWidget);

      await expectBackLeaves(tester);
    });
  });

  testWidgets('lays out at the 200% text scale the app guarantees', (
    tester,
  ) async {
    // The list's badge had to move out of `ListTile.trailing` for exactly
    // this reason (#269); this screen is a column, but the guarantee is
    // worth pinning rather than assuming.
    useViewSize(tester, const Size(320, 800));

    await tester.pumpWidget(harness(textScaler: const TextScaler.linear(2)));
    await settleWith(
      tester,
      household: _household(_id, description: 'Board games, every Sunday.'),
      roster: [
        _member('u-me', role: HouseholdRole.householdOwner),
        // A long name has to wrap inside the pane (#304).
        _member(
          'u-2',
          displayName:
              'Maximiliana Theodora Wolfeschlegelsteinhausen-Bergdorff',
        ),
      ],
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(HouseholdDetailScreen.memberCountKey), findsOneWidget);
    expect(find.byKey(HouseholdDetailScreen.memberKey('u-2')), findsOneWidget);
  });

  group('the retry on the refresh banner (#300 D10)', () {
    testWidgets('runs a pass and says so, over the household', (tester) async {
      final pass = Completer<void>();
      var calls = 0;

      await tester.pumpWidget(
        harness(
          onRetry: () {
            calls++;
            return pass.future;
          },
        ),
      );
      hydration.add(HouseholdHydrationState.failed);
      await settleWith(tester);
      expect(find.text(_retryCopy), findsOneWidget);

      await tester.tap(find.byKey(HouseholdDetailScreen.refreshRetryKey));
      await tester.pump();
      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      expect(calls, 1);
      // Two of them: the banner's message, and the disabled button's own
      // label — it keeps a name rather than becoming a bare spinner
      // (`BgeSubmitButton`'s contract, #163).
      expect(find.text(_refreshingCopy), findsNWidgets(2));
      expect(find.text(_refreshFailedCopy), findsNothing);
      // Annotated, not hidden — the same rule the failed banner follows.
      expect(find.text('Sunday Crew'), findsOneWidget);

      pass.complete();
      hydration.add(HouseholdHydrationState.refreshed);
      await tester.pumpAndSettle();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsNothing);
    });

    testWidgets('is offered on an unverified absence, where it is worth the '
        'most (#300 D10)', (tester) async {
      // A household missing from a cache whose last pass failed may well
      // exist on the server. This is the one surface where the retry can
      // change what is on screen rather than only how fresh it is.
      final pass = Completer<void>();
      var calls = 0;

      await tester.pumpWidget(
        harness(
          onRetry: () {
            calls++;
            return pass.future;
          },
        ),
      );
      hydration.add(HouseholdHydrationState.failed);
      households.add(const []);
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsOneWidget);

      await tester.tap(find.byKey(HouseholdDetailScreen.refreshRetryKey));
      await tester.pump();
      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      expect(calls, 1);
      // #270's rule takes over from here: an absence with a pass running is
      // unknown rather than missing, so the screen stops asserting it.
      expect(find.byKey(HouseholdDetailScreen.loadingKey), findsOneWidget);
      expect(find.text(_notFoundCopy), findsNothing);

      pass.complete();
      hydration.add(HouseholdHydrationState.failed);
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsOneWidget);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
    });

    testWidgets('is not offered where the composition cannot refresh (#137)', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.failed);
      await settleWith(tester);

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(HouseholdDetailScreen.refreshRetryKey), findsNothing);
    });

    testWidgets('a pass nobody asked for is not announced (#300 D6)', (
      tester,
    ) async {
      await tester.pumpWidget(harness(onRetry: () async {}));
      hydration.add(HouseholdHydrationState.failed);
      await settleWith(tester);

      hydration.add(HouseholdHydrationState.running);
      // Two pumps: the status event reaches the bloc on one microtask turn
      // and the rebuild lands on the next.
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsNothing);
    });
  });

  group('the invites entry (#455, #489)', () {
    late FakeHouseholdInviteRemote invites;
    late List<String> opened;

    setUp(() {
      invites = FakeHouseholdInviteRemote()
        ..onFetchHouseholdInvites = (_, _, _, limit) async =>
            pageOf(const [], limit: limit, total: 2, hasMore: true);
      opened = [];
    });

    Widget withInvites() => harness(
      invites: invites,
      // Pushes a real page, so leaving it uncovers this screen.
      onOpenInvites: (context, householdId) {
        opened.add(householdId);
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('the invites')),
            ),
          ),
        );
      },
    );

    testWidgets('an owner sees it, with what awaits approval', (tester) async {
      await tester.pumpWidget(withInvites());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.invitesKey), findsOneWidget);
      expect(find.text('2 awaiting approval'), findsOneWidget);
    });

    testWidgets('no count is shown when nothing awaits approval', (
      tester,
    ) async {
      invites.onFetchHouseholdInvites = (_, _, _, limit) async =>
          pageOf(const [], limit: limit, total: 0);
      await tester.pumpWidget(withInvites());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdAdmin)],
      );

      expect(find.byKey(HouseholdDetailScreen.invitesKey), findsOneWidget);
      expect(find.textContaining('awaiting approval'), findsNothing);
    });

    testWidgets('a member does not see it', (tester) async {
      await tester.pumpWidget(withInvites());
      await settleWith(tester);

      expect(find.byKey(HouseholdDetailScreen.invitesKey), findsNothing);
      expect(invites.calls, isEmpty);
    });

    testWidgets('a household the server does not know yet has none, and '
        'nothing is asked', (tester) async {
      await tester.pumpWidget(withInvites());
      await settleWith(
        tester,
        household: _household(_id).copyWith(isLocalOnly: true),
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.invitesKey), findsNothing);
      expect(invites.calls, isEmpty);
    });

    testWidgets('a composition without invites has none', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.invitesKey), findsNothing);
    });

    testWidgets("opens the household's invites, and counts again on the "
        'way back', (tester) async {
      await tester.pumpWidget(withInvites());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      await tester.tap(find.byKey(HouseholdDetailScreen.invitesKey));
      await tester.pumpAndSettle();
      expect(opened, [_id]);
      expect(find.text('the invites'), findsOneWidget);
      expect(invites.calls, hasLength(1));

      Navigator.of(tester.element(find.text('the invites'))).pop();
      await tester.pumpAndSettle();

      expect(invites.calls, hasLength(2));
    });
  });

  group('the Invite row (#569)', () {
    late FakeHouseholdInviteRemote invites;
    late List<String> invited;

    setUp(() {
      invites = FakeHouseholdInviteRemote()
        ..onFetchHouseholdInvites = (_, _, _, limit) async =>
            pageOf(const [], limit: limit, total: 0);
      invited = [];
    });

    Widget withInvite() => harness(
      invites: invites,
      onOpenInvites: (_, _) {},
      onInvite: (_, householdId) => invited.add(householdId),
    );

    Household under(MemberInvitePolicy? policy) => _household(_id).copyWith(
      settings: policy == null
          ? null
          : HouseholdSettings(memberInvitePolicy: policy),
    );

    testWidgets('a member under Direct gets the Invite row, not the invites '
        'entry', (tester) async {
      await tester.pumpWidget(withInvite());
      await settleWith(tester, household: under(MemberInvitePolicy.direct));

      expect(
        find.descendant(
          of: find.byKey(HouseholdDetailScreen.inviteKey),
          matching: find.text('Invite someone'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(HouseholdDetailScreen.invitesKey), findsNothing);
      expect(invites.calls, isEmpty);
    });

    testWidgets('a member under NeedsApproval gets the Invite row', (
      tester,
    ) async {
      await tester.pumpWidget(withInvite());
      await settleWith(
        tester,
        household: under(MemberInvitePolicy.needsApproval),
      );

      expect(find.byKey(HouseholdDetailScreen.inviteKey), findsOneWidget);
    });

    testWidgets('a member under Off gets no Invite row', (tester) async {
      await tester.pumpWidget(withInvite());
      await settleWith(tester, household: under(MemberInvitePolicy.off));

      expect(find.byKey(HouseholdDetailScreen.inviteKey), findsNothing);
      expect(find.byKey(HouseholdDetailScreen.invitesKey), findsNothing);
    });

    testWidgets('a member gets no Invite row while the policy is unknown', (
      tester,
    ) async {
      for (final policy in [null, MemberInvitePolicy.unknown]) {
        await tester.pumpWidget(withInvite());
        await settleWith(tester, household: under(policy));

        expect(
          find.byKey(HouseholdDetailScreen.inviteKey),
          findsNothing,
          reason: '$policy',
        );
      }
    });

    testWidgets('an owner gets the invites entry, not the Invite row', (
      tester,
    ) async {
      await tester.pumpWidget(withInvite());
      await settleWith(
        tester,
        household: under(MemberInvitePolicy.direct),
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.invitesKey), findsOneWidget);
      expect(find.byKey(HouseholdDetailScreen.inviteKey), findsNothing);
    });

    testWidgets('a local-only household offers no Invite row', (tester) async {
      await tester.pumpWidget(withInvite());
      await settleWith(
        tester,
        household: under(MemberInvitePolicy.direct).copyWith(isLocalOnly: true),
      );

      expect(find.byKey(HouseholdDetailScreen.inviteKey), findsNothing);
    });

    testWidgets('no onInvite, no Invite row', (tester) async {
      await tester.pumpWidget(harness(invites: invites));
      await settleWith(tester, household: under(MemberInvitePolicy.direct));

      expect(find.byKey(HouseholdDetailScreen.inviteKey), findsNothing);
    });

    testWidgets("tapping Invite calls onInvite with the household's id", (
      tester,
    ) async {
      await tester.pumpWidget(withInvite());
      await settleWith(tester, household: under(MemberInvitePolicy.direct));

      await tester.tap(find.byKey(HouseholdDetailScreen.inviteKey));
      await tester.pump();

      expect(invited, [_id]);
    });
  });

  group('the Edit entry (#476)', () {
    late List<String> edited;

    setUp(() => edited = []);

    Widget withEdit() =>
        harness(onEdit: (_, householdId) => edited.add(householdId));

    testWidgets('an owner sees Edit', (tester) async {
      await tester.pumpWidget(withEdit());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.editKey), findsOneWidget);
      expect(find.byTooltip('Edit household'), findsOneWidget);
    });

    testWidgets('an admin sees Edit', (tester) async {
      await tester.pumpWidget(withEdit());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdAdmin)],
      );

      expect(find.byKey(HouseholdDetailScreen.editKey), findsOneWidget);
    });

    testWidgets('a member does not see Edit', (tester) async {
      await tester.pumpWidget(withEdit());
      await settleWith(tester);

      expect(find.byKey(HouseholdDetailScreen.editKey), findsNothing);
    });

    testWidgets('a household not yet synced has no Edit', (tester) async {
      await tester.pumpWidget(withEdit());
      await settleWith(
        tester,
        household: _household(_id).copyWith(isLocalOnly: true),
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.editKey), findsNothing);
    });

    testWidgets('no onEdit, no Edit', (tester) async {
      await tester.pumpWidget(harness());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.editKey), findsNothing);
    });

    testWidgets('tapping Edit calls onEdit with the id', (tester) async {
      await tester.pumpWidget(withEdit());
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      await tester.tap(find.byKey(HouseholdDetailScreen.editKey));
      await tester.pump();

      expect(edited, [_id]);
    });
  });
}
