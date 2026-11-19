import 'dart:async';
import 'dart:ui' show SemanticsFlag;

import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/catalog_app.dart';

class _MockImportBloc extends MockBloc<GameImportEvent, GameImportState>
    implements GameImportBloc {
  /// What the widget asked of the bloc, in order.
  final sent = <GameImportEvent>[];

  @override
  void add(GameImportEvent event) => sent.add(event);
}

const _requested = ImportJob(
  jobId: 'j1',
  status: ImportJobStatus.running,
  origin: ImportJobOrigin.requested,
  externalId: '1',
);

ImportJob _job(
  String id, {
  ImportJobStatus status = ImportJobStatus.running,
  ImportJobOrigin origin = ImportJobOrigin.chosenExpansion,
  String? title,
  String? parent = 'j1',
  ImportErrorCode? errorCode,
  String? gameId,
}) => ImportJob(
  jobId: id,
  status: status,
  origin: origin,
  externalId: 'ext_$id',
  gameTitle: title,
  parentJobId: parent,
  errorCode: errorCode,
  gameId: gameId,
);

void main() {
  late _MockImportBloc bloc;
  late List<String> imported;
  late StreamController<GameImportState> states;

  setUp(() {
    bloc = _MockImportBloc();
    imported = [];
    states = StreamController<GameImportState>.broadcast();
  });

  tearDown(() => states.close());

  /// Holds [bloc] at [initial], and lets [states] move it.
  void startAt(GameImportState initial) =>
      whenListen(bloc, states.stream, initialState: initial);

  Future<void> move(WidgetTester tester, GameImportState next) async {
    states.add(next);
    await tester.pump();
  }

  /// The progress in a scroll view, after a control of the page's own
  /// when [lead]: one that focus history can fall back to.
  Widget host({
    bool autofocus = false,
    bool lead = false,
    Map<String, String> titles = const {},
  }) => BlocProvider<GameImportBloc>.value(
    value: bloc,
    child: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (lead) TextButton(onPressed: () {}, child: const Text('Lead')),
            GameImportProgress(
              requestedTitle: 'Spirit Island: Jagged Earth',
              titlesByExternalId: titles,
              autofocus: autofocus,
              onImported: (_, gameId) => imported.add(gameId),
            ),
          ],
        ),
      ),
    ),
  );

  Widget app({
    ValueNotifier<bool>? offline,
    Map<String, String>? titles,
    bool autofocus = false,
    bool lead = false,
  }) => catalogApp(
    host(titles: titles ?? const {}, autofocus: autofocus, lead: lead),
    offline: offline,
  );

  final status = find.byKey(GameImportProgress.statusKey);
  final checkAgain = find.byKey(GameImportProgress.checkAgainKey);
  final tryAgain = find.byKey(GameImportProgress.tryAgainKey);
  final banner = find.byType(BgeInlineBanner);

  /// The status's focus node, which the outcome banner shares.
  FocusNode statusNode(WidgetTester tester) => Focus.of(tester.element(status));

  /// The focus node of the button found by [button].
  FocusNode buttonNode(WidgetTester tester, Finder button) => Focus.of(
    tester.element(find.descendant(of: button, matching: find.byType(Text))),
  );

  /// Tabs until [node] has the focus, as a keyboard user reaches it.
  Future<void> tabTo(WidgetTester tester, FocusNode node) async {
    for (var i = 0; i < 10 && !node.hasPrimaryFocus; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(node.hasPrimaryFocus, isTrue, reason: 'Tab never reached it');
  }

  /// The ring around the status, or null while none is drawn.
  Border? statusRing(WidgetTester tester) {
    final ring = find.descendant(
      of: find.ancestor(of: status, matching: find.byType(BgeFocusRing)),
      matching: find.byType(DecoratedBox),
    );
    return (tester.widget<DecoratedBox>(ring.first).decoration as BoxDecoration)
            .border
        as Border?;
  }

  testWidgets('the status says each stage in one live region', (tester) async {
    final handle = tester.ensureSemantics();
    startAt(const GameImportStarting());
    await tester.pumpWidget(app());
    expect(find.text('Sending the import to the server…'), findsOneWidget);
    final id = tester.getSemantics(status).id;
    expect(tester.getSemantics(status), isSemantics(isLiveRegion: true));

    await move(tester, const GameImportInProgress(running: false));
    expect(
      find.text('Waiting for the server to start the import…'),
      findsOneWidget,
    );
    expect(tester.getSemantics(status).id, id);

    await move(tester, const GameImportInProgress(running: true));
    expect(find.text('Importing from the data source…'), findsOneWidget);
    expect(tester.getSemantics(status).id, id);
    expect(tester.getSemantics(status), isSemantics(isLiveRegion: true));
    handle.dispose();
  });

  testWidgets('a single-game import shows no job rows', (tester) async {
    startAt(const GameImportInProgress(running: true, jobs: [_requested]));
    await tester.pumpWidget(app());

    expect(find.byKey(GameImportProgress.jobKey('j1')), findsNothing);
    expect(find.text('Importing 1 game'), findsNothing);
  });

  testWidgets('an added base game says why it is there', (tester) async {
    final handle = tester.ensureSemantics();
    final base = _job('jb', origin: ImportJobOrigin.addedBaseGame);
    startAt(GameImportInProgress(running: true, jobs: [_requested, base]));
    await tester.pumpWidget(app());

    expect(
      find.text(
        'Also importing the base game Spirit Island: Jagged Earth needs',
      ),
      findsOneWidget,
    );

    await move(
      tester,
      GameImportInProgress(
        running: true,
        jobs: [
          _requested,
          _job(
            'jb',
            origin: ImportJobOrigin.addedBaseGame,
            status: ImportJobStatus.completed,
            title: 'Spirit Island',
          ),
        ],
      ),
    );
    expect(
      find.text(
        'Also importing Spirit Island, the base game Spirit Island: Jagged '
        'Earth needs',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a job row is read as one node', (tester) async {
    final handle = tester.ensureSemantics();
    startAt(
      GameImportInProgress(
        running: true,
        jobs: [
          _requested,
          _job(
            'j2',
            status: ImportJobStatus.completed,
            title: 'Jagged Earth',
            gameId: 'g2',
          ),
        ],
      ),
    );
    await tester.pumpWidget(app());

    expect(
      tester.getSemantics(find.byKey(GameImportProgress.jobKey('j2'))),
      isSemantics(label: 'Jagged Earth\nImported'),
    );
    expect(find.bySemanticsLabel('Importing 2 games'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('rows take their title from the lookup, and say their state', (
    tester,
  ) async {
    startAt(
      GameImportInProgress(
        running: true,
        jobs: [
          _requested,
          _job('j2', status: ImportJobStatus.pending),
          _job('j3', status: ImportJobStatus.unknown),
          _job('j4', status: ImportJobStatus.failed),
          _job('j5', status: ImportJobStatus.cancelled),
          _job(
            'j6',
            status: ImportJobStatus.cancelled,
            errorCode: ImportErrorCode.baseImportFailed,
          ),
          _job('j7'),
        ],
      ),
    );
    await tester.pumpWidget(app(titles: {'ext_j2': 'Branch & Claw'}));

    String line(String id, String text) {
      expect(
        find.descendant(
          of: find.byKey(GameImportProgress.jobKey(id)),
          matching: find.text(text),
        ),
        findsOneWidget,
        reason: '$id: $text',
      );
      return text;
    }

    line('j1', 'Spirit Island: Jagged Earth');
    line('j1', 'Importing');
    line('j2', 'Branch & Claw');
    line('j2', 'Waiting');
    line('j3', 'Importing');
    line('j4', 'Another game');
    line('j4', 'Failed');
    line('j5', 'Cancelled');
    line('j6', "Skipped: the game it goes with wasn't imported");
    line('j7', 'Importing');
  });

  testWidgets('an added base game whose parent is not listed names the game '
      'asked for', (tester) async {
    startAt(
      GameImportInProgress(
        running: true,
        jobs: [
          _requested.copyWith(gameTitle: 'Jagged Earth, as the server has it'),
          _job('jb', origin: ImportJobOrigin.addedBaseGame),
          _job('jc', origin: ImportJobOrigin.addedBaseGame, parent: 'j_gone'),
        ],
      ),
    );
    await tester.pumpWidget(app());

    // Its parent listed: named as the server names it.
    expect(
      find.descendant(
        of: find.byKey(GameImportProgress.jobKey('jb')),
        matching: find.text(
          'Also importing the base game Jagged Earth, as the server has it '
          'needs',
        ),
      ),
      findsOneWidget,
    );
    // Its parent not listed: the game asked for, as the caller named it.
    expect(
      find.descendant(
        of: find.byKey(GameImportProgress.jobKey('jc')),
        matching: find.text(
          'Also importing the base game Spirit Island: Jagged Earth needs',
        ),
      ),
      findsOneWidget,
    );
  });

  group('every state that ends the polls still draws the rows', () {
    final jobs = [
      _requested.copyWith(
        status: ImportJobStatus.failed,
        errorCode: ImportErrorCode.gatewayError,
      ),
      _job('j2', title: 'Jagged Earth'),
    ];
    for (final (name, state) in [
      ('still running', GameImportStillRunning(jobs: jobs)),
      (
        'failed',
        GameImportFailed(failure: GameImportFailure.dataGateway, jobs: jobs),
      ),
    ]) {
      testWidgets(name, (tester) async {
        startAt(state);
        await tester.pumpWidget(app());

        expect(find.byKey(GameImportProgress.jobKey('j1')), findsOneWidget);
        expect(find.byKey(GameImportProgress.jobKey('j2')), findsOneWidget);
        expect(find.text('Jagged Earth'), findsOneWidget);
      });
    }
  });

  testWidgets('completion calls onImported once', (tester) async {
    startAt(const GameImportInProgress(running: true));
    await tester.pumpWidget(app());

    await move(
      tester,
      const GameImportCompleted(gameId: 'g1', jobs: [_requested]),
    );
    await move(
      tester,
      const GameImportCompleted(gameId: 'g1', jobs: [_requested]),
    );

    expect(imported, ['g1']);
  });

  // For a caller that leaves the progress in place, or is covered as the
  // import ends.
  testWidgets('a completed import says so, with no spinner', (tester) async {
    startAt(const GameImportInProgress(running: true));
    await tester.pumpWidget(app());

    await move(
      tester,
      GameImportCompleted(
        gameId: 'g1',
        jobs: [
          _requested.copyWith(
            status: ImportJobStatus.completed,
            gameTitle: 'Spirit Island',
            gameId: 'g1',
          ),
        ],
      ),
    );

    expect(find.text('Spirit Island was imported.'), findsOneWidget);
    expect(find.text('Importing from the data source…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('running out of polls with the game imported offers Open '
      'beside Check again', (tester) async {
    startAt(const GameImportInProgress(running: true));
    await tester.pumpWidget(app());

    await move(
      tester,
      GameImportStillRunning(
        gameId: 'g1',
        jobs: [
          _requested.copyWith(
            status: ImportJobStatus.completed,
            gameTitle: 'Spirit Island',
            gameId: 'g1',
          ),
          _job('j2'),
        ],
      ),
    );

    expect(
      find.text(
        'Spirit Island was imported. The server is still importing the '
        'other games, so you can open it now, check again, or close this '
        'and search for them later.',
      ),
      findsOneWidget,
    );
    expect(checkAgain, findsOneWidget);
    expect(imported, isEmpty);
    await tester.tap(find.byKey(GameImportProgress.openKey));
    await tester.pump();
    expect(imported, ['g1']);
  });

  testWidgets('running out of polls before the game is imported offers no '
      'Open', (tester) async {
    startAt(const GameImportInProgress(running: true));
    await tester.pumpWidget(app());

    await move(tester, const GameImportStillRunning(jobs: [_requested]));

    expect(checkAgain, findsOneWidget);
    expect(find.byKey(GameImportProgress.openKey), findsNothing);
  });

  testWidgets('partly completed says what failed and opens on press', (
    tester,
  ) async {
    startAt(const GameImportInProgress(running: true));
    await tester.pumpWidget(app());

    await move(
      tester,
      GameImportPartlyCompleted(
        gameId: 'g1',
        jobs: [
          _requested.copyWith(
            status: ImportJobStatus.completed,
            gameTitle: 'Spirit Island',
            gameId: 'g1',
          ),
          _job('j2', status: ImportJobStatus.failed),
          _job('j3', status: ImportJobStatus.completed),
        ],
      ),
    );

    // An outcome on a pop-up that stays: a warning banner, its words and
    // icon saying what its tone does.
    expect(
      find.descendant(
        of: banner,
        matching: find.text(
          "Spirit Island was imported, but 1 other game wasn't.",
        ),
      ),
      findsOneWidget,
    );
    expect(tester.widget<BgeInlineBanner>(banner).tone, BgeBannerTone.warning);
    expect(
      find.descendant(of: banner, matching: find.byType(Icon)),
      findsOneWidget,
    );
    expect(imported, isEmpty);
    await tester.tap(find.byKey(GameImportProgress.openKey));
    await tester.pump();
    expect(imported, ['g1']);
    expect(find.text('Open Spirit Island'), findsOneWidget);
  });

  testWidgets('a failure is an error banner, titled, in place of the status '
      'line, and heard once', (tester) async {
    final handle = tester.ensureSemantics();
    startAt(const GameImportInProgress(running: true, jobs: [_requested]));
    await tester.pumpWidget(app());
    final node = tester.getSemantics(status).id;
    expect(banner, findsNothing);

    await move(
      tester,
      const GameImportFailed(
        failure: GameImportFailure.dataGateway,
        jobs: [_requested],
      ),
    );

    expect(tester.widget<BgeInlineBanner>(banner).tone, BgeBannerTone.error);
    expect(tester.widget<BgeInlineBanner>(banner).announce, isTrue);
    // The banner takes the status line's place: no line, no spinner.
    expect(find.text('Importing from the data source…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // One node says it, the status's own, so the change is read once.
    expect(tester.getSemantics(status).id, node);
    expect(
      tester.getSemantics(status),
      isSemantics(
        label: "Import failed\nThe data source didn't answer. Try again later.",
        isLiveRegion: true,
      ),
    );
    expect(
      find.semantics.byFlag(SemanticsFlag.isLiveRegion).evaluate(),
      hasLength(1),
    );
    handle.dispose();
  });

  testWidgets('focus on the status stays as the outcome lands, on the banner', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    startAt(const GameImportInProgress(running: true, jobs: [_requested]));
    await tester.pumpWidget(app(autofocus: true));
    await tester.pump();
    final node = statusNode(tester);
    expect(node.hasPrimaryFocus, isTrue);

    await move(
      tester,
      const GameImportFailed(
        failure: GameImportFailure.server,
        jobs: [_requested],
      ),
    );
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, same(node));
    // The focused node is the banner's: it holds the banner, and a screen
    // reader on it hears the outcome.
    expect(Focus.of(tester.element(banner)), same(node));
    expect(
      tester.getSemantics(status),
      isSemantics(
        label: "Import failed\nThe server couldn't import this game.",
        isFocused: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('the status is no Tab stop', (tester) async {
    startAt(const GameImportStillRunning(jobs: [_requested]));
    await tester.pumpWidget(app(autofocus: true, lead: true));
    await tester.pump();
    final node = statusNode(tester);
    expect(node.hasPrimaryFocus, isTrue);

    final visited = <FocusNode?>[];
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      visited.add(FocusManager.instance.primaryFocus);
    }
    expect(visited, contains(buttonNode(tester, checkAgain)));
    expect(visited, isNot(contains(node)));
  });

  group('the status hand-off by keyboard is ringed', () {
    tearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );

    testWidgets('with a keyboard', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      startAt(const GameImportInProgress(running: true));
      await tester.pumpWidget(app(autofocus: true));
      expect(statusRing(tester), isNull);
      await tester.pump();

      expect(statusNode(tester).hasPrimaryFocus, isTrue);
      final context = tester.element(status);
      final ring = statusRing(tester);
      expect(ring?.top.color, Theme.of(context).colorScheme.primary);
      expect(ring?.top.width, BgeTokens.of(context).focusOutlineWidth);
    });

    // The ring is drawn inside its box: its inner edge keeps focusRingGap
    // off the banner's fill, as a filled button's outside ring does.
    testWidgets("clear of the banner's fill", (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      startAt(const GameImportFailed(failure: GameImportFailure.server));
      await tester.pumpWidget(app(autofocus: true));
      await tester.pump();
      expect(statusRing(tester), isNotNull);

      final tokens = BgeTokens.of(tester.element(status));
      final reach = tokens.focusRingGap + tokens.focusOutlineWidth;
      final ringBox = find
          .descendant(
            of: find.ancestor(of: status, matching: find.byType(BgeFocusRing)),
            matching: find.byType(DecoratedBox),
          )
          .first;
      expect(tester.getRect(ringBox), tester.getRect(banner).inflate(reach));
      expect(
        (tester.widget<DecoratedBox>(ringBox).decoration as BoxDecoration)
            .borderRadius,
        BorderRadius.circular(tokens.radiusMd + reach),
      );
    });

    testWidgets('not for a touch', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      startAt(const GameImportInProgress(running: true));
      await tester.pumpWidget(app(autofocus: true));
      await tester.pump();

      expect(statusNode(tester).hasPrimaryFocus, isTrue);
      expect(statusRing(tester), isNull);
    });
  });

  testWidgets('check again asks the bloc to poll, offline too', (tester) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    startAt(const GameImportStillRunning(jobs: [_requested]));
    await tester.pumpWidget(app(offline: offline));

    expect(tester.widget<TextButton>(checkAgain).onPressed, isNotNull);
    await tester.tap(checkAgain);
    expect(bloc.sent, [const GameImportCheckAgainRequested()]);
  });

  group('check again stays through its own poll', () {
    /// Presses Check again by keyboard, and has the bloc start the poll.
    /// Gives its focus node, and its semantics node's id when semantics are
    /// on.
    Future<(FocusNode, int?)> pressCheckAgain(WidgetTester tester) async {
      startAt(const GameImportStillRunning(jobs: [_requested]));
      await tester.pumpWidget(app(lead: true));
      final again = buttonNode(tester, checkAgain);
      final node = tester.binding.semanticsEnabled
          ? tester.getSemantics(checkAgain).id
          : null;
      await tabTo(tester, again);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(bloc.sent, [const GameImportCheckAgainRequested()]);
      await move(
        tester,
        const GameImportInProgress(running: true, jobs: [_requested]),
      );
      return (again, node);
    }

    testWidgets('inert, in place and focused, while the poll runs', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final (again, node) = await pressCheckAgain(tester);

      expect(checkAgain, findsOneWidget);
      expect(buttonNode(tester, checkAgain), same(again));
      expect(again.hasPrimaryFocus, isTrue);
      expect(tester.getSemantics(checkAgain).id, node);
      expect(
        tester.getSemantics(checkAgain),
        isSemantics(
          label: 'Check again',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocused: true,
          hasTapAction: false,
        ),
      );

      // A press while it runs does nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(bloc.sent, [const GameImportCheckAgainRequested()]);
      handle.dispose();
    });

    testWidgets('live again, with its focus, when the poll runs out again', (
      tester,
    ) async {
      final (again, _) = await pressCheckAgain(tester);

      await move(tester, const GameImportStillRunning(jobs: [_requested]));
      expect(buttonNode(tester, checkAgain), same(again));
      expect(again.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(bloc.sent, [
        const GameImportCheckAgainRequested(),
        const GameImportCheckAgainRequested(),
      ]);
    });

    testWidgets('gone once the import fails, with focus on the status', (
      tester,
    ) async {
      await pressCheckAgain(tester);

      await move(
        tester,
        const GameImportFailed(
          failure: GameImportFailure.notOnDataGateway,
          jobs: [_requested],
        ),
      );
      await tester.pump();

      expect(checkAgain, findsNothing);
      expect(FocusManager.instance.primaryFocus, same(statusNode(tester)));
    });
  });

  group('try again stays through its own start', () {
    /// Presses Try again by keyboard, and has the bloc start again. Gives
    /// its focus node, and its semantics node's id when semantics are on.
    Future<(FocusNode, int?)> pressTryAgain(
      WidgetTester tester, {
      ValueNotifier<bool>? offline,
    }) async {
      startAt(const GameImportFailed(failure: GameImportFailure.server));
      await tester.pumpWidget(app(lead: true, offline: offline));
      final again = buttonNode(tester, tryAgain);
      final node = tester.binding.semanticsEnabled
          ? tester.getSemantics(tryAgain).id
          : null;
      await tabTo(tester, again);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(bloc.sent, [const GameImportRequested()]);
      await move(tester, const GameImportStarting());
      return (again, node);
    }

    testWidgets('inert, in place and focused, while the start runs', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final (again, node) = await pressTryAgain(tester);

      for (final state in [
        const GameImportStarting(),
        const GameImportInProgress(running: false),
        const GameImportInProgress(running: true, jobs: [_requested]),
      ]) {
        await move(tester, state);
        expect(buttonNode(tester, tryAgain), same(again), reason: '$state');
        expect(again.hasPrimaryFocus, isTrue, reason: '$state');
        expect(tester.getSemantics(tryAgain).id, node, reason: '$state');
        expect(
          tester.getSemantics(tryAgain),
          isSemantics(
            label: 'Try again',
            isEnabled: false,
            isFocused: true,
            hasTapAction: false,
          ),
          reason: '$state',
        );
        // A press while it runs does nothing.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(bloc.sent, [const GameImportRequested()], reason: '$state');
      }
      handle.dispose();
    });

    testWidgets('live again, with its focus, when the start fails again', (
      tester,
    ) async {
      final (again, _) = await pressTryAgain(tester);

      await move(
        tester,
        const GameImportFailed(failure: GameImportFailure.unreachable),
      );
      expect(buttonNode(tester, tryAgain), same(again));
      expect(again.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(bloc.sent, [
        const GameImportRequested(),
        const GameImportRequested(),
      ]);
    });

    // Offered again, but disabled offline, where it can hold no focus.
    testWidgets('failing again offline hands its focus to the status', (
      tester,
    ) async {
      final offline = ValueNotifier(false);
      addTearDown(offline.dispose);
      final (again, _) = await pressTryAgain(tester, offline: offline);

      offline.value = true;
      await tester.pump();
      // Its own start runs: it keeps its focus through it.
      expect(again.hasPrimaryFocus, isTrue);

      await move(
        tester,
        const GameImportFailed(failure: GameImportFailure.unreachable),
      );
      await tester.pump();

      expect(tester.widget<TextButton>(tryAgain).onPressed, isNull);
      expect(FocusManager.instance.primaryFocus, same(statusNode(tester)));
    });

    testWidgets('gone once the polls run out, with focus on the status', (
      tester,
    ) async {
      await pressTryAgain(tester);

      await move(tester, const GameImportStillRunning(jobs: [_requested]));
      await tester.pump();

      expect(tryAgain, findsNothing);
      expect(checkAgain, findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(statusNode(tester)));
    });
  });

  testWidgets('try again is disabled offline and kept in the tree, its note '
      'under it', (tester) async {
    final handle = tester.ensureSemantics();
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    startAt(const GameImportFailed(failure: GameImportFailure.server));
    await tester.pumpWidget(app(offline: offline));

    expect(tester.widget<TextButton>(tryAgain).onPressed, isNull);
    expect(
      tester.getSemantics(tryAgain),
      matchesSemantics(
        label: 'Try again',
        hint: onlineOnlyCopy,
        isButton: true,
        hasEnabledState: true,
      ),
    );
    final note = find.text(onlineOnlyCopy);
    expect(note, findsOneWidget);
    expect(
      tester.getRect(note).top,
      greaterThanOrEqualTo(tester.getRect(tryAgain).bottom),
    );
    final node = tester.getSemantics(status).id;

    offline.value = false;
    await tester.pump();
    expect(tester.getSemantics(status).id, node);
    expect(note, findsNothing);
    expect(tester.widget<TextButton>(tryAgain).onPressed, isNotNull);
    await tester.tap(tryAgain);
    expect(bloc.sent, [const GameImportRequested()]);
    handle.dispose();
  });

  testWidgets('a failure that cannot change offers no try again', (
    tester,
  ) async {
    startAt(const GameImportFailed(failure: GameImportFailure.forbidden));
    await tester.pumpWidget(app());

    expect(tryAgain, findsNothing);
    expect(
      find.descendant(
        of: banner,
        matching: find.text(
          "You don't have permission to import games on this server.",
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('autofocus focuses the status', (tester) async {
    startAt(const GameImportStarting());
    await tester.pumpWidget(catalogApp(host(autofocus: true)));
    await tester.pump();

    final focus = Focus.of(tester.element(status));
    expect(focus.hasPrimaryFocus, isTrue);
    expect(FocusManager.instance.primaryFocus, focus);
  });

  group('accessibility audit', () {
    auditScreen(
      'partly completed, three jobs',
      build: (theme) {
        whenListen(
          bloc,
          const Stream<GameImportState>.empty(),
          initialState: GameImportPartlyCompleted(
            gameId: 'g1',
            jobs: [
              _requested.copyWith(
                status: ImportJobStatus.completed,
                gameTitle: 'Spirit Island',
                gameId: 'g1',
              ),
              _job('j2', status: ImportJobStatus.failed),
              _job(
                'j3',
                status: ImportJobStatus.cancelled,
                errorCode: ImportErrorCode.baseImportFailed,
              ),
            ],
          ),
        );
        return catalogApp(host(), theme: theme);
      },
    );
    auditScreen(
      'failed, two jobs, try again',
      build: (theme) {
        whenListen(
          bloc,
          const Stream<GameImportState>.empty(),
          initialState: GameImportFailed(
            failure: GameImportFailure.dataGateway,
            jobs: [
              _requested.copyWith(
                status: ImportJobStatus.failed,
                errorCode: ImportErrorCode.gatewayError,
              ),
              _job(
                'j2',
                status: ImportJobStatus.cancelled,
                errorCode: ImportErrorCode.baseImportFailed,
              ),
            ],
          ),
        );
        return catalogApp(host(), theme: theme);
      },
    );
  });
}
