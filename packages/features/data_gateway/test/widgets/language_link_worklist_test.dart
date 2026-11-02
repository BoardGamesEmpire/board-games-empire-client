import 'dart:async';

import 'package:data_gateway/data_gateway.dart';
import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:flutter/foundation.dart'
    show
        FlutterMemoryAllocations,
        ObjectCreated,
        ObjectDisposed,
        ObjectEvent,
        precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart' show Bloc, BlocObserver;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_data_gateway_remote.dart';
import '../support/screen_input.dart';

/// Every event any bloc was sent, for what the screen can't show: an event the
/// bloc went on to drop.
final class _EventLog extends BlocObserver {
  final List<Object?> seen = [];

  @override
  void onEvent(Bloc<dynamic, dynamic> bloc, Object? event) {
    super.onEvent(bloc, event);
    seen.add(event);
  }
}

void main() {
  late FakeDataGatewayRemote remote;
  late DataGatewayAccess access;

  const waiting = LanguageLinkFilter.waiting;
  const ignoredFilter = LanguageLinkFilter.ignored;
  const resolvedFilter = LanguageLinkFilter.resolved;

  const czech = LanguageTagRef(id: 'tag_cs', tag: 'cs', name: 'Czech');
  const slovak = LanguageTagRef(id: 'tag_sk', tag: 'sk', name: 'Slovak');

  final a = languageLink('a');
  final b = languageLink('b');
  final c = languageLink('c');

  LanguageLink ignoredOf(LanguageLink link) =>
      link.copyWith(status: LanguageLinkStatus.ignored);

  // Not skipping what is offstage, because to a finder a sliver scrolled out
  // of the viewport is, and the worklist is at the foot of a long page.
  Finder filter(LanguageLinkFilter filter) =>
      find.byKey(LanguageLinkWorklist.filterKey(filter), skipOffstage: false);
  Finder row(String id) =>
      find.byKey(LanguageLinkWorklist.rowKey(id), skipOffstage: false);
  Finder menu(String id) =>
      find.byKey(LanguageLinkWorklist.menuKey(id), skipOffstage: false);
  final banner = find.byKey(
    LanguageLinkWorklist.outcomeKey,
    skipOffstage: false,
  );
  final moreButton = find.byKey(
    LanguageLinkWorklist.moreKey,
    skipOffstage: false,
  );
  final emptyText = find.byKey(
    LanguageLinkWorklist.emptyKey,
    skipOffstage: false,
  );
  final errorSurface = find.byKey(
    LanguageLinkWorklist.errorKey,
    skipOffstage: false,
  );
  final heading = find.text('Language names to review', skipOffstage: false);
  final refreshButton = find.byKey(DataGatewayDetailScreen.refreshKey);

  Finder textIn(Finder parent, String text) => find.descendant(
    of: parent,
    matching: find.text(text, skipOffstage: false),
    skipOffstage: false,
  );

  /// The icon a row's menu button shows, which keyboard focus lands around.
  Finder iconOf(Finder menu) => find.descendant(
    of: menu,
    matching: find.byType(Icon, skipOffstage: false),
    skipOffstage: false,
  );

  String readCall({LanguageLinkStatus? status, String id = 'dg_1'}) =>
      'fetchLanguageLinks($id, '
      '${status == null ? null : <LanguageLinkStatus>{status}}, 1)';
  Iterable<String> linkReads() =>
      remote.calls.where((call) => call.startsWith('fetchLanguageLinks'));
  Iterable<String> detailReads() =>
      remote.calls.where((call) => call.startsWith('fetchOne'));

  LanguageLinkFilter filterOf(Set<LanguageLinkStatus>? statuses) =>
      switch (statuses?.single) {
        null => waiting,
        LanguageLinkStatus.ignored => ignoredFilter,
        _ => resolvedFilter,
      };

  /// Answers every read with what [byFilter] holds for its filter, on one
  /// page, and says there is more when [hasMore].
  void listing(
    Map<LanguageLinkFilter, List<LanguageLink>> byFilter, {
    bool hasMore = false,
  }) => remote.onFetchLanguageLinks = (_, statuses, page, _) async =>
      linkPageOf(
        byFilter[filterOf(statuses)] ?? const [],
        page: page,
        hasMore: hasMore,
      );

  /// Answers each read with the next of [answers], and goes on answering with
  /// the last. A page is the answer, a future is waited on, and anything else
  /// is thrown.
  void reads(List<Object> answers) {
    var read = 0;
    remote.onFetchLanguageLinks = (_, _, _, _) {
      final answer = answers[read < answers.length ? read : answers.length - 1];
      read++;
      return switch (answer) {
        final PaginatedResult<LanguageLink> page => Future.value(page),
        final Future<PaginatedResult<LanguageLink>> pending => pending,
        _ => Future.error(answer),
      };
    };
  }

  /// Holds every ignore until the test answers it.
  Completer<LanguageLink> holdIgnores() {
    final held = Completer<LanguageLink>();
    remote.onIgnoreLanguageLink = (_, _) => held.future;
    return held;
  }

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = DataGatewayAccess(remote: remote);
    // A DataGateway with little to say, so the worklist sits high on the page.
    remote.onFetchOne = (id) async => gateway(id, name: 'BGG');
    remote.onFetchLanguageTags = (_, _, _) async => tagPageOf([czech, slovak]);
  });

  tearDown(() => access.dispose());

  Widget app(Widget home, {TextScaler textScaler = TextScaler.noScaling}) =>
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
        supportedLocales: DataGatewayLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: home,
      );

  /// Opens the screen on a view tall enough to show the whole worklist,
  /// unless the test gives a [size].
  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(800, 2400),
    TextScaler textScaler = TextScaler.noScaling,
    bool settle = true,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        DataGatewayDetailScreen(remote: remote, id: 'dg_1', access: access),
        textScaler: textScaler,
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await pumpEvent(tester);
      await tester.pump();
    }
  }

  /// Lets a menu, or a dialog opened from one, finish opening or closing,
  /// while the action it asked for runs: that row's spinner never settles.
  Future<void> letMenuClose(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  /// Opens the menu on [id]'s row with a tap, and chooses [item] from it.
  ///
  /// A `PopupMenuItem` hands its choice over once its menu has gone, so this
  /// lets the menu close before anything is asserted.
  Future<void> choose(WidgetTester tester, String id, Key item) async {
    await tester.ensureVisible(menu(id));
    await tester.pumpAndSettle();
    await tester.tap(menu(id));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(item));
    await letMenuClose(tester);
  }

  /// Chooses [item] from [id]'s menu as a keyboard user does: focus on the
  /// menu's button, Space opens the menu, the arrows go down to the item,
  /// and Enter chooses it.
  Future<void> chooseByKeyboard(
    WidgetTester tester,
    String id,
    Key item,
  ) async {
    await focusOn(tester, iconOf(menu(id)));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await letMenuClose(tester);
    for (var step = 0; step < 4; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      if (focusIsIn(tester, find.byKey(item))) break;
    }
    expect(focusIsIn(tester, find.byKey(item)), isTrue, reason: '$item');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await letMenuClose(tester);
  }

  /// Picks [tag] in the language picker that is open.
  Future<void> pick(WidgetTester tester, LanguageTagRef tag) async {
    await tester.tap(find.byKey(LanguageTagPickerDialog.rowKey(tag.id)));
    await letMenuClose(tester);
  }

  /// Scrolls the page until [target] is built, and then into view.
  Future<void> bringIntoView(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  /// Keyboard focus is on no control: on the page, or on nothing at all.
  bool focusOnNothing() {
    final focused = FocusManager.instance.primaryFocus;
    return focused == null || focused is FocusScopeNode;
  }

  ScrollPosition pagePosition(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  double pageOffset(WidgetTester tester) => pagePosition(tester).pixels;

  /// Moves the page as a user's scrolling does, and lets it lay out.
  Future<void> scrollPageTo(WidgetTester tester, double offset) async {
    pagePosition(tester).jumpTo(offset);
    await tester.pump();
  }

  /// Whether [rect] is inside the part of the page the user can see.
  bool rectOnScreen(WidgetTester tester, Rect rect) {
    final view = tester.getRect(find.byType(Scrollable).first);
    return rect.top >= view.top - precisionErrorTolerance &&
        rect.bottom <= view.bottom + precisionErrorTolerance;
  }

  /// Whether the control with keyboard focus can be seen.
  bool focusOnScreen(WidgetTester tester) =>
      rectOnScreen(tester, FocusManager.instance.primaryFocus!.rect);

  /// Puts [id]'s row at the foot of the view, where the footer arriving would
  /// cover it.
  Future<void> bringToFoot(WidgetTester tester, String id) async {
    await bringIntoView(tester, menu(id));
    await Scrollable.ensureVisible(tester.element(row(id)), alignment: 1);
    await tester.pumpAndSettle();
  }

  /// [id]'s action is running, and its row shows it.
  void expectBusy(WidgetTester tester, String id) {
    expect(menu(id), findsNothing);
    expect(
      find.descendant(
        of: row(id),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
  }

  group('the filters', () {
    testWidgets('waiting is selected first, and each filter reads its status', (
      tester,
    ) async {
      final x = languageLink('x', status: LanguageLinkStatus.ignored);
      final r = languageLink(
        'r',
        status: LanguageLinkStatus.resolved,
        tag: czech,
      );
      listing({
        waiting: [a],
        ignoredFilter: [x],
        resolvedFilter: [r],
      });
      await pumpScreen(tester);

      bool selected(LanguageLinkFilter of) =>
          tester.widget<FilterChip>(filter(of)).selected;

      expect(textIn(filter(waiting), 'Waiting'), findsOneWidget);
      expect(textIn(filter(ignoredFilter), 'Ignored'), findsOneWidget);
      expect(textIn(filter(resolvedFilter), 'Resolved'), findsOneWidget);
      expect(selected(waiting), isTrue);
      expect(selected(ignoredFilter), isFalse);
      expect(selected(resolvedFilter), isFalse);
      expect(linkReads(), [readCall()]);
      expect(row('a'), findsOneWidget);

      await press(tester, filter(ignoredFilter));
      await tester.pumpAndSettle();

      expect(linkReads().last, readCall(status: LanguageLinkStatus.ignored));
      expect(selected(ignoredFilter), isTrue);
      expect(selected(waiting), isFalse);
      expect(row('x'), findsOneWidget);
      expect(row('a'), findsNothing);

      await press(tester, filter(resolvedFilter));
      await tester.pumpAndSettle();

      expect(linkReads().last, readCall(status: LanguageLinkStatus.resolved));
      expect(selected(resolvedFilter), isTrue);
      expect(row('r'), findsOneWidget);
      expect(row('x'), findsNothing);
    });

    testWidgets('selected filter is exposed as selected to assistive tech', (
      tester,
    ) async {
      listing({});
      await pumpScreen(tester);

      expect(
        tester.getSemantics(filter(waiting)),
        isSemantics(isButton: true, isSelected: true, label: 'Waiting'),
      );
      expect(
        tester.getSemantics(filter(ignoredFilter)),
        isSemantics(isButton: true, isSelected: false, label: 'Ignored'),
      );

      await press(tester, filter(ignoredFilter));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(filter(ignoredFilter)),
        isSemantics(isButton: true, isSelected: true, label: 'Ignored'),
      );
      expect(
        tester.getSemantics(filter(waiting)),
        isSemantics(isButton: true, isSelected: false, label: 'Waiting'),
      );
    });

    testWidgets('the section heading is announced as a heading', (
      tester,
    ) async {
      listing({});
      await pumpScreen(tester);

      expect(
        tester.getSemantics(heading),
        isSemantics(isHeader: true, label: 'Language names to review'),
      );
    });
  });

  group('a row', () {
    testWidgets('two rows for one value in different formats say which is '
        'which, to the eye and to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      listing({
        waiting: [
          languageLink('i', value: 'en', format: LanguageCodeFormat.iso6391),
          languageLink('t', value: 'en', format: LanguageCodeFormat.ietfBcp47),
        ],
      });
      remote.onIgnoreLanguageLink = (_, id) async => languageLink(
        id,
        value: 'en',
        format: LanguageCodeFormat.iso6391,
      ).copyWith(status: LanguageLinkStatus.ignored);
      await pumpScreen(tester);

      expect(
        find.descendant(of: row('i'), matching: find.text('ISO 639-1 code')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row('t'), matching: find.text('language tag')),
        findsOneWidget,
      );
      expect(
        tester.widget<PopupMenuButton<LanguageLinkAction>>(menu('i')).tooltip,
        'Actions for en (ISO 639-1 code)',
      );
      expect(
        tester.widget<PopupMenuButton<LanguageLinkAction>>(menu('t')).tooltip,
        'Actions for en (language tag)',
      );

      await tester.tap(menu('i'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LanguageLinkWorklist.ignoreKey));
      await tester.pumpAndSettle();

      expect(
        tester.widget<BgeInlineBanner>(banner).message,
        'Ignored en (ISO 639-1 code).',
      );
      handle.dispose();
    });

    testWidgets('a row shows the native name and the tag the DataGateway '
        'supplied, each once and none that repeats the value', (tester) async {
      listing({
        waiting: [
          languageLink(
            'z',
            value: 'zho',
            suppliedName: 'Chinese',
            suppliedNativeName: '中文',
            suppliedIetfTag: 'zh-Hant',
          ),
          languageLink(
            'c',
            value: 'cs',
            suppliedName: 'Czech',
            suppliedNativeName: 'Czech',
            suppliedIetfTag: 'cs',
          ),
        ],
      });
      await pumpScreen(tester);

      expect(
        find.descendant(
          of: row('z'),
          matching: find.text('Chinese · 中文 · zh-Hant'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row('c'), matching: find.text('Czech')),
        findsOneWidget,
      );
    });

    testWidgets('a row shows what the DataGateway supplied, and its status', (
      tester,
    ) async {
      listing({
        waiting: [
          languageLink(
            'p',
            value: 'tlh',
            status: LanguageLinkStatus.pending,
            suppliedName: 'Klingon',
          ),
          // The same as the value: said once.
          languageLink('u', value: 'Klingon', suppliedName: 'Klingon'),
          languageLink('i', value: 'xx', status: LanguageLinkStatus.ignored),
          languageLink(
            'r',
            value: 'ces',
            status: LanguageLinkStatus.resolved,
            tag: czech,
            suppliedName: 'Czech',
          ),
          languageLink(
            'k',
            value: 'qq',
            status: LanguageLinkStatus.unknown,
            suppliedName: 'Mystery',
          ),
        ],
      });
      await pumpScreen(tester);

      List<String?> textsOf(String id) => [
        for (final text in tester.widgetList<Text>(
          find.descendant(
            of: row(id),
            matching: find.byType(Text),
            skipOffstage: false,
          ),
        ))
          text.data,
      ];

      expect(textsOf('p'), ['tlh', 'Klingon', 'Waiting for review']);
      expect(textsOf('u'), ['Klingon', 'Not matched']);
      expect(textsOf('i'), ['xx', 'Ignored']);
      expect(textsOf('r'), ['ces', 'Czech', 'Linked to Czech (cs)']);
      // A status this client doesn't know says nothing.
      expect(textsOf('k'), ['qq', 'Mystery']);

      // Each status is an icon and words, never color alone.
      for (final (id, status) in [
        ('p', 'Waiting for review'),
        ('u', 'Not matched'),
        ('i', 'Ignored'),
        ('r', 'Linked to Czech (cs)'),
      ]) {
        final line = find.ancestor(
          of: textIn(row(id), status),
          matching: find.byType(Row),
        );
        expect(
          find.descendant(of: line.first, matching: find.byType(Icon)),
          findsOneWidget,
          reason: status,
        );
      }
    });

    testWidgets('a row reads as one node, and its menu is a button of its own '
        'named for the value', (tester) async {
      listing({
        waiting: [
          languageLink(
            'p',
            value: 'tlh',
            status: LanguageLinkStatus.pending,
            suppliedName: 'Klingon',
          ),
        ],
      });
      await pumpScreen(tester);

      final rowNode = tester.getSemantics(textIn(row('p'), 'tlh'));
      expect(
        rowNode,
        isSemantics(isButton: false, label: 'tlh\nKlingon\nWaiting for review'),
      );
      // By its tooltip: getSemantics on the menu would walk up to the row.
      final menuNode = find.semantics
          .byPredicate((node) => node.tooltip == 'Actions for tlh')
          .evaluate()
          .single;
      expect(menuNode, isNot(same(rowNode)));
      expect(
        menuNode,
        isSemantics(
          isButton: true,
          hasTapAction: true,
          tooltip: 'Actions for tlh',
        ),
      );
    });

    testWidgets('a pending row offers add, link and ignore; an ignored row '
        'offers only link', (tester) async {
      final p = languageLink('p', status: LanguageLinkStatus.pending);
      final u = languageLink('u');
      final x = languageLink('x', status: LanguageLinkStatus.ignored);
      final r = languageLink(
        'r',
        status: LanguageLinkStatus.resolved,
        tag: czech,
      );
      listing({
        waiting: [p, u],
        ignoredFilter: [x],
        resolvedFilter: [r],
      });
      await pumpScreen(tester);

      Future<List<String?>> itemsOf(String id) async {
        await tester.ensureVisible(menu(id));
        await tester.pumpAndSettle();
        await tester.tap(menu(id));
        await tester.pumpAndSettle();
        final items = [
          for (final text in tester.widgetList<Text>(
            find.descendant(
              of: find.byType(PopupMenuItem<LanguageLinkAction>),
              matching: find.byType(Text),
            ),
          ))
            text.data,
        ];
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        return items;
      }

      expect(await itemsOf('p'), [
        'Add this language',
        'Link to a language…',
        'Ignore',
      ]);
      expect(await itemsOf('u'), ['Link to a language…', 'Ignore']);

      await press(tester, filter(ignoredFilter));
      await tester.pumpAndSettle();
      expect(await itemsOf('x'), ['Link to a language…']);

      await press(tester, filter(resolvedFilter));
      await tester.pumpAndSettle();
      expect(await itemsOf('r'), ['Link to a language…', 'Ignore']);
    });

    testWidgets('a row stays out of reach while busy', (tester) async {
      listing({
        waiting: [a, b],
      });
      final held = holdIgnores();
      await pumpScreen(tester);

      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);

      expect(remote.calls, contains('ignoreLanguageLink(dg_1, a)'));
      expect(menu('a'), findsNothing);
      expect(
        find.descendant(
          of: row('a'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      // In the menu's place, a node of its own that says what is happening.
      final spinner = find.bySemanticsLabel('Working on Value a…');
      expect(spinner, findsOneWidget);
      expect(
        tester.getSemantics(textIn(row('a'), 'Value a')),
        isSemantics(label: 'Value a\nNot matched'),
      );
      // The other rows stay in reach.
      expect(menu('b'), findsOneWidget);

      held.complete(ignoredOf(a));
      await tester.pumpAndSettle();

      expect(row('a'), findsNothing);
      expect(spinner, findsNothing);
    });

    testWidgets("a row's words keep their room while its spinner stands in for "
        'its menu, so they wrap the same and nothing below them moves', (
      tester,
    ) async {
      listing({
        waiting: [a, b],
      });
      final held = holdIgnores();
      await pumpScreen(tester);
      double room() => tester
          .renderObject<RenderParagraph>(textIn(row('a'), 'Value a'))
          .constraints
          .maxWidth;
      final before = room();
      final below = tester.getTopLeft(row('b'));

      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);

      expect(menu('a'), findsNothing);
      expect(room(), before);
      expect(tester.getTopLeft(row('b')), below);

      held.complete(ignoredOf(a));
      await tester.pumpAndSettle();
    });

    testWidgets('a reader who may not change sees rows and no menus', (
      tester,
    ) async {
      access.changeDenied();
      listing({
        waiting: [a, b],
      });
      await pumpScreen(tester);

      expect(row('a'), findsOneWidget);
      expect(row('b'), findsOneWidget);
      expect(menu('a'), findsNothing);
      expect(find.byType(PopupMenuButton<LanguageLinkAction>), findsNothing);
    });

    testWidgets('a screen reader counts the rows, and only the rows', (
      tester,
    ) async {
      listing({
        waiting: [a, b, c],
      });
      remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
      await pumpScreen(tester);

      int? count() => tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount;

      expect(count(), 3);

      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      expect(count(), 3);
    });
  });

  group('the link action', () {
    testWidgets('link opens the picker, and a choice sends its tag id', (
      tester,
    ) async {
      listing({
        waiting: [a],
      });
      remote.onLinkLanguageLink = (_, _, _) async =>
          a.copyWith(status: LanguageLinkStatus.resolved, tag: slovak);
      await pumpScreen(tester);

      await choose(tester, 'a', LanguageLinkWorklist.linkKey);

      expect(find.byType(LanguageTagPickerDialog), findsOneWidget);
      expect(find.text('Link "Value a" to a language'), findsOneWidget);

      await pick(tester, slovak);
      await tester.pumpAndSettle();

      expect(remote.calls, contains('linkLanguageLink(dg_1, a, tag_sk)'));
      expect(find.byType(LanguageTagPickerDialog), findsNothing);
    });

    testWidgets('dismissing the picker sends nothing', (tester) async {
      final events = _EventLog();
      final observer = Bloc.observer;
      Bloc.observer = events;
      addTearDown(() => Bloc.observer = observer);
      listing({
        waiting: [a],
      });
      await pumpScreen(tester);

      await choose(tester, 'a', LanguageLinkWorklist.linkKey);
      await tester.tap(find.byKey(LanguageTagPickerDialog.cancelKey));
      await tester.pumpAndSettle();

      expect(find.byType(LanguageTagPickerDialog), findsNothing);
      // Not even to the bloc, which would drop a link that names no tag.
      expect(events.seen.whereType<LanguageLinkListActionRequested>(), isEmpty);
      expect(
        remote.calls.where((call) => call.startsWith('linkLanguageLink')),
        isEmpty,
      );
      expect(menu('a'), findsOneWidget);
    });

    testWidgets('the picker is a dialog, so opening and closing it reads '
        'nothing again', (tester) async {
      listing({
        waiting: [a],
      });
      await pumpScreen(tester);

      await choose(tester, 'a', LanguageLinkWorklist.linkKey);
      await tester.tap(find.byKey(LanguageTagPickerDialog.cancelKey));
      await tester.pumpAndSettle();

      expect(linkReads(), hasLength(1));
      expect(detailReads(), hasLength(1));
    });

    testWidgets('a choice made after the screen moved to another DataGateway '
        'sends nothing', (tester) async {
      final id = ValueNotifier('dg_1');
      addTearDown(id.dispose);
      listing({
        waiting: [a],
      });
      await tester.pumpWidget(
        app(
          ValueListenableBuilder<String>(
            valueListenable: id,
            builder: (_, id, _) =>
                DataGatewayDetailScreen(remote: remote, id: id, access: access),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await choose(tester, 'a', LanguageLinkWorklist.linkKey);
      // go_router keys a page by its path pattern, so going to another
      // DataGateway's location rebuilds the screen in place, under the picker.
      id.value = 'dg_2';
      await tester.pump();
      await pick(tester, slovak);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        remote.calls.where((call) => call.startsWith('linkLanguageLink')),
        isEmpty,
      );
    });
  });

  group('the banner', () {
    final klingon = languageLink(
      'k',
      value: 'Klingon',
      status: LanguageLinkStatus.pending,
    );

    for (final kind in LanguageLinkOutcomeKind.values) {
      final (tone, copy) = switch (kind) {
        LanguageLinkOutcomeKind.linked => (
          BgeBannerTone.success,
          'Linked Klingon.',
        ),
        LanguageLinkOutcomeKind.ignored => (
          BgeBannerTone.success,
          'Ignored Klingon.',
        ),
        LanguageLinkOutcomeKind.accepted => (
          BgeBannerTone.success,
          'Added Klingon.',
        ),
        LanguageLinkOutcomeKind.conflict => (
          BgeBannerTone.info,
          "Couldn't add Klingon. It may have been settled already, or isn't a "
              'language the server knows. Try linking it instead.',
        ),
        LanguageLinkOutcomeKind.unknownTag => (
          BgeBannerTone.error,
          'That language is no longer available.',
        ),
        LanguageLinkOutcomeKind.refused => (
          BgeBannerTone.info,
          "Your role can't change data gateways.",
        ),
        LanguageLinkOutcomeKind.gone => (
          BgeBannerTone.info,
          'Klingon is no longer on this list.',
        ),
        LanguageLinkOutcomeKind.noAnswer => (
          BgeBannerTone.error,
          "Couldn't get an answer about Klingon. Check the list before trying "
              'again.',
        ),
      };

      testWidgets('each outcome has its banner copy: ${kind.name}', (
        tester,
      ) async {
        listing({
          waiting: [klingon],
        });
        final linked = klingon.copyWith(
          status: LanguageLinkStatus.resolved,
          tag: czech,
        );
        final Key item;
        switch (kind) {
          case LanguageLinkOutcomeKind.linked:
            item = LanguageLinkWorklist.linkKey;
            remote.onLinkLanguageLink = (_, _, _) async => linked;
          case LanguageLinkOutcomeKind.ignored:
            item = LanguageLinkWorklist.ignoreKey;
            remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(klingon);
          case LanguageLinkOutcomeKind.accepted:
            item = LanguageLinkWorklist.acceptKey;
            remote.onAcceptLanguageLink = (_, _) async => linked;
          case LanguageLinkOutcomeKind.conflict:
            item = LanguageLinkWorklist.acceptKey;
            remote.onAcceptLanguageLink = (_, _) async =>
                throw const DataGatewayConflictException(
                  'not pending',
                  statusCode: 409,
                );
          case LanguageLinkOutcomeKind.unknownTag:
            item = LanguageLinkWorklist.linkKey;
            remote.onLinkLanguageLink = (_, _, _) async =>
                throw const DataGatewayPermanentException(
                  'no such tag',
                  statusCode: 400,
                );
          case LanguageLinkOutcomeKind.refused:
            item = LanguageLinkWorklist.ignoreKey;
            remote.onIgnoreLanguageLink = (_, _) async => throw forbidden();
          case LanguageLinkOutcomeKind.gone:
            item = LanguageLinkWorklist.ignoreKey;
            remote.onIgnoreLanguageLink = (_, _) async =>
                throw const DataGatewayNotFoundException(
                  'gone',
                  statusCode: 404,
                );
          case LanguageLinkOutcomeKind.noAnswer:
            item = LanguageLinkWorklist.ignoreKey;
            remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
        }
        await pumpScreen(tester);

        await choose(tester, 'k', item);
        if (item == LanguageLinkWorklist.linkKey) await pick(tester, czech);
        await tester.pumpAndSettle();

        final shown = tester.widget<BgeInlineBanner>(banner);
        expect(shown.message, copy);
        expect(shown.tone, tone);
        expect(textIn(banner, copy), findsOneWidget);
      });
    }

    testWidgets('it is pinned below the list, which it takes no row from', (
      tester,
    ) async {
      listing({
        waiting: [a, b, c],
      });
      remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
      await pumpScreen(tester, size: const Size(360, 640));
      await bringIntoView(tester, menu('b'));

      await chooseByKeyboard(tester, 'b', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();

      final list = tester.getRect(find.byType(Scrollable).first);
      final shown = tester.getRect(banner);
      final tokens = BgeTokens.of(tester.element(banner));
      // The page gives the footer no inset, so the banner brings its own.
      expect(shown.top - list.bottom, tokens.spaceSm);
      expect(640 - shown.bottom, tokens.spaceLg);
      // Between the rows nothing has arrived.
      expect(
        tester.getTopLeft(row('b')).dy - tester.getBottomLeft(row('a')).dy,
        0,
      );
    });

    testWidgets('with no outcome the footer takes no height', (tester) async {
      listing({
        waiting: [a, b],
      });
      remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
      await pumpScreen(tester, size: const Size(360, 640));

      // The list runs to the foot of the window: no band below it.
      expect(tester.getRect(find.byType(Scrollable).first).bottom, 640);

      await bringIntoView(tester, menu('a'));
      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(Scrollable).first).bottom,
        lessThan(640),
      );

      await tester.tap(textIn(banner, 'Dismiss'));
      await tester.pumpAndSettle();

      expect(banner, findsNothing);
      expect(tester.getRect(find.byType(Scrollable).first).bottom, 640);
    });

    testWidgets("an outcome coming and going keeps the page's scroll position "
        'and focus', (tester) async {
      final longList = [for (var n = 1; n <= 40; n++) languageLink('r$n')];
      listing({waiting: longList});
      final held = holdIgnores();
      await pumpScreen(tester, size: const Size(360, 640));
      await bringIntoView(tester, menu('r10'));
      await chooseByKeyboard(tester, 'r10', LanguageLinkWorklist.ignoreKey);
      await focusOn(tester, iconOf(menu('r11')));
      final focused = FocusManager.instance.primaryFocus;
      final page = tester.state<ScrollableState>(find.byType(Scrollable).first);
      final offset = page.position.pixels;

      held.completeError(unreachable());
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable).first),
        same(page),
      );
      expect(page.position.pixels, offset);
      expect(FocusManager.instance.primaryFocus, same(focused));

      await tester.tap(textIn(banner, 'Dismiss'));
      await tester.pumpAndSettle();

      expect(banner, findsNothing);
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable).first),
        same(page),
      );
      expect(page.position.pixels, offset);
      expect(FocusManager.instance.primaryFocus, same(focused));
    });

    testWidgets('it waits while the DataGateway is not showing, and comes back '
        'with it', (tester) async {
      listing({
        waiting: [a, b],
      });
      remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
      var detailRead = 0;
      remote.onFetchOne = (id) async {
        if (++detailRead == 2) throw unreachable();
        return gateway(id, name: 'BGG');
      };
      await pumpScreen(tester);
      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);

      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayDetailScreen.errorKey), findsOneWidget);
      expect(banner, findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
    });

    for (final (shape, size) in [
      ('with Dismiss below its words', const Size(360, 640)),
      ('with Dismiss beside its words', const Size(800, 600)),
    ]) {
      testWidgets(
        'tab reaches it after the list, without stopping there on the '
        'way down, $shape',
        (tester) async {
          final longList = [for (var n = 1; n <= 16; n++) languageLink('r$n')];
          listing({waiting: longList});
          remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
          await pumpScreen(tester, size: size);
          await bringIntoView(tester, menu('r2'));
          await chooseByKeyboard(tester, 'r2', LanguageLinkWorklist.ignoreKey);
          await tester.pumpAndSettle();
          expect(focusIsIn(tester, menu('r2')), isTrue);

          for (var n = 3; n <= 16; n++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();

            expect(focusIsIn(tester, menu('r$n')), isTrue, reason: 'r$n');
            expect(focusOnScreen(tester), isTrue, reason: 'r$n');
          }

          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();

          expect(
            focusIsIn(
              tester,
              find.descendant(of: banner, matching: find.byType(TextButton)),
            ),
            isTrue,
          );
        },
      );
    }

    testWidgets('dismissing from the keyboard leaves focus on the row it came '
        'from', (tester) async {
      listing({
        waiting: [a, b, c],
      });
      remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
      await pumpScreen(tester);
      await chooseByKeyboard(tester, 'b', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();
      expect(focusIsIn(tester, menu('b')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusIsIn(tester, menu('c')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        focusIsIn(
          tester,
          find.descendant(of: banner, matching: find.byType(TextButton)),
        ),
        isTrue,
      );

      await pressKey(tester);
      await tester.pumpAndSettle();

      expect(banner, findsNothing);
      expect(focusIsIn(tester, menu('c')), isTrue);
    });

    testWidgets('dismiss closes the banner', (tester) async {
      listing({
        waiting: [a, b],
      });
      remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(a);
      await pumpScreen(tester);
      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);

      await tester.tap(textIn(banner, 'Dismiss'));
      await tester.pumpAndSettle();

      expect(banner, findsNothing);
    });
  });

  group('in place of the rows', () {
    testWidgets('each filter has its own empty text', (tester) async {
      listing({});
      await pumpScreen(tester);

      for (final (of, copy) in [
        (waiting, 'Nothing to review'),
        (ignoredFilter, 'Nothing ignored'),
        (resolvedFilter, 'Nothing linked yet'),
      ]) {
        await press(tester, filter(of));
        await tester.pumpAndSettle();

        expect(textIn(emptyText, copy), findsOneWidget, reason: of.name);
        expect(
          tester.getSemantics(textIn(emptyText, copy)),
          isSemantics(isLiveRegion: true, label: copy),
          reason: of.name,
        );
        expect(moreButton, findsNothing);
      }
    });

    testWidgets('a page worked through with more on the server shows more '
        'alone, and no empty text', (tester) async {
      listing({
        waiting: [a],
      }, hasMore: true);
      remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(a);
      await pumpScreen(tester);

      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();

      expect(row('a'), findsNothing);
      expect(emptyText, findsNothing);
      expect(find.text('Nothing to review'), findsNothing);
      expect(moreButton, findsOneWidget);
    });

    testWidgets('reading the worklist is announced', (tester) async {
      final pending = Completer<PaginatedResult<LanguageLink>>();
      remote.onFetchLanguageLinks = (_, _, _, _) => pending.future;
      await pumpScreen(tester, settle: false);

      final spinner = find.bySemanticsLabel('Loading language names…');
      expect(
        tester.getSemantics(spinner),
        isSemantics(isLiveRegion: true, label: 'Loading language names…'),
      );
      // The filter it is reading for shows meanwhile.
      expect(tester.widget<FilterChip>(filter(waiting)).selected, isTrue);

      pending.complete(linkPageOf([a]));
      await tester.pumpAndSettle();

      expect(spinner, findsNothing);
      expect(row('a'), findsOneWidget);
    });

    testWidgets('a failed read offers retry', (tester) async {
      reads([
        unreachable(),
        linkPageOf([a]),
      ]);
      await pumpScreen(tester);

      expect(errorSurface, findsOneWidget);
      const failed = "Couldn't load the language names.";
      expect(textIn(errorSurface, failed), findsOneWidget);
      expect(
        tester.getSemantics(textIn(errorSurface, failed)),
        isSemantics(isLiveRegion: true, label: failed),
      );
      // The filters stay, to read another.
      expect(filter(ignoredFilter), findsOneWidget);
      // The rest of the screen is still there.
      expect(find.byKey(DataGatewayDetailScreen.nameKey), findsOneWidget);

      await press(tester, textIn(errorSurface, 'Try again'));
      await tester.pumpAndSettle();

      expect(errorSurface, findsNothing);
      expect(row('a'), findsOneWidget);
      expect(linkReads(), hasLength(2));
      // Only the worklist failed, so only the worklist is read again.
      expect(detailReads(), hasLength(1));
    });

    testWidgets(
      'a refused read says so in the section, with nothing to retry',
      (tester) async {
        remote.onFetchLanguageLinks = (_, _, _, _) async => throw forbidden();
        await pumpScreen(tester);

        const title = "You don't have access to data gateways";
        expect(find.text(title), findsOneWidget);
        expect(
          find.text('Ask an admin of this server if you need to manage them.'),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(find.text(title)),
          isSemantics(
            isLiveRegion: true,
            label:
                '$title\nAsk an admin of this server if you need to manage '
                'them.',
          ),
        );
        expect(find.text('Try again'), findsNothing);
        expect(errorSurface, findsNothing);
        expect(filter(waiting), findsNothing);
        // The rest of the screen is still there.
        expect(heading, findsOneWidget);
        expect(find.byKey(DataGatewayDetailScreen.nameKey), findsOneWidget);
      },
    );

    testWidgets('a gone DataGateway hands the screen to its gone surface', (
      tester,
    ) async {
      var detailRead = 0;
      remote.onFetchOne = (id) async {
        if (++detailRead == 1) return gateway(id, name: 'BGG');
        throw const DataGatewayNotFoundException('gone', statusCode: 404);
      };
      remote.onFetchLanguageLinks = (_, _, _, _) async =>
          throw const DataGatewayNotFoundException('gone', statusCode: 404);

      await pumpScreen(tester);

      expect(detailReads(), hasLength(2));
      expect(find.byKey(DataGatewayDetailScreen.goneKey), findsOneWidget);
      expect(heading, findsNothing);
    });

    testWidgets('until the DataGateway is read again, a worklist found gone '
        'offers retry', (tester) async {
      final worklistRead = Completer<PaginatedResult<LanguageLink>>();
      final detailAgain = Completer<DataGateway>();
      var detailRead = 0;
      remote.onFetchOne = (id) => ++detailRead == 1
          ? Future.value(gateway(id, name: 'BGG'))
          : detailAgain.future;
      remote.onFetchLanguageLinks = (_, _, _, _) => worklistRead.future;
      await pumpScreen(tester, settle: false);
      expect(find.byKey(DataGatewayDetailScreen.nameKey), findsOneWidget);

      worklistRead.completeError(
        const DataGatewayNotFoundException('gone', statusCode: 404),
      );
      await pumpEvent(tester);

      expect(detailReads(), hasLength(2));
      expect(errorSurface, findsOneWidget);
      expect(textIn(errorSurface, 'Try again'), findsOneWidget);
      expect(find.byKey(DataGatewayDetailScreen.nameKey), findsOneWidget);

      detailAgain.completeError(
        const DataGatewayNotFoundException('gone', statusCode: 404),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayDetailScreen.goneKey), findsOneWidget);
      expect(errorSurface, findsNothing);
    });

    testWidgets('the worklist shows only while the DataGateway does', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => throw unreachable();
      listing({
        waiting: [a],
      });
      await pumpScreen(tester);

      expect(find.byKey(DataGatewayDetailScreen.errorKey), findsOneWidget);
      expect(heading, findsNothing);
      expect(row('a'), findsNothing);
    });
  });

  group('more', () {
    final firstPage = [for (var n = 1; n <= 50; n++) languageLink('r$n')];

    /// Answers the first page with [firstPage] and more to come, and holds
    /// every later page until the test answers it.
    Completer<PaginatedResult<LanguageLink>> holdNextPage() {
      final next = Completer<PaginatedResult<LanguageLink>>();
      remote.onFetchLanguageLinks = (_, _, page, _) => page == 1
          ? Future.value(linkPageOf(firstPage, hasMore: true))
          : next.future;
      return next;
    }

    testWidgets('more loads the next page and is announced', (tester) async {
      final next = holdNextPage();
      await pumpScreen(tester);
      await bringIntoView(tester, moreButton);

      expect(
        tester.getSemantics(textIn(moreButton, 'Show more')),
        isSemantics(isButton: true, isLiveRegion: false, label: 'Show more'),
      );

      await press(tester, moreButton);

      expect(linkReads().last, 'fetchLanguageLinks(dg_1, null, 2)');
      expect(textIn(moreButton, 'Show more'), findsNothing);
      expect(
        tester.getSemantics(textIn(moreButton, 'Loading more…')),
        isSemantics(isButton: true, isLiveRegion: true, label: 'Loading more…'),
      );

      next.complete(
        linkPageOf([languageLink('r51'), languageLink('r52')], page: 2),
      );
      await tester.pumpAndSettle();

      expect(row('r51'), findsOneWidget);
      expect(row('r52'), findsOneWidget);
      expect(moreButton, findsNothing);
    });

    testWidgets('a focused more keeps focus through its page, and a press '
        'meanwhile sends nothing', (tester) async {
      final next = holdNextPage();
      await pumpScreen(tester);
      await bringIntoView(tester, moreButton);

      await focusOn(tester, textIn(moreButton, 'Show more'));
      expect(focusIsIn(tester, moreButton), isTrue);

      await pressKey(tester);

      expect(textIn(moreButton, 'Loading more…'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(moreButton).onPressed, isNotNull);
      expect(focusIsIn(tester, moreButton), isTrue);

      await pressKey(tester);

      expect(linkReads(), [readCall(), 'fetchLanguageLinks(dg_1, null, 2)']);
      expect(focusIsIn(tester, moreButton), isTrue);

      // The rows arrive above it, and it keeps its place in the tree.
      next.complete(
        linkPageOf(
          [for (var n = 51; n <= 100; n++) languageLink('r$n')],
          page: 2,
          hasMore: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(textIn(moreButton, 'Show more'), findsOneWidget);
      expect(focusIsIn(tester, moreButton), isTrue);
    });

    testWidgets('a focused more keeps focus when its page fails', (
      tester,
    ) async {
      final next = holdNextPage();
      await pumpScreen(tester);
      await bringIntoView(tester, moreButton);
      await focusOn(tester, textIn(moreButton, 'Show more'));

      await pressKey(tester);
      next.completeError(unreachable());
      await tester.pumpAndSettle();

      // The failure line arrives above it, and it keeps its place in the tree.
      expect(textIn(moreButton, 'Try again'), findsOneWidget);
      expect(focusIsIn(tester, moreButton), isTrue);
    });

    testWidgets('when the last page takes more away, focus goes back to the '
        'row it came from, ahead of the new rows', (tester) async {
      final next = holdNextPage();
      await pumpScreen(tester);
      await bringIntoView(tester, moreButton);

      await focusOn(tester, iconOf(menu('r50')));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusIsIn(tester, moreButton), isTrue);

      await pressKey(tester);
      next.complete(linkPageOf([languageLink('r51')], page: 2));
      await tester.pumpAndSettle();

      expect(moreButton, findsNothing);
      expect(focusIsIn(tester, menu('r50')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(focusIsIn(tester, menu('r51')), isTrue);
    });

    testWidgets('a failed more says so, and its button tries again', (
      tester,
    ) async {
      var nextPage = 0;
      remote.onFetchLanguageLinks = (_, _, page, _) async {
        if (page == 1) return linkPageOf(firstPage, hasMore: true);
        if (++nextPage == 1) throw unreachable();
        return linkPageOf([languageLink('r51')], page: 2);
      };
      await pumpScreen(tester);
      await bringIntoView(tester, moreButton);

      await press(tester, moreButton);
      await tester.pumpAndSettle();

      const failed = "Couldn't load more language names.";
      expect(find.text(failed), findsOneWidget);
      expect(
        tester.getSemantics(find.text(failed)),
        isSemantics(isLiveRegion: true, label: failed),
      );
      expect(textIn(moreButton, 'Try again'), findsOneWidget);
      // The rows read so far stay.
      expect(row('r50'), findsOneWidget);

      await press(tester, moreButton);
      await tester.pumpAndSettle();

      expect(linkReads().where((call) => call.endsWith(', 2)')), hasLength(2));
      expect(find.text(failed), findsNothing);
      expect(row('r51'), findsOneWidget);
    });
  });

  group('focus after an action', () {
    testWidgets("an action that drops the row puts focus on the next row's "
        'menu', (tester) async {
      listing({
        waiting: [a, b, c],
      });
      final held = holdIgnores();
      await pumpScreen(tester);
      // Focus came down from row a, so there is somewhere for it to fall back.
      await focusOn(tester, iconOf(menu('a')));

      await chooseByKeyboard(tester, 'b', LanguageLinkWorklist.ignoreKey);

      expect(remote.calls, contains('ignoreLanguageLink(dg_1, b)'));
      expect(menu('b'), findsNothing);
      // Gone with the menu, onto nothing: not back to row a.
      expect(focusOnNothing(), isTrue);
      expect(focusIsIn(tester, menu('a')), isFalse);

      held.complete(ignoredOf(b));
      await tester.pumpAndSettle();

      expect(row('b'), findsNothing);
      expect(focusIsIn(tester, menu('c')), isTrue);
    });

    testWidgets('one on the last row puts focus on the one before', (
      tester,
    ) async {
      listing({
        waiting: [a, b, c],
      });
      final held = holdIgnores();
      await pumpScreen(tester);
      await focusOn(tester, iconOf(menu('a')));

      await chooseByKeyboard(tester, 'c', LanguageLinkWorklist.ignoreKey);
      expect(focusOnNothing(), isTrue);

      held.complete(ignoredOf(c));
      await tester.pumpAndSettle();

      expect(row('c'), findsNothing);
      expect(focusIsIn(tester, menu('b')), isTrue);
    });

    testWidgets('one that keeps the row puts focus back on its menu', (
      tester,
    ) async {
      final r1 = languageLink(
        'r1',
        status: LanguageLinkStatus.resolved,
        tag: czech,
      );
      final r2 = languageLink(
        'r2',
        status: LanguageLinkStatus.resolved,
        tag: czech,
      );
      listing({
        resolvedFilter: [r1, r2],
      });
      final held = Completer<LanguageLink>();
      remote.onLinkLanguageLink = (_, _, _) => held.future;
      await pumpScreen(tester);
      await press(tester, filter(resolvedFilter));
      await tester.pumpAndSettle();
      await focusOn(tester, iconOf(menu('r2')));

      await chooseByKeyboard(tester, 'r1', LanguageLinkWorklist.linkKey);
      await pick(tester, slovak);

      expect(remote.calls, contains('linkLanguageLink(dg_1, r1, tag_sk)'));
      expect(menu('r1'), findsNothing);
      expect(focusOnNothing(), isTrue);

      // Linked to another tag, and still under the resolved filter.
      held.complete(r1.copyWith(tag: slovak));
      await tester.pumpAndSettle();

      expect(textIn(row('r1'), 'Linked to Slovak (sk)'), findsOneWidget);
      expect(focusIsIn(tester, menu('r1')), isTrue);
    });

    testWidgets('one that empties the list puts focus on the selected chip', (
      tester,
    ) async {
      listing({
        waiting: [a],
      });
      final held = holdIgnores();
      await pumpScreen(tester);
      await focusOn(tester, find.byIcon(Icons.refresh));

      await chooseByKeyboard(tester, 'a', LanguageLinkWorklist.ignoreKey);
      expect(focusOnNothing(), isTrue);

      held.complete(ignoredOf(a));
      await tester.pumpAndSettle();

      expect(emptyText, findsOneWidget);
      expect(focusIsIn(tester, filter(waiting)), isTrue);
    });

    testWidgets('focus the user moved during the action is left where it is', (
      tester,
    ) async {
      final d = languageLink('d');
      listing({
        waiting: [a, b, c, d],
      });
      final held = holdIgnores();
      await pumpScreen(tester);

      await chooseByKeyboard(tester, 'b', LanguageLinkWorklist.ignoreKey);
      // On to row d while row b's ignore runs.
      await focusOn(tester, iconOf(menu('d')));

      held.complete(ignoredOf(b));
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      expect(focusIsIn(tester, menu('d')), isTrue);
      expect(focusIsIn(tester, menu('c')), isFalse);
    });

    group('by pointer, from a page pushed over another', () {
      final back = find.byType(BackButtonIcon);

      /// Opens the screen over another page, so its app bar has Back, and puts
      /// focus there, as a click or an earlier Tab can leave it.
      Future<void> pumpOver(WidgetTester tester) async {
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = const Size(800, 2400);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(app(const Scaffold(body: Text('below'))));
        unawaited(
          tester
              .state<NavigatorState>(find.byType(Navigator))
              .push(
                MaterialPageRoute<void>(
                  builder: (_) => DataGatewayDetailScreen(
                    remote: remote,
                    id: 'dg_1',
                    access: access,
                  ),
                ),
              ),
        );
        await tester.pumpAndSettle();
        await focusOn(tester, back);
        expect(focusIsIn(tester, find.byType(BackButton)), isTrue);
      }

      /// Links [id]'s row to Czech with clicks: the menu, Link, then the
      /// language in the picker. A click focuses none of them.
      Future<void> linkByPointer(WidgetTester tester, String id) async {
        await tester.tap(menu(id));
        await letMenuClose(tester);
        await tester.tap(find.byKey(LanguageLinkWorklist.linkKey));
        await letMenuClose(tester);
        await pick(tester, czech);
      }

      testWidgets("a link through the picker ends with focus on the next row's "
          'menu, not where the picker gave it back', (tester) async {
        listing({
          waiting: [a, b, c],
        });
        final held = Completer<LanguageLink>();
        remote.onLinkLanguageLink = (_, _, _) => held.future;
        await pumpOver(tester);

        await linkByPointer(tester, 'b');
        expect(remote.calls, contains('linkLanguageLink(dg_1, b, tag_cs)'));
        expect(menu('b'), findsNothing);
        // The picker gave focus back to Back as it closed.
        expect(focusIsIn(tester, find.byType(BackButton)), isTrue);

        held.complete(
          b.copyWith(status: LanguageLinkStatus.resolved, tag: czech),
        );
        await tester.pumpAndSettle();

        expect(row('b'), findsNothing);
        expect(focusIsIn(tester, menu('c')), isTrue);
      });

      testWidgets('a control the user focuses during it is left alone', (
        tester,
      ) async {
        listing({
          waiting: [a, b, c],
        });
        final held = Completer<LanguageLink>();
        remote.onLinkLanguageLink = (_, _, _) => held.future;
        await pumpOver(tester);

        await linkByPointer(tester, 'b');
        await focusOn(tester, find.byIcon(Icons.refresh));

        held.complete(
          b.copyWith(status: LanguageLinkStatus.resolved, tag: czech),
        );
        await tester.pumpAndSettle();

        expect(focusIsIn(tester, refreshButton), isTrue);
        expect(focusIsIn(tester, menu('c')), isFalse);
      });
    });

    testWidgets('a focused menu keeps focus when a banner arrives and more '
        'goes in the one frame', (tester) async {
      final pendingA = languageLink('a', status: LanguageLinkStatus.pending);
      var read = 0;
      // The read that follows the action says there is no more.
      remote.onFetchLanguageLinks = (_, _, _, _) async =>
          linkPageOf([pendingA, b], hasMore: ++read == 1);
      final held = Completer<LanguageLink>();
      remote.onAcceptLanguageLink = (_, _) => held.future;
      await pumpScreen(tester);
      expect(moreButton, findsOneWidget);

      await chooseByKeyboard(tester, 'a', LanguageLinkWorklist.acceptKey);
      await focusOn(tester, iconOf(menu('b')));

      // A conflict reads again, and that read has its answer before the frame.
      held.completeError(
        const DataGatewayConflictException('not pending', statusCode: 409),
      );
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      expect(moreButton, findsNothing);
      expect(focusIsIn(tester, menu('b')), isTrue);
    });

    testWidgets("a focused menu keeps focus when the DataGateway's own banner "
        'arrives in the footer, above the worklist\'s place there', (
      tester,
    ) async {
      listing({
        waiting: [a, b],
      });
      remote.onInterview = (id) async => DataGatewayInterviewResult(
        dataGateway: gateway(id, name: 'BGG'),
        succeeded: false,
      );
      await pumpScreen(tester);
      await focusOn(tester, iconOf(menu('b')));

      await tester.tap(find.byKey(DataGatewayDetailScreen.interviewKey));
      await tester.pumpAndSettle();

      final own = find.byKey(DataGatewayDetailScreen.outcomeKey);
      expect(own, findsOneWidget);
      expect(
        tester.getTopLeft(own).dy,
        greaterThanOrEqualTo(
          tester.getRect(find.byType(Scrollable).first).bottom,
        ),
      );
      expect(focusIsIn(tester, menu('b')), isTrue);
    });

    testWidgets('a read that takes the row with focus moves focus to the row '
        'now in its place', (tester) async {
      reads([
        linkPageOf([a, b, c]),
        linkPageOf([a, c]),
      ]);
      await pumpScreen(tester);
      // Tabbed down from row a, which is where focus would otherwise fall back.
      await focusOn(tester, iconOf(menu('a')));
      await focusOn(tester, iconOf(menu('b')));

      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(row('b'), findsNothing);
      expect(focusIsIn(tester, menu('c')), isTrue);
    });

    testWidgets('a read that takes the row with focus does the same under '
        'another filter', (tester) async {
      final x = languageLink('x', status: LanguageLinkStatus.ignored);
      final y = languageLink('y', status: LanguageLinkStatus.ignored);
      final z = languageLink('z', status: LanguageLinkStatus.ignored);
      reads([
        linkPageOf([a]),
        linkPageOf([x, y, z]),
        linkPageOf([x, z]),
      ]);
      await pumpScreen(tester);
      await press(tester, filter(ignoredFilter));
      await tester.pumpAndSettle();
      await focusOn(tester, iconOf(menu('y')));

      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(row('y'), findsNothing);
      expect(focusIsIn(tester, menu('z')), isTrue);
    });

    testWidgets('a read that takes the last row with focus moves focus to the '
        'one before', (tester) async {
      reads([
        linkPageOf([a, b]),
        linkPageOf([a]),
      ]);
      await pumpScreen(tester);
      await focusOn(tester, iconOf(menu('b')));

      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(row('b'), findsNothing);
      expect(focusIsIn(tester, menu('a')), isTrue);
    });

    testWidgets(
      'a read that takes every row moves focus to the selected chip',
      (tester) async {
        reads([
          linkPageOf([a]),
          linkPageOf([]),
        ]);
        await pumpScreen(tester);
        await focusOn(tester, iconOf(menu('a')));

        await tester.tap(refreshButton);
        await tester.pumpAndSettle();

        expect(emptyText, findsOneWidget);
        expect(focusIsIn(tester, filter(waiting)), isTrue);
      },
    );

    testWidgets('a read that takes the rows down moves focus to the selected '
        'chip', (tester) async {
      reads([
        linkPageOf([a, b]),
        unreachable(),
      ]);
      await pumpScreen(tester);
      await focusOn(tester, iconOf(menu('b')));

      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(errorSurface, findsOneWidget);
      expect(focusIsIn(tester, filter(waiting)), isTrue);
    });

    testWidgets("a refusal elsewhere takes the menu with focus, so focus goes "
        'to the selected chip', (tester) async {
      listing({
        waiting: [a, b, c],
      });
      final held = holdIgnores();
      await pumpScreen(tester);
      await chooseByKeyboard(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await focusOn(tester, iconOf(menu('c')));

      held.completeError(forbidden());
      await tester.pumpAndSettle();

      expect(menu('c'), findsNothing);
      expect(focusIsIn(tester, filter(waiting)), isTrue);
    });

    testWidgets('a refusal from another screen takes the menu with focus, and '
        'focus can be seen on the chip it goes to', (tester) async {
      final longList = [for (var n = 1; n <= 40; n++) languageLink('r$n')];
      listing({waiting: longList});
      await pumpScreen(tester, size: const Size(360, 640));
      await bringIntoView(tester, menu('r20'));
      await focusOn(tester, iconOf(menu('r20')));
      // A key, so that focus shows.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      access.changeDenied();
      await tester.pumpAndSettle();

      expect(menu('r20'), findsNothing);
      expect(focusIsIn(tester, filter(waiting)), isTrue);
      expect(focusOnScreen(tester), isTrue);
    });

    testWidgets('a filter chosen while a menu has focus moves focus to that '
        'filter', (tester) async {
      listing({
        waiting: [a, b],
        ignoredFilter: [languageLink('x', status: LanguageLinkStatus.ignored)],
      });
      await pumpScreen(tester);
      await focusOn(tester, iconOf(menu('b')));

      await press(tester, filter(ignoredFilter));
      await tester.pumpAndSettle();

      expect(row('x'), findsOneWidget);
      expect(focusIsIn(tester, filter(ignoredFilter)), isTrue);
    });

    testWidgets('a worklist built over rows it already has follows the first '
        'read that takes one', (tester) async {
      reads([
        linkPageOf([a, b, c]),
        linkPageOf([a, b, c]),
        linkPageOf([a, b, c]),
        linkPageOf([a, c]),
      ]);
      var detailRead = 0;
      remote.onFetchOne = (id) async {
        if (++detailRead == 2) throw unreachable();
        return gateway(id, name: 'BGG');
      };
      await pumpScreen(tester);
      // The row's failure takes the worklist off the page, and a retry builds
      // it again, over rows the bloc kept.
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();
      expect(row('b'), findsNothing);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      await focusOn(tester, iconOf(menu('b')));

      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(row('b'), findsNothing);
      expect(focusIsIn(tester, menu('c')), isTrue);
    });

    testWidgets('a read landing with the end of an action that only moves '
        'the row puts focus back on its menu', (tester) async {
      final pending = [
        for (final id in ['a', 'b', 'c', 'd'])
          languageLink(id, status: LanguageLinkStatus.pending),
      ];
      reads([linkPageOf(pending), linkPageOf(pending.sublist(1))]);
      final held = Completer<LanguageLink>();
      remote.onAcceptLanguageLink = (_, _) => held.future;
      await pumpScreen(tester);

      await chooseByKeyboard(tester, 'c', LanguageLinkWorklist.acceptKey);
      expectBusy(tester, 'c');

      held.completeError(
        const DataGatewayConflictException('settled', statusCode: 409),
      );
      await tester.pumpAndSettle();

      expect(row('a'), findsNothing);
      // Its old place is d's now.
      expect(focusIsIn(tester, menu('c')), isTrue);
    });

    testWidgets("a read that takes the row with focus leaves focus alone when "
        "the row in its place isn't built", (tester) async {
      final longList = [for (var n = 1; n <= 40; n++) languageLink('r$n')];
      reads([
        linkPageOf(longList),
        linkPageOf([...longList]..removeAt(19)),
      ]);
      await pumpScreen(tester, size: const Size(360, 640));
      // Focus was here first, so there is somewhere for it to fall back.
      await focusOn(tester, find.byIcon(Icons.refresh));
      await bringIntoView(tester, menu('r20'));
      await focusOn(tester, iconOf(menu('r20')));
      // A key, so the focused row shows it, and keeps itself alive off screen.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      await scrollPageTo(tester, 0);
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(menu('r20'), findsNothing);
      expect(focusOnNothing(), isTrue);
      expect(pageOffset(tester), 0);
    });

    testWidgets("a listed row whose menu isn't built leaves focus alone, and "
        'the chip out of it', (tester) async {
      final longList = [for (var n = 1; n <= 40; n++) languageLink('r$n')];
      listing({waiting: longList});
      final held = holdIgnores();
      await pumpScreen(tester, size: const Size(360, 640));
      await bringIntoView(tester, menu('r20'));
      await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.ignoreKey);
      expectBusy(tester, 'r20');

      // Well away from the row by the time its action ends.
      await scrollPageTo(tester, 0);
      held.completeError(unreachable());
      await tester.pumpAndSettle();

      expect(row('r20'), findsNothing);
      expect(focusOnNothing(), isTrue);
      expect(focusIsIn(tester, filter(waiting)), isFalse);
      expect(pageOffset(tester), 0);
    });

    testWidgets('a menu opened during the action keeps its focus', (
      tester,
    ) async {
      listing({
        waiting: [a, b, c],
      });
      final held = holdIgnores();
      await pumpScreen(tester);

      await chooseByKeyboard(tester, 'b', LanguageLinkWorklist.ignoreKey);
      // Row a's menu, opened and waiting for a choice: focus is on its route,
      // which is a scope, and not this worklist's to take.
      await tester.tap(menu('a'));
      await letMenuClose(tester);
      final inMenu = FocusManager.instance.primaryFocus;
      expect(inMenu, isA<FocusScopeNode>());

      held.complete(ignoredOf(b));
      await letMenuClose(tester);

      expect(find.byKey(LanguageLinkWorklist.linkKey), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(inMenu));
    });

    testWidgets('a filter changed during the action takes focus nowhere: the '
        'row has no place in the list now shown', (tester) async {
      final x = languageLink('x', status: LanguageLinkStatus.ignored);
      listing({
        waiting: [a, b, c],
        ignoredFilter: [x],
      });
      final held = holdIgnores();
      await pumpScreen(tester);

      await chooseByKeyboard(tester, 'b', LanguageLinkWorklist.ignoreKey);
      // With a pointer, which leaves focus where it is.
      await press(tester, filter(ignoredFilter));
      await letMenuClose(tester);
      expect(row('x'), findsOneWidget);

      held.complete(ignoredOf(b));
      await tester.pumpAndSettle();

      expect(row('x'), findsOneWidget);
      expect(focusOnNothing(), isTrue);
    });

    testWidgets('a refusal takes every menu, so focus goes to the selected '
        'chip', (tester) async {
      listing({
        waiting: [a, b],
      });
      remote.onIgnoreLanguageLink = (_, _) async => throw forbidden();
      await pumpScreen(tester);

      await chooseByKeyboard(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();

      expect(menu('a'), findsNothing);
      expect(row('a'), findsOneWidget);
      expect(focusIsIn(tester, filter(waiting)), isTrue);
    });

    testWidgets('when actions run side by side, focus comes back for the row '
        'acted on last, from the place it had when its action ended', (
      tester,
    ) async {
      final d = languageLink('d');
      listing({
        waiting: [a, b, c, d],
      });
      final held = {
        'a': Completer<LanguageLink>(),
        'b': Completer<LanguageLink>(),
      };
      remote.onIgnoreLanguageLink = (_, id) => held[id]!.future;
      await pumpScreen(tester);

      await chooseByKeyboard(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await chooseByKeyboard(tester, 'b', LanguageLinkWorklist.ignoreKey);

      // Row a's end moves row b up a place, and gives nothing back.
      held['a']!.complete(ignoredOf(a));
      await letMenuClose(tester);
      expect(row('a'), findsNothing);
      expect(focusOnNothing(), isTrue);

      held['b']!.complete(ignoredOf(b));
      await tester.pumpAndSettle();

      expect(row('b'), findsNothing);
      expect(focusIsIn(tester, menu('c')), isTrue);
    });

    testWidgets('focus comes back once for an action', (tester) async {
      var read = 0;
      remote.onFetchLanguageLinks = (_, _, _, _) async =>
          linkPageOf([a, b, if (++read > 1) c]);
      // Answered as still waiting, so the row stays and takes focus back.
      remote.onIgnoreLanguageLink = (_, _) async =>
          a.copyWith(status: LanguageLinkStatus.pending);
      await pumpScreen(tester);

      await chooseByKeyboard(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();
      expect(focusIsIn(tester, menu('a')), isTrue);

      // Focus let go of, and a read that brings a row: no action has ended.
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(row('c'), findsOneWidget);
      expect(focusOnNothing(), isTrue);
    });

    testWidgets('an action asked for while more is out starts, and more goes '
        'on saying it is loading', (tester) async {
      final firstPage = [for (var n = 1; n <= 50; n++) languageLink('r$n')];
      remote.onFetchLanguageLinks = (_, _, page, _) => page == 1
          ? Future.value(linkPageOf(firstPage, hasMore: true))
          : Completer<PaginatedResult<LanguageLink>>().future;
      remote.onIgnoreLanguageLink = (_, _) => Completer<LanguageLink>().future;
      await pumpScreen(tester);

      await bringIntoView(tester, moreButton);
      await press(tester, moreButton);
      await choose(tester, 'r50', LanguageLinkWorklist.ignoreKey);

      expect(remote.calls, contains('ignoreLanguageLink(dg_1, r50)'));
      expect(menu('r50'), findsNothing);
      expect(textIn(moreButton, 'Loading more…'), findsOneWidget);
    });

    testWidgets('more asked for during an action says it is loading', (
      tester,
    ) async {
      listing({
        waiting: [a, b],
      }, hasMore: true);
      remote.onIgnoreLanguageLink = (_, _) => Completer<LanguageLink>().future;
      await pumpScreen(tester);
      await bringIntoView(tester, moreButton);

      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);
      expect(textIn(moreButton, 'Show more'), findsOneWidget);

      await press(tester, moreButton);

      expect(textIn(moreButton, 'Loading more…'), findsOneWidget);
      expect(remote.calls.where((call) => call.endsWith(', 2)')), isEmpty);
    });

    testWidgets('tab goes along the filters, then each menu, then more: a row '
        'is content, not a stop', (tester) async {
      listing({
        waiting: [a, b],
      }, hasMore: true);
      await pumpScreen(tester);

      await focusOn(tester, textIn(filter(waiting), 'Waiting'));
      for (final control in [
        filter(ignoredFilter),
        filter(resolvedFilter),
        menu('a'),
        menu('b'),
        moreButton,
      ]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();

        expect(focusIsIn(tester, control), isTrue, reason: '$control');
      }
    });

    testWidgets('shift-tab goes back up the rows, not by way of the app bar', (
      tester,
    ) async {
      final longList = [for (var n = 1; n <= 40; n++) languageLink('r$n')];
      listing({waiting: longList});
      await pumpScreen(tester, size: const Size(360, 640));
      await bringIntoView(tester, menu('r20'));
      await focusOn(tester, iconOf(menu('r20')));

      for (var n = 19; n >= 15; n--) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();

        expect(focusIsIn(tester, menu('r$n')), isTrue, reason: 'r$n');
        expect(focusOnScreen(tester), isTrue, reason: 'r$n');
      }
    });

    testWidgets('a focused filter keeps focus through its read', (
      tester,
    ) async {
      final read = Completer<PaginatedResult<LanguageLink>>();
      remote.onFetchLanguageLinks = (_, statuses, _, _) =>
          statuses == null ? Future.value(linkPageOf([a])) : read.future;
      await pumpScreen(tester);

      await focusOn(tester, textIn(filter(ignoredFilter), 'Ignored'));
      await pressKey(tester);

      expect(find.bySemanticsLabel('Loading language names…'), findsOneWidget);
      expect(focusIsIn(tester, filter(ignoredFilter)), isTrue);

      read.complete(linkPageOf([languageLink('x')]));
      await tester.pumpAndSettle();

      expect(row('x'), findsOneWidget);
      expect(focusIsIn(tester, filter(ignoredFilter)), isTrue);
    });

    testWidgets('the focus node of a row that goes is disposed with it, and '
        'the rest with the screen', (tester) async {
      final live = <String>{};
      void watch(ObjectEvent event) {
        final label = switch (event.object) {
          final FocusNode node => node.debugLabel,
          _ => null,
        };
        if (label == null || !label.startsWith('language link')) return;
        if (event is ObjectCreated) live.add(label);
        if (event is ObjectDisposed) live.remove(label);
      }

      FlutterMemoryAllocations.instance.addListener(watch);
      addTearDown(
        () => FlutterMemoryAllocations.instance.removeListener(watch),
      );
      listing({
        waiting: [a, b],
      });
      remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(a);
      await pumpScreen(tester);
      expect(
        live,
        containsAll(['language link menu a', 'language link menu b']),
      );

      await choose(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();

      expect(row('a'), findsNothing);
      expect(live, isNot(contains('language link menu a')));
      expect(live, contains('language link menu b'));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(live, isEmpty);
    });
  });

  group('the page around an action, on a long list', () {
    final longList = [for (var n = 1; n <= 40; n++) languageLink('r$n')];

    // The screen's height, so most of the list is out of view.
    const phone = Size(800, 600);

    for (final (outcome, succeeds, focused, next) in [
      ('a success', true, 'r13', 'r14'),
      ('a failure', false, 'r12', 'r13'),
    ]) {
      testWidgets('$outcome leaves the page where the user is working, with '
          'the banner and the focused menu in view, and Tab goes on from '
          'there', (tester) async {
        listing({waiting: longList});
        remote.onIgnoreLanguageLink = (_, _) async =>
            succeeds ? ignoredOf(longList[11]) : throw unreachable();
        await pumpScreen(tester, size: phone);
        await bringToFoot(tester, 'r12');
        final before = pageOffset(tester);

        await chooseByKeyboard(tester, 'r12', LanguageLinkWorklist.ignoreKey);
        await tester.pumpAndSettle();

        expect(focusIsIn(tester, menu(focused)), isTrue);
        // The footer took the foot of the view, and the page made room.
        expect(focusOnScreen(tester), isTrue);
        expect(pageOffset(tester), greaterThanOrEqualTo(before));
        expect(tester.getRect(banner).bottom, lessThanOrEqualTo(600));

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();

        expect(focusIsIn(tester, menu(next)), isTrue);
        expect(focusOnScreen(tester), isTrue);
      });
    }

    testWidgets("an action at the list's foot, with a banner up, keeps the "
        'page and its focus', (tester) async {
      listing({waiting: longList});
      remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
      await pumpScreen(tester, size: phone);
      await bringIntoView(tester, menu('r40'));
      await chooseByKeyboard(tester, 'r40', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);
      await scrollPageTo(tester, pagePosition(tester).maxScrollExtent);

      // The next action leaves that banner up until it answers.
      final at = pageOffset(tester);
      final held = holdIgnores();
      await chooseByKeyboard(tester, 'r40', LanguageLinkWorklist.ignoreKey);
      expect(banner, findsOneWidget);
      expect(pageOffset(tester), at);

      held.completeError(unreachable());
      await tester.pumpAndSettle();

      expect(focusIsIn(tester, menu('r40')), isTrue);
      expect(focusOnScreen(tester), isTrue);
    });

    testWidgets('a page the user moved on during the action stays where it '
        'went', (tester) async {
      listing({waiting: longList});
      final held = holdIgnores();
      await pumpScreen(tester, size: phone);
      await bringIntoView(tester, menu('r12'));

      await chooseByKeyboard(tester, 'r12', LanguageLinkWorklist.ignoreKey);
      // Just far enough that the row next in line is above the view, and built.
      final view = tester.getRect(find.byType(Scrollable).first);
      final next = tester.getRect(row('r13'));
      await scrollPageTo(
        tester,
        pageOffset(tester) + next.bottom - view.top + 1,
      );
      await letMenuClose(tester);
      final moved = pageOffset(tester);

      held.complete(ignoredOf(longList[11]));
      await tester.pumpAndSettle();

      expect(focusIsIn(tester, menu('r13')), isTrue);
      expect(focusOnScreen(tester), isFalse);
      expect(pageOffset(tester), moved);
    });

    testWidgets('a row taller than the view still brings its menu into view', (
      tester,
    ) async {
      final tall = languageLink('tall', value: 'A very long name ' * 40);
      listing({
        waiting: [a, tall, b],
      });
      remote.onIgnoreLanguageLink = (_, _) async => ignoredOf(a);
      await pumpScreen(
        tester,
        size: const Size(320, 568),
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      await bringIntoView(tester, menu('a'));
      expect(
        tester.getSize(row('tall')).height,
        greaterThan(tester.getSize(find.byType(Scrollable).first).height),
      );

      await chooseByKeyboard(tester, 'a', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();

      expect(focusIsIn(tester, menu('tall')), isTrue);
      expect(focusOnScreen(tester), isTrue);
    });
  });

  group('at phone size, with each answer held across a frame', () {
    final longList = [
      for (var n = 1; n <= 40; n++)
        languageLink('r$n', status: LanguageLinkStatus.pending),
    ];
    final deep = longList[19];
    const notFound = DataGatewayNotFoundException('gone', statusCode: 404);
    const settled = DataGatewayConflictException('settled', statusCode: 409);
    const noAnswerCopy =
        "Couldn't get an answer about Value r20. Check the list before trying "
        'again.';
    const refusedCopy = "Your role can't change data gateways.";

    /// The outcome can be read, and has been said: it is built, on screen and
    /// in the semantics tree, as a live region. A banner taller than the
    /// footer's cap scrolls inside it, from its head.
    void expectOutcomeShown(WidgetTester tester, String copy) {
      expect(banner, findsOneWidget);
      final window = Offset.zero & tester.view.physicalSize;
      final rect = tester.getRect(banner);
      expect(rect.top, greaterThanOrEqualTo(window.top));
      expect(rect.top, lessThan(window.bottom));
      if (rect.height <= window.height / 2) {
        expect(rect.bottom, lessThanOrEqualTo(window.bottom));
      }
      expect(
        find.semantics.byLabel(copy).evaluate().single,
        isSemantics(isLiveRegion: true, label: copy),
      );
    }

    for (final (screen, size, scaler) in [
      ('360x640', const Size(360, 640), TextScaler.noScaling),
      (
        '320x568 at 200%',
        const Size(320, 568),
        const TextScaler.linear(BgeTextScale.maxScaleFactor),
      ),
    ]) {
      Future<void> open(WidgetTester tester) =>
          pumpScreen(tester, size: size, textScaler: scaler);

      testWidgets('$screen: the acted row gone', (tester) async {
        listing({waiting: longList});
        final held = holdIgnores();
        await open(tester);
        await bringIntoView(tester, menu('r20'));
        final before = pageOffset(tester);

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.ignoreKey);
        expectBusy(tester, 'r20');

        held.complete(ignoredOf(deep));
        await tester.pumpAndSettle();

        expect(row('r20'), findsNothing);
        expectOutcomeShown(tester, 'Ignored Value r20.');
        expect(focusIsIn(tester, menu('r21')), isTrue);
        expect(focusOnScreen(tester), isTrue);
        expect(pageOffset(tester), greaterThanOrEqualTo(before));
      });

      testWidgets('$screen: a filter changed during the action', (
        tester,
      ) async {
        listing({
          waiting: longList,
          ignoredFilter: [
            languageLink('x', status: LanguageLinkStatus.ignored),
          ],
        });
        final held = holdIgnores();
        await open(tester);
        await bringIntoView(tester, filter(ignoredFilter));
        final filtersAt = pageOffset(tester);
        await bringIntoView(tester, menu('r20'));

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.ignoreKey);
        expectBusy(tester, 'r20');

        await scrollPageTo(tester, filtersAt);
        await press(tester, filter(ignoredFilter));
        await letMenuClose(tester);
        expect(row('x'), findsOneWidget);

        held.complete(ignoredOf(deep));
        await tester.pumpAndSettle();

        expectOutcomeShown(tester, 'Ignored Value r20.');
      });

      testWidgets('$screen: a read replacing the rows', (tester) async {
        final replaced = [for (var n = 101; n <= 104; n++) languageLink('r$n')];
        final read = Completer<PaginatedResult<LanguageLink>>();
        reads([linkPageOf(longList), read.future, linkPageOf(replaced)]);
        final held = holdIgnores();
        await open(tester);
        await bringIntoView(tester, menu('r20'));

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.ignoreKey);
        expectBusy(tester, 'r20');

        await tester.tap(refreshButton);
        await pumpEvent(tester);
        read.complete(linkPageOf(replaced));
        await pumpEvent(tester);
        expect(row('r20'), findsNothing);

        held.completeError(unreachable());
        await tester.pumpAndSettle();

        expectOutcomeShown(tester, noAnswerCopy);

        // And it stays through the read after that.
        await tester.tap(refreshButton);
        await tester.pumpAndSettle();

        expectOutcomeShown(tester, noAnswerCopy);
      });

      testWidgets('$screen: the user scrolled away during the action', (
        tester,
      ) async {
        listing({waiting: longList});
        final held = holdIgnores();
        await open(tester);
        await bringIntoView(tester, menu('r20'));

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.ignoreKey);
        expectBusy(tester, 'r20');

        await scrollPageTo(tester, 0);
        held.completeError(unreachable());
        await tester.pumpAndSettle();

        expectOutcomeShown(tester, noAnswerCopy);
        expect(pageOffset(tester), 0);
        expect(focusOnNothing(), isTrue);
      });

      testWidgets('$screen: an earlier action failing while a later one runs', (
        tester,
      ) async {
        listing({waiting: longList});
        final held = {
          'r20': Completer<LanguageLink>(),
          'r21': Completer<LanguageLink>(),
        };
        remote.onIgnoreLanguageLink = (_, id) => held[id]!.future;
        await open(tester);
        await bringIntoView(tester, menu('r20'));

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.ignoreKey);
        await chooseByKeyboard(tester, 'r21', LanguageLinkWorklist.ignoreKey);
        expectBusy(tester, 'r20');
        expectBusy(tester, 'r21');

        held['r20']!.completeError(unreachable());
        await letMenuClose(tester);

        expectOutcomeShown(tester, noAnswerCopy);
        expectBusy(tester, 'r21');

        held['r21']!.complete(ignoredOf(longList[20]));
        await tester.pumpAndSettle();

        expectOutcomeShown(tester, 'Ignored Value r21.');
        expect(focusIsIn(tester, menu('r22')), isTrue);
        expect(focusOnScreen(tester), isTrue);
      });

      testWidgets('$screen: a refusal on a deep row, from the keyboard', (
        tester,
      ) async {
        listing({waiting: longList});
        final held = holdIgnores();
        await open(tester);
        await bringIntoView(tester, menu('r20'));

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.ignoreKey);
        expectBusy(tester, 'r20');

        held.completeError(forbidden());
        await tester.pumpAndSettle();

        expectOutcomeShown(tester, refusedCopy);
        expect(find.byType(PopupMenuButton<LanguageLinkAction>), findsNothing);
        // No menu is left to take focus, and focus can be seen where it went.
        expect(focusIsIn(tester, filter(waiting)), isTrue);
        expect(focusOnScreen(tester), isTrue);
      });

      testWidgets('$screen: a refusal on a deep row, by touch', (tester) async {
        listing({waiting: longList});
        final held = holdIgnores();
        await open(tester);
        await bringIntoView(tester, menu('r20'));

        await choose(tester, 'r20', LanguageLinkWorklist.ignoreKey);
        expectBusy(tester, 'r20');
        final before = pageOffset(tester);

        held.completeError(forbidden());
        await tester.pumpAndSettle();

        expectOutcomeShown(tester, refusedCopy);
        expect(find.byType(PopupMenuButton<LanguageLinkAction>), findsNothing);
        // A touch shows no focus, so nothing takes the page from the reader.
        expect(pageOffset(tester), before);
      });

      testWidgets('$screen: a link found gone', (tester) async {
        listing({waiting: longList});
        final held = holdIgnores();
        await open(tester);
        await bringIntoView(tester, menu('r20'));

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.ignoreKey);
        expectBusy(tester, 'r20');

        held.completeError(notFound);
        await tester.pumpAndSettle();

        expectOutcomeShown(tester, 'Value r20 is no longer on this list.');
      });

      testWidgets('$screen: a conflict, at the foot of the view', (
        tester,
      ) async {
        listing({waiting: longList});
        final held = Completer<LanguageLink>();
        remote.onAcceptLanguageLink = (_, _) => held.future;
        await open(tester);
        await bringToFoot(tester, 'r12');

        await chooseByKeyboard(tester, 'r12', LanguageLinkWorklist.acceptKey);
        expectBusy(tester, 'r12');

        held.completeError(settled);
        await tester.pumpAndSettle();

        expectOutcomeShown(
          tester,
          "Couldn't add Value r12. It may have been settled already, or isn't "
          'a language the server knows. Try linking it instead.',
        );
        expect(row('r12'), findsOneWidget);
        expect(focusIsIn(tester, menu('r12')), isTrue);
        expect(focusOnScreen(tester), isTrue);
      });

      testWidgets('$screen: a conflict whose read lands in the same frame and '
          'takes the row', (tester) async {
        reads([
          linkPageOf(longList),
          linkPageOf([...longList]..removeAt(19)),
        ]);
        final held = Completer<LanguageLink>();
        remote.onAcceptLanguageLink = (_, _) => held.future;
        await open(tester);
        await bringIntoView(tester, menu('r20'));

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.acceptKey);
        expectBusy(tester, 'r20');

        held.completeError(settled);
        await tester.pumpAndSettle();

        expect(row('r20'), findsNothing);
        expect(focusIsIn(tester, menu('r21')), isTrue);
        expect(focusOnScreen(tester), isTrue);
      });

      testWidgets('$screen: a conflict whose read takes the row', (
        tester,
      ) async {
        final read = Completer<PaginatedResult<LanguageLink>>();
        reads([linkPageOf(longList), read.future]);
        final held = Completer<LanguageLink>();
        remote.onAcceptLanguageLink = (_, _) => held.future;
        await open(tester);
        await bringIntoView(tester, menu('r20'));
        // Tabbed down from the row above, which is where focus would fall.
        await focusOn(tester, iconOf(menu('r19')));

        await chooseByKeyboard(tester, 'r20', LanguageLinkWorklist.acceptKey);
        expectBusy(tester, 'r20');

        held.completeError(settled);
        await tester.pumpAndSettle();
        expect(focusIsIn(tester, menu('r20')), isTrue);

        read.complete(linkPageOf([...longList]..removeAt(19)));
        await tester.pumpAndSettle();

        expect(row('r20'), findsNothing);
        expect(focusIsIn(tester, menu('r21')), isTrue);
        expect(focusOnScreen(tester), isTrue);
      });
    }

    // On a tall phone the conflict's banner fills the footer's half of the
    // body, which pushes a row at the foot of the view further out than a
    // lazy list keeps built by default: about 300dp here, under the test
    // font. The page keeps it built (#457).
    testWidgets('412x915 at 200%: a conflict at the foot of a tall view', (
      tester,
    ) async {
      listing({waiting: longList});
      final held = Completer<LanguageLink>();
      remote.onAcceptLanguageLink = (_, _) => held.future;
      await pumpScreen(
        tester,
        size: const Size(412, 915),
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      await bringToFoot(tester, 'r12');

      await chooseByKeyboard(tester, 'r12', LanguageLinkWorklist.acceptKey);
      expectBusy(tester, 'r12');

      held.completeError(settled);
      await tester.pumpAndSettle();

      expectOutcomeShown(
        tester,
        "Couldn't add Value r12. It may have been settled already, or isn't "
        'a language the server knows. Try linking it instead.',
      );
      expect(focusIsIn(tester, menu('r12')), isTrue);
      expect(focusOnScreen(tester), isTrue);
    });
  });

  group('reading again', () {
    testWidgets('refresh reads the worklist again too', (tester) async {
      listing({
        waiting: [a],
      });
      await pumpScreen(tester);
      expect(linkReads(), hasLength(1));

      await press(tester, refreshButton);
      await tester.pumpAndSettle();

      expect(detailReads(), hasLength(2));
      expect(linkReads(), hasLength(2));
    });

    testWidgets('coming back into view reads the worklist again too', (
      tester,
    ) async {
      listing({
        waiting: [a],
      });
      await pumpScreen(tester);

      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('a page on top')),
              ),
            ),
      );
      await tester.pumpAndSettle();
      expect(linkReads(), hasLength(1));

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      expect(detailReads(), hasLength(2));
      expect(linkReads(), hasLength(2));
    });

    testWidgets('a new id in place starts a fresh worklist', (tester) async {
      final id = ValueNotifier('dg_1');
      addTearDown(id.dispose);
      remote.onFetchLanguageLinks = (id, _, _, _) async =>
          linkPageOf([languageLink('of_$id')]);
      await tester.pumpWidget(
        app(
          ValueListenableBuilder<String>(
            valueListenable: id,
            builder: (_, id, _) =>
                DataGatewayDetailScreen(remote: remote, id: id, access: access),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(row('of_dg_1'), findsOneWidget);

      id.value = 'dg_2';
      await tester.pumpAndSettle();

      expect(linkReads().last, readCall(id: 'dg_2'));
      expect(row('of_dg_2'), findsOneWidget);
      expect(row('of_dg_1'), findsNothing);
    });
  });

  group('the layout', () {
    const large = TextScaler.linear(BgeTextScale.maxScaleFactor);
    const longValue =
        'Old Church Slavonic, as written in the Glagolitic script';
    const longName = 'Staroslověnština, církevní slovanština psaná hlaholicí';
    const longTag = LanguageTagRef(
      id: 'tag_long',
      tag: 'cu-Glag-x-liturgical',
      name: 'Church Slavonic (Glagolitic, in liturgical use)',
    );

    testWidgets('no overflow at 200% text on 320 wide, with a long value and '
        'all filters', (tester) async {
      listing({
        waiting: [
          languageLink(
            'w1',
            value: longValue,
            status: LanguageLinkStatus.pending,
            suppliedName: longName,
          ),
          languageLink('w2', value: longValue, suppliedName: longName),
        ],
        ignoredFilter: [
          languageLink(
            'i1',
            value: longValue,
            status: LanguageLinkStatus.ignored,
            suppliedName: longName,
          ),
        ],
        resolvedFilter: [
          languageLink(
            'r1',
            value: longValue,
            status: LanguageLinkStatus.resolved,
            tag: longTag,
            suppliedName: longName,
          ),
        ],
      }, hasMore: true);
      // The longest banner there is.
      remote.onAcceptLanguageLink = (_, _) async =>
          throw const DataGatewayConflictException('settled', statusCode: 409);

      await pumpScreen(tester, size: const Size(320, 568), textScaler: large);
      expect(tester.takeException(), isNull);

      await bringIntoView(tester, menu('w1'));
      await choose(tester, 'w1', LanguageLinkWorklist.acceptKey);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<BgeInlineBanner>(banner).message,
        startsWith("Couldn't add"),
      );

      for (final (of, rowId) in [
        (ignoredFilter, 'i1'),
        (resolvedFilter, 'r1'),
        (waiting, 'w1'),
      ]) {
        await press(tester, filter(of));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: of.name);
        expect(textIn(row(rowId), longValue), findsOneWidget, reason: of.name);
        await bringIntoView(tester, moreButton);
        expect(tester.takeException(), isNull, reason: of.name);
      }
    });

    testWidgets('the page ends on its usual inset, with no footer to give it', (
      tester,
    ) async {
      listing({
        waiting: [a, b],
      });
      await pumpScreen(tester, size: const Size(360, 640));
      await scrollPageTo(tester, pagePosition(tester).maxScrollExtent);

      final list = tester.getRect(find.byType(Scrollable).first);
      final inset = BgeTokens.of(tester.element(row('b'))).spaceLg;
      expect(list.bottom - tester.getRect(row('b')).bottom, inset);
    });
  });
}
