import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
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
    TextScaler textScaler = TextScaler.noScaling,
    bool hasRemote = true,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    theme: BgeTheme.light(),
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
  }) async {
    await tester.pumpWidget(
      harness(
        onOpenEvents: onOpenEvents,
        onOpen: onOpen,
        textScaler: textScaler,
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

  group('own events', () {
    testWidgets('at most 3 rows, soonest first, with the See all link', (
      tester,
    ) async {
      await show(tester, upcoming(5).reversed.toList());

      final tops = [
        for (var n = 0; n < 3; n++) tester.getTopLeft(rowOf('e-up-$n')).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet(), hasLength(3));
      expect(rowOf('e-up-3'), findsNothing);
      expect(rowOf('e-up-4'), findsNothing);
      expect(UpcomingEventsSection.rowCap, 3);

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

    testWidgets('a separator follows every row but the last', (tester) async {
      await show(tester, upcoming(2));

      expect(
        find.descendant(of: rowOf('e-up-0'), matching: find.byType(Divider)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rowOf('e-up-1'), matching: find.byType(Divider)),
        findsNothing,
      );
    });

    testWidgets('planning and past events alone count as no upcoming events', (
      tester,
    ) async {
      remote.browse = (_) => browsePage(offered(1));

      await show(tester, [
        item('e-plan'),
        item('e-past', occurrences: [confirmed('o', day(20))]),
      ]);

      expect(remote.browseRequests, [(page: 1, limit: 3)]);
      expect(rowOf('e-offer-0'), findsOneWidget);
      expect(rowOf('e-plan'), findsNothing);
      expect(rowOf('e-past'), findsNothing);
      // True of someone hosting an event with no date, unlike "not going to
      // anything".
      expect(find.text(_note), findsOneWidget);
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

        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byKey(UpcomingEventsSection.linkKey)).right,
          lessThanOrEqualTo(320),
        );
      });
    }
  });
}
