import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_connectivity.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _seeAll = 'See all';
const _yourEvents = 'Your events';
const _note = "You have no upcoming events yet. Here's what's coming up.";
const _empty = 'Nothing coming up right now.';
const _refreshFailed =
    "Couldn't refresh your events. What's shown may be out of date.";

/// [base] cancelled, its dates left as they were (#502).
EventListItem _cancelled(EventListItem base) => EventListItem(
  event: base.event.copyWith(
    status: EventStatus.cancelled,
    cancelledAt: DateTime.utc(2026, 10, 20),
  ),
  occurrences: base.occurrences
      .map(
        (o) => o.copyWith(
          status: OccurrenceStatus.cancelled,
          cancelledAt: DateTime.utc(2026, 10, 20),
        ),
      )
      .toList(),
  attendance: base.attendance,
);

/// Pins the #613 home section against a mocked cache, a scripted remote and a
/// hand-driven hydration stream: which rows it shows, when it reads the
/// fallback, and that the fallback stays out of the cache.
void main() {
  final now = DateTime.utc(2026, 10, 23, 18);
  DateTime day(int day) => DateTime.utc(2026, 10, day, 19);

  late _MockEventRepository repository;
  late StreamController<List<EventListItem>> items;
  late EventHydrationStatus status;
  late FakeEventRemote remote;
  late FakeConnectivity connectivity;

  setUpAll(() {
    registerFallbackValue(EventAccessSource.read);
    registerFallbackValue(<EventSnapshot>[]);
    registerFallbackValue(
      EventSnapshot(event: item('fallback').event, occurrences: const []),
    );
  });

  setUp(() {
    repository = _MockEventRepository();
    items = StreamController<List<EventListItem>>.broadcast();
    status = EventHydrationStatus();
    remote = FakeEventRemote((_) => throw StateError('the list is not read'));
    remote.browse = (_) => browsePage(const []);
    connectivity = FakeConnectivity();
    when(repository.watchAttendingEventListItems)
        .thenAnswer((_) => items.stream);
  });

  tearDown(() {
    unawaited(items.close());
    unawaited(status.close());
    unawaited(connectivity.close());
  });

  final navigatorKey = GlobalKey<NavigatorState>();

  Widget harness({
    void Function(BuildContext context)? onOpenEvents,
    void Function(BuildContext context, String eventId)? onOpen,
    Future<void> Function()? onRetry,
    ThemeData? theme,
    TextScaler textScaler = TextScaler.noScaling,
    bool hasRemote = true,
    Stream<List<Household>>? Function()? households,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: BgePage(
      width: BgePageWidth.pane,
      // The column the home page puts its sections in.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UpcomingEventsSection(
            repository: repository,
            households: households,
            hydration: status.watch(),
            remote: hasRemote ? remote : null,
            connectivity: connectivity,
            onOpenEvents: onOpenEvents ?? (_) {},
            onOpen: onOpen,
            onRetry: onRetry,
            now: () => now,
          ),
        ],
      ),
    ),
  );

  /// Lets a cache answer reach the bloc, the bloc reach the cubit, and the
  /// cubit's read answer.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// Shows the section over a cache holding [rows], with the hydrate settled.
  Future<void> show(
    WidgetTester tester,
    List<EventListItem> rows, {
    void Function(BuildContext context)? onOpenEvents,
    void Function(BuildContext context, String eventId)? onOpen,
    TextScaler textScaler = TextScaler.noScaling,
    Stream<List<Household>>? Function()? households,
  }) async {
    await tester.pumpWidget(
      harness(
        onOpenEvents: onOpenEvents,
        onOpen: onOpen,
        textScaler: textScaler,
        households: households,
      ),
    );
    status.finished(EventHydrateOutcome.complete);
    items.add(rows);
    await settle(tester);
  }

  /// [count] upcoming events, `e-up-0` soonest.
  List<EventListItem> upcoming(int count, {String prefix = 'e-up'}) => [
    for (var n = 0; n < count; n++)
      item('$prefix-$n', occurrences: [confirmed('o', day(24 + n))]),
  ];

  List<EventSnapshot> offered(int count) => [
    for (final row in upcoming(count, prefix: 'e-offer'))
      EventSnapshot(event: row.event, occurrences: row.occurrences),
  ];

  Finder rowOf(String id) => find.byKey(UpcomingEventsSection.rowKey(id));

  Finder row() => find.descendant(
    of: find.byType(BgeShelf),
    matching: find.byType(Scrollable),
  );

  ScrollPosition rowPosition(WidgetTester tester) =>
      tester.state<ScrollableState>(row()).position;

  /// Whether the primary focus is in what [finder] finds.
  bool focusIn(WidgetTester tester, Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    final target = tester.element(finder);
    if (focused == target) return true;
    var inside = false;
    focused.visitAncestorElements((element) {
      inside = element == target;
      return !inside;
    });
    return inside;
  }

  group('own events', () {
    testWidgets('at most 10 cards, soonest first, with the See all link', (
      tester,
    ) async {
      await show(tester, upcoming(12).reversed.toList());

      final starts = [
        for (var n = 0; n < 10; n++) tester.getTopLeft(rowOf('e-up-$n')).dx,
      ];
      expect(starts, orderedEquals([...starts]..sort()));
      expect(starts.toSet(), hasLength(10));
      expect(rowOf('e-up-10'), findsNothing);
      expect(rowOf('e-up-11'), findsNothing);
      expect(UpcomingEventsSection.rowCap, 10);

      expect(
        find.descendant(
          of: find.byKey(UpcomingEventsSection.linkKey),
          matching: find.text(_seeAll),
        ),
        findsOneWidget,
      );
      expect(find.byKey(UpcomingEventsSection.fallbackNoteKey), findsNothing);
      expect(remote.browseRequests, isEmpty);
    });

    testWidgets('fewer than the cap still show the link', (tester) async {
      await show(tester, upcoming(1));

      expect(find.text(_seeAll), findsOneWidget);
    });

    testWidgets('a row with no attendance shows no RSVP, one with attendance '
        'shows it', (tester) async {
      await show(tester, [
        item(
          'e-known',
          occurrences: [confirmed('o', day(24))],
          attendance: attendance(EventParticipationStatus.attending),
        ),
        item('e-unknown', occurrences: [confirmed('o', day(25))]),
      ]);

      expect(
        find.descendant(of: rowOf('e-known'), matching: find.text('Going')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rowOf('e-unknown'), matching: find.text('Going')),
        findsNothing,
      );
    });

    testWidgets('a declined event still shows, with its badge', (tester) async {
      await show(tester, [
        item(
          'e-no',
          occurrences: [confirmed('o', day(24))],
          attendance: attendance(EventParticipationStatus.notAttending),
        ),
      ]);

      expect(
        find.descendant(of: rowOf('e-no'), matching: find.text('Not going')),
        findsOneWidget,
      );
      expect(remote.browseRequests, isEmpty);
    });

    testWidgets('a cancelled upcoming event is left off the shelf', (
      tester,
    ) async {
      await show(tester, [
        item('e-live', occurrences: [confirmed('o', day(24))]),
        _cancelled(item('e-off', occurrences: [confirmed('o', day(25))])),
      ]);

      expect(rowOf('e-live'), findsOneWidget);
      expect(rowOf('e-off'), findsNothing);
    });

    testWidgets('planning and past events alone count as no upcoming events', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(1));

      await show(tester, [
        item('e-plan'),
        item('e-past', occurrences: [confirmed('o', day(20))]),
      ]);

      expect(remote.browseRequests, [(page: 1, limit: 10)]);
      expect(rowOf('e-offer-0'), findsOneWidget);
      expect(rowOf('e-plan'), findsNothing);
      expect(rowOf('e-past'), findsNothing);
      // True of someone hosting an event with no date, unlike "not going to
      // anything".
      expect(find.text(_note), findsOneWidget);
    });
  });

  group('the row', () {
    testWidgets('the fallback note sits between the heading and the cards', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(3));
      await show(tester, const []);

      final note = tester.getRect(
        find.byKey(UpcomingEventsSection.fallbackNoteKey),
      );
      expect(
        tester.getBottomLeft(find.byKey(UpcomingEventsSection.headingKey)).dy,
        lessThan(note.top),
      );
      expect(note.bottom, lessThan(tester.getTopLeft(rowOf('e-offer-0')).dy));
    });

    testWidgets('with more cards than fit, Next events moves the row', (
      tester,
    ) async {
      useViewSize(tester, const Size(390, 800));
      await show(tester, upcoming(6));
      await tester.pumpAndSettle();

      final next = find.byKey(BgeShelf.nextKey);
      expect(tester.widget<IconButton>(next).tooltip, 'Next events');
      expect(
        tester.widget<IconButton>(find.byKey(BgeShelf.previousKey)).tooltip,
        'Previous events',
      );

      await tester.tap(next);
      await tester.pumpAndSettle();

      expect(rowPosition(tester).pixels, greaterThan(0));
    });

    testWidgets('cards share one height', (tester) async {
      await show(
        tester,
        [
          item(
            'e-full',
            location: 'Back room',
            householdId: 'h-1',
            occurrences: [confirmed('o', day(24))],
            attendance: attendance(EventParticipationStatus.attending),
          ),
          item('e-bare', occurrences: [confirmed('o', day(25))]),
        ],
        households: () => Stream.value([
          Household(
            id: 'h-1',
            name: 'The Smiths',
            createdAt: now,
            updatedAt: now,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: rowOf('e-full'),
          matching: find.text('Back room · The Smiths · Going'),
        ),
        findsOneWidget,
      );
      // The title and the date line, and no empty line under them.
      expect(
        find.descendant(of: rowOf('e-bare'), matching: find.byType(Text)),
        findsNWidgets(2),
      );
      expect(
        tester.getSize(rowOf('e-bare')).height,
        tester.getSize(rowOf('e-full')).height,
      );
    });

    testWidgets("the user's own event arriving returns the row to its start "
        "and keeps the link's focus", (tester) async {
      useViewSize(tester, const Size(390, 800));
      remote.browse = (_) => browsePage(offered(6));
      await show(tester, const []);
      await tester.pumpAndSettle();
      rowPosition(tester).jumpTo(300);
      Focus.of(tester.element(find.text(_yourEvents))).requestFocus();
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus;

      // Enough to overflow too, so that the row could have stayed where it was.
      items.add(upcoming(6));
      await settle(tester);
      await tester.pumpAndSettle();

      expect(rowOf('e-up-0'), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.fallbackNoteKey), findsNothing);
      expect(rowPosition(tester).pixels, 0);
      expect(FocusManager.instance.primaryFocus, same(focused));
    });

    testWidgets('tabbing to the last card brings it into view', (tester) async {
      useViewSize(tester, const Size(390, 800));
      await show(tester, upcoming(10), onOpen: (_, _) {});
      await tester.pumpAndSettle();
      final last = rowOf('e-up-9');
      expect(
        tester.getRect(last).left,
        greaterThan(tester.getRect(row()).right),
      );

      for (var i = 0; i < 40 && !focusIn(tester, last); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(focusIn(tester, last), isTrue, reason: 'never reached by tabbing');
      final viewport = tester.getRect(row());
      final card = tester.getRect(last);
      expect(card.left, greaterThanOrEqualTo(viewport.left));
      expect(card.right, lessThanOrEqualTo(viewport.right));
    });

    testWidgets("the heading starts at the section's start edge", (
      tester,
    ) async {
      await show(tester, upcoming(1));

      expect(
        tester.getTopLeft(find.byKey(UpcomingEventsSection.headingKey)).dx,
        tester.getTopLeft(find.byType(UpcomingEventsSection)).dx,
      );
    });
  });

  group('the first fill', () {
    testWidgets('no fetch while the first hydrate fills an empty cache', (
      tester,
    ) async {
      status.started();
      await tester.pumpWidget(harness());
      items.add(const []);
      await settle(tester);

      expect(remote.browseRequests, isEmpty);
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsOneWidget);
      expect(find.text(_yourEvents), findsOneWidget);

      status.finished(EventHydrateOutcome.complete);
      await settle(tester);

      expect(remote.browseRequests, hasLength(1));
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsNothing);
    });

    testWidgets('a cache answering at once still waits for the first fill', (
      tester,
    ) async {
      when(repository.watchAttendingEventListItems)
          .thenAnswer((_) => Stream.value(const []));
      status.started();

      await tester.pumpWidget(harness());
      await settle(tester);

      expect(remote.browseRequests, isEmpty);
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsOneWidget);
    });

    testWidgets('no fetch while a page with nothing upcoming is all that has '
        'landed', (tester) async {
      remote.browse = (_) => browsePage(offered(1));
      status.started();
      await tester.pumpWidget(harness());
      // The list is ordered by creation, so an upcoming event can be pages on.
      items.add([item('e-plan')]);
      await settle(tester);

      expect(remote.browseRequests, isEmpty);
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsOneWidget);
      expect(find.text(_note), findsNothing);
      expect(find.text(_empty), findsNothing);

      items.add([item('e-plan'), ...upcoming(1)]);
      await settle(tester);

      expect(rowOf('e-up-0'), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsNothing);

      status.finished(EventHydrateOutcome.complete);
      await settle(tester);

      expect(remote.browseRequests, isEmpty);
    });

    testWidgets('the fallback reads once that pass lands with nothing '
        'upcoming', (tester) async {
      remote.browse = (_) => browsePage(offered(1));
      status.started();
      await tester.pumpWidget(harness());
      items.add([item('e-plan')]);
      await settle(tester);

      status.finished(EventHydrateOutcome.complete);
      await settle(tester);

      expect(remote.browseRequests, hasLength(1));
      expect(rowOf('e-offer-0'), findsOneWidget);
      expect(find.text(_note), findsOneWidget);
    });

    testWidgets('with only a cancelled upcoming event, the fallback reads', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(1));

      await show(tester, [
        _cancelled(item('e-off', occurrences: [confirmed('o', day(25))])),
      ]);

      expect(remote.browseRequests, hasLength(1));
      expect(rowOf('e-off'), findsNothing);
      expect(rowOf('e-offer-0'), findsOneWidget);
      expect(find.text(_note), findsOneWidget);
    });

    testWidgets('own rows show at once, ahead of the pass ending', (
      tester,
    ) async {
      status.started();
      await tester.pumpWidget(harness());
      items.add(upcoming(1));
      await settle(tester);

      expect(rowOf('e-up-0'), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsNothing);
    });

    testWidgets('a re-check after a pass has landed leaves the fallback up', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, [item('e-plan')]);
      expect(rowOf('e-offer-0'), findsOneWidget);

      status.started();
      await settle(tester);

      expect(rowOf('e-offer-0'), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsNothing);
      expect(remote.browseRequests, hasLength(1));
    });

    testWidgets('a retried pass over a cache with nothing upcoming spins, as '
        'it does over an empty one', (tester) async {
      await tester.pumpWidget(harness());
      status.finished(EventHydrateOutcome.failed);
      await tester.pump();
      items.add([item('e-plan')]);
      await settle(tester);
      expect(find.text(_empty), findsOneWidget);

      status.started();
      await settle(tester);

      expect(remote.browseRequests, isEmpty);
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsOneWidget);
      expect(find.text(_empty), findsNothing);
    });

    testWidgets('announces the loading state', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(harness());

      expect(
        tester.getSemantics(find.bySemanticsLabel('Loading your events')),
        isSemantics(isLiveRegion: true),
      );

      handle.dispose();
    });

    testWidgets('announces the empty text that follows the spinner', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await show(tester, const []);

      expect(
        tester.getSemantics(find.byKey(UpcomingEventsSection.emptyKey)),
        isSemantics(label: _empty, isLiveRegion: true),
      );

      handle.dispose();
    });

    testWidgets('announces the note that follows the spinner', (tester) async {
      final handle = tester.ensureSemantics();
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, const []);

      expect(
        tester.getSemantics(find.byKey(UpcomingEventsSection.fallbackNoteKey)),
        isSemantics(label: _note, isLiveRegion: true),
      );

      handle.dispose();
    });

    testWidgets('the fallback read spins too, with no flash of empty', (
      tester,
    ) async {
      final answer = Completer<PaginatedResult<EventSnapshot>>();
      remote.browse = (_) => answer.future;

      await show(tester, const []);

      expect(find.byKey(UpcomingEventsSection.loadingKey), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.emptyKey), findsNothing);

      answer.complete(browsePage(offered(1)));
      await settle(tester);

      expect(find.byKey(UpcomingEventsSection.loadingKey), findsNothing);
      expect(rowOf('e-offer-0'), findsOneWidget);
    });
  });

  group('the fallback', () {
    testWidgets('rows, note and Your events link', (tester) async {
      remote.browse = (_) => browsePage(offered(3));

      await show(tester, const []);

      for (var n = 0; n < 3; n++) {
        expect(rowOf('e-offer-$n'), findsOneWidget);
      }
      expect(find.text(_note), findsOneWidget);
      expect(find.text(_yourEvents), findsOneWidget);
      expect(find.text(_seeAll), findsNothing);
      expect(find.text('Upcoming events'), findsOneWidget);
      for (final badge in ['Going', 'Maybe', 'Not going', 'Invited']) {
        expect(find.text(badge), findsNothing);
      }
      expect(
        find.textContaining(RegExp('join', caseSensitive: false)),
        findsNothing,
      );
    });

    testWidgets("the caller's own event arriving replaces the fallback, and a "
        'late answer is dropped', (tester) async {
      final answer = Completer<PaginatedResult<EventSnapshot>>();
      remote.browse = (_) => answer.future;
      await show(tester, const []);

      items.add(upcoming(1));
      await settle(tester);
      expect(rowOf('e-up-0'), findsOneWidget);
      expect(find.text(_seeAll), findsOneWidget);

      answer.complete(browsePage(offered(1)));
      await settle(tester);

      expect(rowOf('e-up-0'), findsOneWidget);
      expect(rowOf('e-offer-0'), findsNothing);
      expect(find.text(_note), findsNothing);
    });

    testWidgets("the caller's own event replaces rows already up", (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(2));
      await show(tester, const []);
      expect(rowOf('e-offer-0'), findsOneWidget);

      items.add(upcoming(1));
      await settle(tester);

      expect(rowOf('e-up-0'), findsOneWidget);
      expect(rowOf('e-offer-0'), findsNothing);
      expect(find.text(_note), findsNothing);
    });

    testWidgets('losing the last own event reads the fallback', (tester) async {
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, upcoming(1));
      expect(remote.browseRequests, isEmpty);

      items.add(const []);
      await settle(tester);

      expect(remote.browseRequests, hasLength(1));
      expect(rowOf('e-offer-0'), findsOneWidget);
    });

    testWidgets('no rows either way: the empty text and Your events link', (
      tester,
    ) async {
      await show(tester, const []);

      expect(find.byKey(UpcomingEventsSection.emptyKey), findsOneWidget);
      expect(find.text(_empty), findsOneWidget);
      expect(find.text(_yourEvents), findsOneWidget);
      expect(find.text(_note), findsNothing);
    });

    testWidgets('a failed read: the empty text, not an error', (tester) async {
      remote.browse = (_) => throw const EventRemoteTransientException('down');

      await show(tester, const []);

      expect(find.text(_empty), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.errorKey), findsNothing);
    });

    testWidgets('no remote: the empty text', (tester) async {
      await tester.pumpWidget(harness(hasRemote: false));
      status.finished(EventHydrateOutcome.complete);
      items.add(const []);
      await settle(tester);

      expect(find.text(_empty), findsOneWidget);
    });

    testWidgets('offline: the empty text and no request', (tester) async {
      connectivity.current = ConnectivityState.offline;

      await show(tester, const []);

      expect(find.text(_empty), findsOneWidget);
      expect(remote.browseRequests, isEmpty);
    });

    testWidgets(
      'rows clear offline, and come back online with no user action',
      (tester) async {
        remote.browse = (_) => browsePage(offered(1));
        await show(tester, const []);
        expect(rowOf('e-offer-0'), findsOneWidget);

        connectivity.change(ConnectivityState.offline);
        await settle(tester);
        expect(rowOf('e-offer-0'), findsNothing);
        expect(find.text(_empty), findsOneWidget);

        connectivity.change(ConnectivityState.online);
        await settle(tester);
        expect(rowOf('e-offer-0'), findsOneWidget);
      },
    );

    testWidgets('reads again when uncovered', (tester) async {
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, const []);
      expect(remote.browseRequests, hasLength(1));

      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(remote.browseRequests, hasLength(2));
    });

    testWidgets('a re-read that fails leaves the rows and their focus', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, const [], onOpen: (_, _) {});
      final title = find.descendant(
        of: rowOf('e-offer-0'),
        matching: find.byType(Text),
      );
      Focus.of(tester.element(title.first)).requestFocus();
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;

      remote.browse = (_) => throw const EventRemoteTransientException('down');
      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(remote.browseRequests, hasLength(2));
      expect(rowOf('e-offer-0'), findsOneWidget);
      expect(find.text(_note), findsOneWidget);
      expect(find.text(_empty), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(focused));
    });

    testWidgets('uncovered with own events reads nothing', (tester) async {
      await show(tester, upcoming(1));

      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(remote.browseRequests, isEmpty);
    });

    testWidgets('never writes the cache', (tester) async {
      remote.browse = (_) => browsePage(offered(3));

      await show(tester, const []);
      expect(rowOf('e-offer-0'), findsOneWidget);

      verifyNever(
        () => repository.cacheEvents(any(), source: any(named: 'source')),
      );
      verifyNever(
        () => repository.cacheEvent(any(), source: any(named: 'source')),
      );
    });

    testWidgets('unmounting mid-read throws nothing', (tester) async {
      final answer = Completer<PaginatedResult<EventSnapshot>>();
      remote.browse = (_) => answer.future;
      await show(tester, const []);

      await tester.pumpWidget(const SizedBox());
      answer.complete(browsePage(offered(1)));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('the cache', () {
    testWidgets('a failed cache read: the error banner and retry', (
      tester,
    ) async {
      var retries = 0;
      await tester.pumpWidget(harness(onRetry: () async => retries++));
      items.addError(StateError('no read'));
      await settle(tester);

      expect(find.byKey(UpcomingEventsSection.errorKey), findsOneWidget);
      expect(find.text("Your events couldn't be read."), findsOneWidget);
      expect(find.text(_yourEvents), findsOneWidget);
      expect(remote.browseRequests, isEmpty);

      await tester.tap(find.byKey(UpcomingEventsSection.retryKey));
      await settle(tester);

      expect(retries, 1);
      expect(remote.browseRequests, isEmpty);
    });

    testWidgets('a failed cache read with nothing to retry offers no button', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      items.addError(StateError('no read'));
      await settle(tester);

      expect(find.byKey(UpcomingEventsSection.errorKey), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.retryKey), findsNothing);
    });

    testWidgets('a failed cache read takes the place of fallback rows', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, const []);
      expect(rowOf('e-offer-0'), findsOneWidget);

      items.addError(StateError('no read'));
      await settle(tester);

      expect(rowOf('e-offer-0'), findsNothing);
      expect(find.text(_note), findsNothing);
      expect(find.byKey(UpcomingEventsSection.errorKey), findsOneWidget);
    });

    testWidgets('a failed hydrate over cached rows draws no banner', (
      tester,
    ) async {
      await tester.pumpWidget(harness(onRetry: () async {}));
      status.finished(EventHydrateOutcome.failed);
      await tester.pump();
      items.add(upcoming(1));
      await settle(tester);

      expect(rowOf('e-up-0'), findsOneWidget);
      expect(find.text(_refreshFailed), findsNothing);
      expect(find.byKey(UpcomingEventsSection.errorKey), findsNothing);
    });

    testWidgets("a failed first pass over an empty cache doesn't claim the "
        "caller isn't going to anything", (tester) async {
      // The caller may have events that pass never reached. A failure confirms
      // nothing, so the fallback's note would be a false statement about them.
      remote.browse = (_) => browsePage(offered(1));
      await tester.pumpWidget(harness(onRetry: () async {}));
      status.finished(EventHydrateOutcome.failed);
      await tester.pump();
      items.add(const []);
      await settle(tester);

      expect(remote.browseRequests, isEmpty);
      expect(rowOf('e-offer-0'), findsNothing);
      expect(find.text(_note), findsNothing);
      expect(find.text(_empty), findsOneWidget);
      expect(find.text(_yourEvents), findsOneWidget);
      expect(find.text(_refreshFailed), findsNothing);
      expect(find.byKey(UpcomingEventsSection.loadingKey), findsNothing);
    });

    testWidgets('the same holds over a cache with nothing upcoming', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      status.finished(EventHydrateOutcome.failed);
      await tester.pump();
      items.add([item('e-plan')]);
      await settle(tester);

      expect(remote.browseRequests, isEmpty);
      expect(find.text(_empty), findsOneWidget);
    });

    testWidgets('a pass that lands after a failure reads the fallback', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(1));
      await tester.pumpWidget(harness());
      status.finished(EventHydrateOutcome.failed);
      await tester.pump();
      items.add(const []);
      await settle(tester);
      expect(remote.browseRequests, isEmpty);

      status.started();
      await settle(tester);
      expect(remote.browseRequests, isEmpty);

      status.finished(EventHydrateOutcome.complete);
      await settle(tester);

      expect(remote.browseRequests, hasLength(1));
      expect(rowOf('e-offer-0'), findsOneWidget);
      expect(find.text(_note), findsOneWidget);
    });

    testWidgets('a pass that fails later takes the fallback down with it', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, const []);
      expect(rowOf('e-offer-0'), findsOneWidget);

      status.started();
      status.finished(EventHydrateOutcome.failed);
      await settle(tester);

      expect(rowOf('e-offer-0'), findsNothing);
      expect(find.text(_note), findsNothing);
      expect(find.text(_empty), findsOneWidget);
    });
  });

  group('actions', () {
    testWidgets('tapping a row calls onOpen with its id', (tester) async {
      final opened = <String>[];
      await show(tester, upcoming(1), onOpen: (_, id) => opened.add(id));

      await tester.tap(rowOf('e-up-0'));

      expect(opened, ['e-up-0']);
    });

    testWidgets('tapping a fallback row calls onOpen with its id', (
      tester,
    ) async {
      final opened = <String>[];
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, const [], onOpen: (_, id) => opened.add(id));

      await tester.tap(rowOf('e-offer-0'));

      expect(opened, ['e-offer-0']);
    });

    testWidgets('the link calls onOpenEvents with own events', (tester) async {
      var opened = 0;
      await show(tester, upcoming(1), onOpenEvents: (_) => opened++);

      await tester.tap(find.byKey(UpcomingEventsSection.linkKey));

      expect(opened, 1);
    });

    testWidgets('the link calls onOpenEvents with fallback rows', (
      tester,
    ) async {
      var opened = 0;
      remote.browse = (_) => browsePage(offered(1));
      await show(tester, const [], onOpenEvents: (_) => opened++);

      await tester.tap(find.byKey(UpcomingEventsSection.linkKey));

      expect(opened, 1);
    });

    testWidgets('the link calls onOpenEvents when empty', (tester) async {
      var opened = 0;
      await show(tester, const [], onOpenEvents: (_) => opened++);

      await tester.tap(find.byKey(UpcomingEventsSection.linkKey));

      expect(opened, 1);
    });

    testWidgets('the link keeps focus as its words change', (tester) async {
      await show(tester, const []);
      final link = find.byKey(UpcomingEventsSection.linkKey);
      Focus.of(tester.element(find.text(_yourEvents))).requestFocus();
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;

      items.add(upcoming(1));
      await settle(tester);

      expect(link, findsOneWidget);
      expect(find.text(_seeAll), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(focused));
    });
  });

  group('accessibility', () {
    testWidgets('the heading is a header in semantics', (tester) async {
      await show(tester, upcoming(1));

      expect(
        tester.getSemantics(find.text('Upcoming events')),
        isSemantics(isHeader: true),
      );
    });

    testWidgets("the link's spoken label is See all your events", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await show(tester, upcoming(1));

      expect(find.bySemanticsLabel('See all your events'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^See all$')), findsNothing);

      handle.dispose();
    });

    for (final (name, own) in [('own events', true), ('fallback', false)]) {
      testWidgets('holds at 320dp and 2.0 text with $name', (tester) async {
        useViewSize(tester, const Size(320, 480));
        remote.browse = (_) => browsePage(offered(3));

        await show(
          tester,
          own ? upcoming(3) : const [],
          textScaler: const TextScaler.linear(2),
        );

        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byKey(UpcomingEventsSection.linkKey)).right,
          lessThanOrEqualTo(320),
        );
        // One card fills the row, and the next button says there are more.
        expect(
          tester.getSize(rowOf(own ? 'e-up-0' : 'e-offer-0')).width,
          tester.getSize(row()).width,
        );
        expect(find.byKey(BgeShelf.nextKey), findsOneWidget);
      });
    }
  });

  // Home composes this section in `BgeApp`, so `HomeScreen`'s own audit
  // hosts a placeholder in its place; the section is audited here, in a
  // page as home's column holds it (#50).
  group('accessibility audit', () {
    Widget build(ThemeData theme, TextScaler textScaler) => harness(
      theme: theme,
      textScaler: textScaler,
      onOpen: (_, _) {},
      onRetry: () async {},
    );

    /// The cache answers [rows], with the hydrate settled.
    Future<void> showRows(WidgetTester tester, List<EventListItem> rows) async {
      status.finished(EventHydrateOutcome.complete);
      items.add(rows);
      await tester.pumpAndSettle();
    }

    // The audit's 320dp × 2.0 cells are only worth running if the harness
    // passes the scale and theme on to the section.
    testWidgets('the harness applies the theme and the text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        build(BgeTheme.dark(), const TextScaler.linear(2)),
      );

      final section = find.byType(UpcomingEventsSection);
      expect(MediaQuery.textScalerOf(tester.element(section)).scale(10), 20);
      expect(Theme.of(tester.element(section)).brightness, Brightness.dark);
    });

    // The first hydrate is filling an empty cache: the spinner never
    // settles.
    auditScreen(
      'loading',
      build: build,
      arrange: (tester) async {
        status.started();
        items.add(const []);
        await settle(tester);
        expect(find.byKey(UpcomingEventsSection.loadingKey), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'ready',
      build: build,
      arrange: (tester) async {
        await showRows(tester, upcoming(3));
        expect(rowOf('e-up-0'), findsOneWidget);
        expect(find.text(_seeAll), findsOneWidget);
      },
    );

    // Nothing of the user's own upcoming: what's coming up that they could
    // see, under its note.
    auditScreen(
      'ready, suggested events',
      build: build,
      arrange: (tester) async {
        remote.browse = (_) => browsePage(offered(3));
        await showRows(tester, const []);
        expect(rowOf('e-offer-0'), findsOneWidget);
        expect(find.text(_note), findsOneWidget);
      },
    );

    // At 320dp × 2.0 the note pushes the card's foot below the fold.
    auditScreen(
      'ready, suggested events, scrolled to the end',
      build: build,
      arrange: (tester) async {
        remote.browse = (_) => browsePage(offered(3));
        await showRows(tester, const []);
        await scrollPageToEnd(tester);
      },
    );

    auditScreen(
      'empty',
      build: build,
      arrange: (tester) async {
        await showRows(tester, const []);
        expect(find.byKey(UpcomingEventsSection.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure',
      build: build,
      arrange: (tester) async {
        items.addError(StateError('no read'));
        await tester.pumpAndSettle();
        expect(find.byKey(UpcomingEventsSection.errorKey), findsOneWidget);
        expect(find.byKey(UpcomingEventsSection.retryKey), findsOneWidget);
      },
    );
  });
}
