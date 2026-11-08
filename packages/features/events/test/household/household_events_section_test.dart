import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

class _MockEventRepository extends Mock implements EventRepository {}

/// A household's passes as the section sees them: a real status the test
/// drives, and a record of every household [refresh] and
/// [refreshAfterChange] named. A [refresh] while a pass runs joins it, and a
/// [refreshAfterChange] waits it out and starts another, as the real sync's
/// do.
class _FakeSync implements HouseholdEventsSync {
  final status = HydrationStatus<HouseholdEventsOutcome>(
    landed: (outcome) => outcome != HouseholdEventsOutcome.failed,
  );

  final refreshes = <String>[];
  final afterChanges = <String>[];
  final watched = <String>[];

  Completer<void>? _pass;

  /// Ends the running pass with [outcome].
  void finish(HouseholdEventsOutcome outcome) {
    status.finished(outcome);
    _pass?.complete();
    _pass = null;
  }

  @override
  Stream<Hydration> watch(String householdId) {
    watched.add(householdId);
    return status.watch();
  }

  @override
  Future<void> refresh(String householdId) {
    refreshes.add(householdId);
    final running = _pass;
    if (running != null) return running.future;
    status.started();
    return (_pass = Completer<void>()).future;
  }

  @override
  Future<void> refreshAfterChange(String householdId) async {
    afterChanges.add(householdId);
    await _pass?.future;
    status.started();
    await (_pass = Completer<void>()).future;
  }

  @override
  Future<void> close() => status.close();
}

/// [base] cancelled, its dates with it (#502).
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

const _empty = 'No upcoming events with a confirmed date.';
const _refreshFailed =
    "Couldn't refresh this household's events. What's shown may be out of "
    'date.';
const _loadFailed = "Couldn't load this household's events.";
const _refreshing = 'Refreshing\u{2026}';

