import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

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
}) => HouseholdMember(
  id: 'm-$userId',
  userId: userId,
  householdId: _id,
  role: role,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

const _notFoundCopy = "We couldn't find this household";
const _refreshFailedCopy = "This may be out of date — we couldn't refresh it.";
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

  setUp(() {
    repository = _MockHouseholdRepository();
    households = StreamController<List<Household>>.broadcast();
    members = StreamController<List<HouseholdMember>>.broadcast();
    hydration = StreamController<HouseholdHydrationState>.broadcast();
    when(repository.watchHouseholds).thenAnswer((_) => households.stream);
    when(
      () => repository.watchMembers(any()),
    ).thenAnswer((_) => members.stream);
    when(
      () => repository.getCurrentUserMember(any()),
    ).thenAnswer((_) async => _member('u-me'));
  });

  tearDown(() {
    unawaited(households.close());
    unawaited(members.close());
    unawaited(hydration.close());
  });

  Widget harness({
    String householdId = _id,
    void Function(BuildContext context)? onBack,
    TextScaler textScaler = TextScaler.noScaling,
  }) => MaterialApp(
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
      // A deep link or a restored route can arrive before the drain has
      // filled the cache. "We couldn't find this household" shown to
      // someone who has it is the failure #267 exists to fix.
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
      expect(find.text('Owner'), findsOneWidget);
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

      expect(find.text(_unknownRoleCopy), findsOneWidget);
    });

    testWidgets('appears on the deep-link path, where the cache was cold', (
      tester,
    ) async {
      // The symptom the one-shot identity lookup produced: open the screen
      // cold, the hydrate lands the roster, and "Your role" was never
      // shown because the first (correct) answer to "who are you" was null.
      HouseholdMember? cached;
      when(
        () => repository.getCurrentUserMember(any()),
      ).thenAnswer((_) async => cached);

      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      cached = _member('u-me', role: HouseholdRole.householdOwner);
      await settleWith(
        tester,
        roster: [_member('u-me', role: HouseholdRole.householdOwner)],
      );

      expect(find.byKey(HouseholdDetailScreen.roleKey), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
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
      when(
        () => repository.getCurrentUserMember(any()),
      ).thenAnswer((_) async => null);

      await tester.pumpWidget(harness());
      await settleWith(tester, roster: [_member('u-other')]);

      expect(find.byKey(HouseholdDetailScreen.roleKey), findsNothing);
      expect(find.text('1 member'), findsOneWidget);
    });
  });

  testWidgets('never flashes "No members" between the two hydrate writes', (
    tester,
  ) async {
    // cacheHousehold and cacheMembers are separate writes, so the
    // household is briefly on screen with an empty roster.
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
      // The route can be entered cold, with nothing beneath it to pop to.
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

  testWidgets('lays out at the 200% text scale the app guarantees', (
    tester,
  ) async {
    // The list's badge had to move out of `ListTile.trailing` for exactly
    // this reason (#269); this screen is a column, but the guarantee is
    // worth pinning rather than assuming.
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(textScaler: const TextScaler.linear(2)));
    await settleWith(
      tester,
      household: _household(_id, description: 'Board games, every Sunday.'),
      roster: [_member('u-me', role: HouseholdRole.householdOwner)],
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(HouseholdDetailScreen.memberCountKey), findsOneWidget);
  });
}