/// A household's upcoming events (#503): the upcoming rule over the cached
/// household rows, the read on open, and the states around them.
void main() {
  final start = DateTime.utc(2026, 10, 23, 18);
  late DateTime clock;

  late _MockEventRepository repository;
  late StreamController<List<EventListItem>> items;
  late _FakeSync sync;
  late GlobalKey<NavigatorState> navigatorKey;

  setUp(() {
    navigatorKey = GlobalKey<NavigatorState>();
    clock = start;
    repository = _MockEventRepository();
    items = StreamController<List<EventListItem>>.broadcast();
    sync = _FakeSync();
    when(() => repository.watchHouseholdEventListItems('h-1'))
        .thenAnswer((_) => items.stream);
  });

  tearDown(() {
    unawaited(items.close());
    unawaited(sync.close());
  });

  Widget harness({
    bool withSync = true,
    void Function(BuildContext context, String eventId)? onOpen,
    TextScaler? textScaler,
    ThemeData? theme,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    // No override unless a test sets one, so an audit cell's own scale
    // reaches the section (#767).
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
    home: BgePage(
      width: BgePageWidth.pane,
      // The column the household screen puts it in, under its heading.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HouseholdEventsSection(
            repository: repository,
            householdId: 'h-1',
            sync: withSync ? sync : null,
            onOpen: onOpen,
            now: () => clock,
          ),
        ],
      ),
    ),
  );

  /// Opens the section, then caches [rows] and lands its pass with
  /// [outcome].
  Future<void> show(
    WidgetTester tester,
    List<EventListItem> rows, {
    HouseholdEventsOutcome outcome = HouseholdEventsOutcome.complete,
    void Function(BuildContext context, String eventId)? onOpen,
  }) async {
    await tester.pumpWidget(harness(onOpen: onOpen));
    sync.finish(outcome);
    items.add(rows);
    await tester.pump();
  }

  /// An upcoming event in this household, starting on [day] of the month.
  EventListItem upcoming(String id, int day, {String? title}) => item(
    id,
    title: title ?? 'Game night $id',
    householdId: 'h-1',
    occurrences: [confirmed('o-$id', DateTime.utc(2026, 10, day, 19))],
  );

  Finder rowOf(String id) => find.byKey(HouseholdEventsSection.rowKey(id));

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

  testWidgets('reads the household on open', (tester) async {
    await tester.pumpWidget(harness());

    expect(sync.refreshes, ['h-1']);
    expect(sync.watched, ['h-1']);
    verify(() => repository.watchHouseholdEventListItems('h-1')).called(1);
    verifyNever(repository.watchAttendingEventListItems);
  });

  /// Pushes an opaque page over the section, then pops it.
  Future<void> coverAndUncover(WidgetTester tester) async {
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    expect(sync.refreshes, hasLength(1), reason: 'covering it reads nothing');
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('reads the household again when uncovered', (tester) async {
    await show(tester, [upcoming('e-1', 30)]);
    expect(sync.refreshes, ['h-1']);

    await coverAndUncover(tester);

    // A pass that starts now, not the open's joined: that one may predate an
    // event made while the section was covered.
    expect(sync.refreshes, ['h-1']);
    expect(sync.afterChanges, ['h-1']);
    expect(rowOf('e-1'), findsOneWidget);
  });

  testWidgets('shows only upcoming events, soonest first', (tester) async {
    await show(tester, [
      upcoming('e-2', 30),
      item(
        'e-past',
        title: 'Last week',
        householdId: 'h-1',
        occurrences: [confirmed('o-past', DateTime.utc(2026, 10, 16, 19))],
      ),
      upcoming('e-1', 25),
      item('e-plan', title: 'Someday', householdId: 'h-1'),
    ]);

    expect(rowOf('e-1'), findsOneWidget);
    expect(rowOf('e-2'), findsOneWidget);
    expect(rowOf('e-past'), findsNothing);
    expect(rowOf('e-plan'), findsNothing);
    expect(find.text('Last week'), findsNothing);
    expect(find.text('Someday'), findsNothing);
    expect(
      tester.getTopLeft(rowOf('e-1')).dy,
      lessThan(tester.getTopLeft(rowOf('e-2')).dy),
    );
  });

  group('a cancelled event', () {
    // The household's list never sends one (#503). A cached one, as one the
    // user has just cancelled, waits for a pass to purge it.
    testWidgets('a cached cancelled upcoming event is not shown', (
      tester,
    ) async {
      await show(tester, [
        upcoming('e-1', 25),
        _cancelled(upcoming('e-2', 27)),
      ]);

      expect(rowOf('e-1'), findsOneWidget);
      expect(rowOf('e-2'), findsNothing);
      expect(find.textContaining('Cancelled'), findsNothing);
    });

    testWidgets('when it is the only one, the empty text shows', (
      tester,
    ) async {
      await show(tester, [_cancelled(upcoming('e-2', 27))]);

      expect(rowOf('e-2'), findsNothing);
      expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
    });

    testWidgets('alone during the first pass, it is loading, not a row', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      items.add([_cancelled(upcoming('e-2', 27))]);
      await tester.pump();

      expect(rowOf('e-2'), findsNothing);
      expect(find.byKey(HouseholdEventsSection.loadingKey), findsOneWidget);
      expect(find.byKey(HouseholdEventsSection.emptyKey), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(HouseholdEventsSection.loadingKey),
          matching: find.bySemanticsLabel("Loading this household's events"),
        ),
        findsOneWidget,
      );

      sync.finish(HouseholdEventsOutcome.complete);
      await tester.pump();

      expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
    });
  });

  testWidgets("a row shows the user's answer", (tester) async {
    await show(tester, [
      item(
        'e-1',
        householdId: 'h-1',
        occurrences: [confirmed('o-e-1', DateTime.utc(2026, 10, 25, 19))],
        attendance: const EventAttendance(
          attendeeId: 'att-me',
          status: EventParticipationStatus.attending,
        ),
      ),
    ]);

    expect(
      find.descendant(of: rowOf('e-1'), matching: find.textContaining('Going')),
      findsOneWidget,
    );
  });

  testWidgets('a row opens its event', (tester) async {
    final opened = <String>[];
    await show(tester, [
      upcoming('e-1', 25),
    ], onOpen: (_, eventId) => opened.add(eventId));

    await tester.tap(rowOf('e-1'));
    await tester.pump();

    expect(opened, ['e-1']);

    // With nowhere to open it, the row is content and not a button (#269).
    await tester.pumpWidget(const SizedBox());
    await show(tester, [upcoming('e-1', 25)]);

    expect(
      tester.getSemantics(rowOf('e-1')),
      isSemantics(isButton: false, hasTapAction: false, isFocusable: false),
    );
  });

  testWidgets('rows show no household name', (tester) async {
    // Every row is this household's, and the screen's heading says whose.
    await show(tester, [upcoming('e-1', 25)]);

    final tile = tester.widget<EventRowTile>(
      find.descendant(of: rowOf('e-1'), matching: find.byType(EventRowTile)),
    );
    expect(tile.row.householdName, isNull);
  });

  testWidgets('empty says no upcoming events with a confirmed date', (
    tester,
  ) async {
    await show(tester, const []);

    expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(HouseholdEventsSection.emptyKey)).data,
      _empty,
    );
    // It takes the place of the spinner, which said it was loading.
    expect(
      tester.getSemantics(find.byKey(HouseholdEventsSection.emptyKey)),
      isSemantics(label: _empty, isLiveRegion: true),
    );
    expect(find.byKey(HouseholdEventsSection.loadingKey), findsNothing);
  });

  group('the first pass', () {
    testWidgets('loading while the first pass runs and nothing is cached', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      expect(find.byKey(HouseholdEventsSection.loadingKey), findsOneWidget);

      items.add(const []);
      await tester.pump();

      expect(find.byKey(HouseholdEventsSection.loadingKey), findsOneWidget);
      expect(find.byKey(HouseholdEventsSection.emptyKey), findsNothing);
    });

    testWidgets(
      'loading while it runs over cached rows none of which is upcoming',
      (tester) async {
        // The pass may be about to write upcoming ones, so "no upcoming
        // events" would be a claim no pass has made.
        await tester.pumpWidget(harness());
        items.add([
          item(
            'e-past',
            householdId: 'h-1',
            occurrences: [confirmed('o-past', DateTime.utc(2026, 10, 16))],
          ),
          item('e-plan', householdId: 'h-1'),
        ]);
        await tester.pump();

        expect(find.byKey(HouseholdEventsSection.loadingKey), findsOneWidget);
        expect(find.byKey(HouseholdEventsSection.emptyKey), findsNothing);

        sync.finish(HouseholdEventsOutcome.complete);
        await tester.pump();

        expect(find.byKey(HouseholdEventsSection.loadingKey), findsNothing);
        expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
      },
    );

    testWidgets('cached upcoming rows show while it runs', (tester) async {
      await tester.pumpWidget(harness());
      items.add([upcoming('e-1', 25)]);
      await tester.pump();

      expect(rowOf('e-1'), findsOneWidget);
      expect(find.byKey(HouseholdEventsSection.loadingKey), findsNothing);
    });
  });

  group('a failed pass', () {
    testWidgets('a failed pass keeps the rows and offers a retry', (
      tester,
    ) async {
      await show(tester, [
        upcoming('e-1', 25),
      ], outcome: HouseholdEventsOutcome.failed);

      expect(rowOf('e-1'), findsOneWidget);
      expect(find.text(_refreshFailed), findsOneWidget);
      expect(
        find.byKey(HouseholdEventsSection.refreshRetryKey),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text(_refreshFailed)).dy,
        lessThan(tester.getTopLeft(rowOf('e-1')).dy),
      );

      await tester.tap(find.byKey(HouseholdEventsSection.refreshRetryKey));
      await tester.pump();

      expect(sync.refreshes, ['h-1', 'h-1']);
      expect(find.text(_refreshing), findsWidgets);
      expect(
        find.byKey(HouseholdEventsSection.refreshRetryKey),
        findsOneWidget,
      );

      sync.finish(HouseholdEventsOutcome.complete);
      await tester.pump();

      expect(find.byKey(HouseholdEventsSection.refreshRetryKey), findsNothing);
      expect(rowOf('e-1'), findsOneWidget);
    });

    testWidgets('a pass begun by uncovering leaves the banner as it was', (
      tester,
    ) async {
      await show(tester, [
        upcoming('e-1', 25),
      ], outcome: HouseholdEventsOutcome.failed);

      await coverAndUncover(tester);

      expect(sync.afterChanges, ['h-1']);
      expect(find.text(_refreshing), findsNothing);
      expect(find.text(_refreshFailed), findsOneWidget);
      expect(rowOf('e-1'), findsOneWidget);

      sync.finish(HouseholdEventsOutcome.complete);
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdEventsSection.refreshRetryKey), findsNothing);
      expect(rowOf('e-1'), findsOneWidget);
    });

    testWidgets(
      'with nothing upcoming, the warning sits above the empty text',
      (tester) async {
        await show(tester, const [], outcome: HouseholdEventsOutcome.failed);

        expect(find.text(_refreshFailed), findsOneWidget);
        expect(
          find.byKey(HouseholdEventsSection.refreshRetryKey),
          findsOneWidget,
        );
        expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
        expect(
          tester.getTopLeft(find.text(_refreshFailed)).dy,
          lessThan(
            tester.getTopLeft(find.byKey(HouseholdEventsSection.emptyKey)).dy,
          ),
        );
      },
    );

    testWidgets(
      'a retry over rows none of which is upcoming keeps the banner and its '
      'focus',
      (tester) async {
        // A first pass that failed confirms nothing, so its retry is a first
        // fill: the spinner takes the empty text's place, under the banner
        // that says the retry is running.
        await show(tester, [
          item('e-plan', householdId: 'h-1'),
        ], outcome: HouseholdEventsOutcome.failed);
        final retry = find.byKey(HouseholdEventsSection.refreshRetryKey);

        for (var i = 0; i < 10 && !focusIn(tester, retry); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(focusIn(tester, retry), isTrue, reason: 'never reached');

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(sync.refreshes, ['h-1', 'h-1']);
        expect(find.byKey(HouseholdEventsSection.loadingKey), findsOneWidget);
        expect(find.byKey(HouseholdEventsSection.emptyKey), findsNothing);
        expect(find.text(_refreshing), findsWidgets);
        expect(focusIn(tester, retry), isTrue);

        sync.finish(HouseholdEventsOutcome.complete);
        await tester.pump();

        expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
      },
    );
  });

  group('a failed read', () {
    testWidgets('a failed read shows the error with a retry', (tester) async {
      await tester.pumpWidget(harness());
      sync.finish(HouseholdEventsOutcome.complete);
      items.addError(StateError('the cache could not be read'));
      await tester.pump();

      expect(find.byKey(HouseholdEventsSection.errorKey), findsOneWidget);
      expect(find.byKey(HouseholdEventsSection.errorRetryKey), findsOneWidget);
      expect(find.text(_loadFailed), findsOneWidget);

      await tester.tap(find.byKey(HouseholdEventsSection.errorRetryKey));
      await tester.pump();

      // The pass runs again, and the household's events are read again.
      expect(sync.refreshes, ['h-1', 'h-1']);
      verify(() => repository.watchHouseholdEventListItems('h-1')).called(2);

      items.add([upcoming('e-1', 25)]);
      await tester.pump();

      expect(rowOf('e-1'), findsOneWidget);
      expect(find.byKey(HouseholdEventsSection.errorKey), findsNothing);
    });
  });

  testWidgets(
    'an event whose last date ends while open drops at that instant',
    (tester) async {
      await show(tester, [
        item(
          'e-1',
          householdId: 'h-1',
          occurrences: [
            confirmed(
              'o-1',
              start.subtract(const Duration(hours: 1)),
              end: start.add(const Duration(minutes: 1)),
            ),
          ],
        ),
      ]);
      expect(rowOf('e-1'), findsOneWidget);

      clock = start.add(const Duration(minutes: 1, seconds: 1));
      await tester.pump(const Duration(minutes: 1, seconds: 1));

      expect(rowOf('e-1'), findsNothing);
      expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
      // Nothing was read again for it.
      expect(sync.refreshes, ['h-1']);
    },
  );

  testWidgets('a row keeps its focus when one above it leaves', (tester) async {
    // Rows come from a cache a pass purges, so one can leave while the user
    // is on the next (#549).
    await show(tester, [
      upcoming('e-1', 25),
      upcoming('e-2', 30),
    ], onOpen: (_, _) {});

    for (var i = 0; i < 10 && !focusIn(tester, rowOf('e-2')); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focusIn(tester, rowOf('e-2')), isTrue, reason: 'never reached');

    items.add([upcoming('e-2', 30)]);
    await tester.pump();

    expect(rowOf('e-1'), findsNothing);
    expect(focusIn(tester, rowOf('e-2')), isTrue);
  });

  group('without a sync', () {
    testWidgets('without a sync it shows the cache and offers no retry', (
      tester,
    ) async {
      await tester.pumpWidget(harness(withSync: false));
      items.add([upcoming('e-1', 25)]);
      await tester.pump();

      expect(rowOf('e-1'), findsOneWidget);
      expect(find.byKey(HouseholdEventsSection.refreshRetryKey), findsNothing);
      expect(sync.refreshes, isEmpty);
    });

    testWidgets('an empty cache is empty, not loading', (tester) async {
      await tester.pumpWidget(harness(withSync: false));
      items.add(const []);
      await tester.pump();

      expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
    });

    testWidgets('a failed read says so, with no button', (tester) async {
      await tester.pumpWidget(harness(withSync: false));
      items.addError(StateError('the cache could not be read'));
      await tester.pump();

      expect(find.byKey(HouseholdEventsSection.errorKey), findsOneWidget);
      expect(find.byKey(HouseholdEventsSection.errorRetryKey), findsNothing);
    });
  });

  testWidgets('the banner and the rows lay out at 320dp and 2.0 text', (
    tester,
  ) async {
    useViewSize(tester, const Size(320, 800));
    await tester.pumpWidget(
      harness(onOpen: (_, _) {}, textScaler: const TextScaler.linear(2)),
    );
    sync.finish(HouseholdEventsOutcome.failed);
    items.add([
      upcoming('e-1', 25, title: 'A long evening of cooperative games'),
      upcoming('e-2', 30),
    ]);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(_refreshFailed), findsOneWidget);
    expect(rowOf('e-1'), findsOneWidget);
  });

  testWidgets('leaving stops reading the cache', (tester) async {
    await show(tester, [upcoming('e-1', 25)]);
    expect(items.hasListener, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(items.hasListener, isFalse);
  });

  // The household screen gets this section from `BgeApp`, so its own audit
  // stands a placeholder in its place. The section is audited here, in a
  // page as the household screen's column holds it (#50).
  group('accessibility audit', () {
    Widget build(ThemeData theme) => harness(theme: theme, onOpen: (_, _) {});

    /// Three upcoming rows, the first with the user's answer on it.
    List<EventListItem> rows() => [
      item(
        'e-1',
        title: 'Game night e-1',
        householdId: 'h-1',
        occurrences: [confirmed('o-e-1', DateTime.utc(2026, 10, 25, 19))],
        attendance: const EventAttendance(
          attendeeId: 'att-me',
          status: EventParticipationStatus.attending,
        ),
      ),
      upcoming('e-2', 27, title: 'A long evening of cooperative games'),
      upcoming('e-3', 30),
    ];

    /// Caches [rows] and lands the open's pass with [outcome].
    Future<void> showRows(
      WidgetTester tester,
      List<EventListItem> rows, {
      HouseholdEventsOutcome outcome = HouseholdEventsOutcome.complete,
    }) async {
      sync.finish(outcome);
      items.add(rows);
      await tester.pumpAndSettle();
    }

    // The open's pass runs and nothing is cached: the spinner never
    // settles.
    auditScreen(
      'loading',
      build: build,
      settle: false,
      arrange: (tester) async {
        items.add(const []);
        await tester.pump();
        expect(find.byKey(HouseholdEventsSection.loadingKey), findsOneWidget);
      },
    );

    auditScreen(
      'ready',
      build: build,
      arrange: (tester) async {
        await showRows(tester, rows());
        expect(rowOf('e-1'), findsOneWidget);
        expect(
          find.descendant(
            of: rowOf('e-1'),
            matching: find.textContaining('Going'),
          ),
          findsOneWidget,
        );
      },
    );

    // At 320dp × 2.0 the rows run below the fold.
    auditScreen(
      'ready, scrolled to the end',
      build: build,
      arrange: (tester) async {
        await showRows(tester, rows());
        await scrollPageToEnd(tester);
        expect(rowOf('e-3').hitTestable(), findsOneWidget);
      },
    );

    auditScreen(
      'empty',
      build: build,
      arrange: (tester) async {
        await showRows(tester, const []);
        expect(find.byKey(HouseholdEventsSection.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'refresh failed',
      build: build,
      arrange: (tester) async {
        await showRows(tester, rows(), outcome: HouseholdEventsOutcome.failed);
        expect(find.text(_refreshFailed), findsOneWidget);
        expect(
          find.byKey(HouseholdEventsSection.refreshRetryKey),
          findsOneWidget,
        );
      },
    );

    // The retry's pass never ends, so its spinner keeps going.
    auditScreen(
      'refreshing',
      build: build,
      settle: false,
      arrange: (tester) async {
        await showRows(tester, rows(), outcome: HouseholdEventsOutcome.failed);
        await tester.tap(find.byKey(HouseholdEventsSection.refreshRetryKey));
        await tester.pump();
        expect(sync.refreshes, ['h-1', 'h-1']);
        // The banner's copy and its button's label.
        expect(find.text(_refreshing), findsNWidgets(2));
      },
    );

    auditScreen(
      'failure',
      build: build,
      arrange: (tester) async {
        sync.finish(HouseholdEventsOutcome.complete);
        items.addError(StateError('the cache could not be read'));
        await tester.pumpAndSettle();
        expect(find.byKey(HouseholdEventsSection.errorKey), findsOneWidget);
        expect(
          find.byKey(HouseholdEventsSection.errorRetryKey),
          findsOneWidget,
        );
      },
    );

    // Without a sync, as the shell builds it where none is registered: the
    // failure alone, with no button.
    auditScreen(
      'failure, without retry',
      build: (theme) => harness(theme: theme, withSync: false),
      arrange: (tester) async {
        items.addError(StateError('the cache could not be read'));
        await tester.pumpAndSettle();
        expect(find.text(_loadFailed), findsOneWidget);
        expect(find.byKey(HouseholdEventsSection.errorRetryKey), findsNothing);
      },
    );
  });
}
