import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/expansions/expansion_checklist.dart';
import 'package:game_catalog/src/quick_look/quick_look_layout.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

const _gateway = 'bgg';

/// Many lines of one paragraph at any width these tests use, so the quick
/// look's long description is what the panel sits below.
final String _long = List.filled(80, 'word').join(' ');

final _wingspan = GameSearchHit(
  externalId: '20',
  title: 'Wingspan',
  contentType: ContentType.baseGame,
  summary: 'Attract birds to your wildlife preserves.\n\n$_long',
);

/// [count] expansions of Wingspan at BoardGameGeek, External IDs 21 on.
/// [onServer] marks the first as one the server holds.
GameSearchResults _expansions(int count, {bool onServer = false}) =>
    GameSearchResults(
      byDataGateway: {
        _gateway: [
          for (var n = 1; n <= count; n++)
            GameSearchHit(
              externalId: '${20 + n}',
              title: 'Wingspan expansion $n',
              contentType: ContentType.expansion,
              gameId: onServer && n == 1 ? 'g_expansion_1' : null,
            ),
        ],
      },
    );

/// A poll's answer: the requested game, [status], with any [others].
ImportBatch _batch(
  ImportJobStatus status, {
  String? gameId,
  List<ImportJob> others = const [],
}) => ImportBatch(
  batchId: 'b1',
  correlationId: 'c1',
  status: ImportBatchStatus.running,
  jobs: [
    ImportJob(
      jobId: 'j1',
      status: status,
      origin: ImportJobOrigin.requested,
      externalId: '20',
      gameId: gameId,
      gameTitle: gameId == null ? null : 'Wingspan',
    ),
    ...others,
  ],
);

/// An expansion chosen with the requested game, untitled until it lands.
ImportJob _chosen(String externalId, ImportJobStatus status) => ImportJob(
  jobId: 'j$externalId',
  status: status,
  origin: ImportJobOrigin.chosenExpansion,
  parentJobId: 'j1',
  externalId: externalId,
  gameId: status == ImportJobStatus.completed ? 'g$externalId' : null,
);

void main() {
  late FakeGamesRemote remote;
  late List<String> imported;

  setUp(() {
    remote = FakeGamesRemote();
    imported = [];
  });

  /// The import's host over a quick look's layout, as the search gives it:
  /// the section and the button under it share its state.
  QuickLookHost host({
    GameSearchHit? hit,
    bool mayChooseExpansions = true,
    DataGatewaySearchGrant? grant,
    void Function(BuildContext context, String gameId)? onImported,
  }) =>
      (context, layout) => GameImportPanel(
        remote: remote,
        gatewayId: _gateway,
        hit: hit ?? _wingspan,
        mayChooseExpansions: mayChooseExpansions,
        grant: grant,
        sourceNames: const {_gateway: 'BoardGameGeek'},
        onImported: onImported ?? (_, gameId) => imported.add(gameId),
        child: layout,
      );

  /// The three parts on a plain page: [host] over the section, in the page's
  /// scroll view, and the button under it.
  Widget inPage(QuickLookHost host, {ValueListenable<bool>? offline}) =>
      catalogApp(
        Builder(
          builder: (context) => host(
            context,
            const Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(child: GameImportSection()),
                  ),
                  GameImportButton(),
                ],
              ),
            ),
          ),
        ),
        offline: offline,
      );

  /// A page whose button opens [hit]'s quick look under [host], with the
  /// import's section between [above] and [below] and its button pinned, as
  /// the search opens it. Without [section] the quick look has the button
  /// alone.
  Widget opener(
    QuickLookHost host, {
    GameSearchHit? hit,
    List<Widget> above = const [],
    List<Widget> below = const [],
    bool section = true,
  }) => Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => TextButton(
          onPressed: () => unawaited(
            showSearchHitQuickLook(
              context,
              hit: hit ?? _wingspan,
              sourceName: 'BoardGameGeek',
              host: host,
              sections: [
                ...above,
                if (section) const GameImportSection(),
                ...below,
              ],
              footer: const GameImportButton(),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  /// Opens the quick look on a phone, where it is a sheet.
  Future<void> openQuickLook(
    WidgetTester tester,
    QuickLookHost host, {
    GameSearchHit? hit,
    Size view = const Size(400, 800),
    List<Widget> above = const [],
    List<Widget> below = const [],
    bool section = true,
    ValueListenable<bool>? offline,
  }) async {
    useViewSize(tester, view);
    await tester.pumpWidget(
      catalogApp(
        opener(
          host,
          hit: hit,
          above: above,
          below: below,
          section: section,
        ),
        offline: offline,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  }

  /// Wingspan as a DataGateway result the server holds.
  final held = _wingspan.copyWith(gameId: 'g_wingspan');

  /// Opens the held Wingspan's quick look under [host], which reads the game,
  /// with the import's section and its button pinned.
  Future<void> openHeldQuickLook(
    WidgetTester tester,
    QuickLookHost host, {
    Size view = const Size(400, 800),
  }) async {
    useViewSize(tester, view);
    await tester.pumpWidget(
      catalogApp(
        Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  showGameQuickLook(
                    context,
                    seed: const GameQuickLookSeed(
                      id: 'g_wingspan',
                      title: 'Wingspan',
                    ),
                    remote: remote,
                    host: host,
                    sections: const [GameImportSection()],
                    footer: const GameImportButton(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(GameQuickLook), findsOneWidget);
  }

  /// What the read of the held Wingspan answers.
  GameWithPlatformGames wingspanRead() => (
    game: game(
      'g_wingspan',
      title: 'Wingspan',
    ).copyWith(minPlayers: 1, maxPlayers: 5, description: _long),
    platformGames: [
      PlatformGame(
        id: 'pg_1',
        gameId: 'g_wingspan',
        platformId: 'plat_pg_1',
        platformName: 'Tabletop',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    ],
  );

  /// The quick look's own scroll view, which the footer is pinned under.
  final body = find
      .descendant(
        of: find.byType(QuickLookLayout),
        matching: find.byType(Scrollable),
      )
      .first;

  /// The pinned footer's band.
  final footer = find.byKey(QuickLookLayout.footerKey);

  final importButton = find.byKey(GameImportPanel.importKey);

  String? label(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(of: importButton, matching: find.byType(Text)),
      )
      .data;

  FilledButton button(WidgetTester tester) =>
      tester.widget<FilledButton>(importButton);

  Future<void> tick(WidgetTester tester, String externalId) async {
    final row = find.byKey(ExpansionChecklist.rowKey(_gateway, externalId));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// Presses Import, and lets the start reach the fake.
  Future<void> pressImport(WidgetTester tester) async {
    await tester.ensureVisible(importButton);
    await tester.pumpAndSettle();
    await tester.tap(importButton);
    await tester.pump();
    await tester.pump(Duration.zero);
  }

  /// The server queues the import as batch `b1`.
  void queues() =>
      remote.onStartImport = (_, _, correlationId) async => GameImportReceipt(
        batchId: 'b1',
        baseJobId: 'j1',
        correlationId: correlationId,
      );

  /// Each poll answers the next of [answers], and the last from then on.
  void polls(List<ImportBatch> answers) {
    var next = 0;
    remote.onFetchImport = (_) async =>
        answers[next < answers.length - 1 ? next++ : next];
  }

  int fetches() =>
      remote.calls.where((call) => call.startsWith('fetchImport')).length;

  testWidgets('without mayChooseExpansions there is no checklist and no '
      'expansions request', (tester) async {
    final start = Completer<GameImportReceipt>();
    remote.onStartImport = (_, _, _) => start.future;
    await tester.pumpWidget(inPage(host(mayChooseExpansions: false)));
    await tester.pumpAndSettle();

    expect(find.byType(ExpansionChecklist), findsNothing);
    expect(find.text('Expansions'), findsNothing);
    expect(remote.expansionTargets, isEmpty);
    expect(label(tester), 'Import');

    await pressImport(tester);
    expect(remote.importedExpansions, [<String>[]]);
    expect(remote.expansionTargets, isEmpty);
  });

  testWidgets('the button counts the ticked expansions', (tester) async {
    remote.onFetchExpansions = (_) async => _expansions(3);
    await tester.pumpWidget(inPage(host()));
    await tester.pumpAndSettle();

    expect(remote.expansionTargets, [
      const GameExpansionsTarget.dataGateway(
        gatewayId: _gateway,
        externalId: '20',
      ),
    ]);
    expect(find.byType(ExpansionChecklist), findsOneWidget);
    expect(label(tester), 'Import');

    await tick(tester, '21');
    expect(label(tester), 'Import with 1 expansion');
    await tick(tester, '22');
    expect(label(tester), 'Import with 2 expansions');
    await tick(tester, '21');
    expect(label(tester), 'Import with 1 expansion');
  });

  testWidgets('a game on the server says Re-import', (tester) async {
    remote.onFetchExpansions = (_) async => _expansions(2, onServer: true);
    await tester.pumpWidget(
      inPage(host(hit: held)),
    );
    await tester.pumpAndSettle();

    expect(label(tester), 'Re-import');
    // Imported again, an expansion the server holds can be ticked too.
    await tick(tester, '21');
    expect(label(tester), 'Re-import with 1 expansion');
    await tick(tester, '22');
    expect(label(tester), 'Re-import with 2 expansions');
  });

  testWidgets('Import sends the ticked expansions', (tester) async {
    remote.onFetchExpansions = (_) async => _expansions(3);
    queues();
    polls([
      _batch(
        ImportJobStatus.running,
        others: [
          _chosen('21', ImportJobStatus.pending),
          _chosen('22', ImportJobStatus.pending),
        ],
      ),
      _batch(
        ImportJobStatus.completed,
        gameId: 'g1',
        others: [
          _chosen('21', ImportJobStatus.completed),
          _chosen('22', ImportJobStatus.completed),
        ],
      ),
    ]);
    await tester.pumpWidget(inPage(host()));
    await tester.pumpAndSettle();

    // Ticked out of order: the request lists them in the rows' order.
    await tick(tester, '22');
    await tick(tester, '21');
    await pressImport(tester);

    expect(remote.importedExpansions, [
      ['21', '22'],
    ]);
    expect(remote.calls, contains(startsWith('startImport(bgg/20 ')));
    // The progress takes the place of the checklist and the button.
    expect(find.byType(GameImportProgress), findsOneWidget);
    expect(find.byType(ExpansionChecklist), findsNothing);
    expect(importButton, findsNothing);

    // The chosen expansions' rows are named from the checklist.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Wingspan expansion 1'), findsOneWidget);
    expect(find.text('Wingspan expansion 2'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(imported, ['g1']);
  });

  testWidgets('Import stays enabled while the checklist loads or has failed, '
      'and takes the base game alone', (tester) async {
    final answer = Completer<GameSearchResults>();
    remote.onFetchExpansions = (_) => answer.future;
    final start = Completer<GameImportReceipt>();
    remote.onStartImport = (_, _, _) => start.future;
    await tester.pumpWidget(inPage(host()));
    await tester.pump();

    expect(find.byType(BgeLoadingState), findsOneWidget);
    expect(button(tester).onPressed, isNotNull);

    answer.completeError(unreachable());
    await tester.pumpAndSettle();
    expect(find.byKey(ExpansionChecklist.retryKey), findsOneWidget);
    expect(button(tester).onPressed, isNotNull);
    expect(label(tester), 'Import');

    await pressImport(tester);
    expect(remote.importedExpansions, [<String>[]]);
  });

  testWidgets('a refusal is remembered on the grant', (tester) async {
    final grant = DataGatewaySearchGrant();
    remote.onFetchExpansions = (_) async =>
        throw const GamesForbiddenException('no', apiMessage: 'Not for you');
    await tester.pumpWidget(inPage(host(grant: grant)));
    await tester.pumpAndSettle();

    expect(grant.mayAsk, isFalse);
    expect(find.text('Expansions'), findsNothing);
    expect(label(tester), 'Import');
  });

  testWidgets('focus moves to the progress status', (tester) async {
    // Disposed in a finally: flutter_test checks for live handles before
    // it runs teardowns, so addTearDown can't dispose one.
    final handle = tester.ensureSemantics();
    try {
      remote.onFetchExpansions = (_) async => _expansions(2);
      final start = Completer<GameImportReceipt>();
      remote.onStartImport = (_, _, _) => start.future;
      // A stop above the section that stays built when the checklist and
      // Import give way to the progress: the focus history the status must
      // win focus from. The description has no such control (#1091).
      final before = FocusNode(debugLabel: 'before');
      addTearDown(before.dispose);
      await openQuickLook(
        tester,
        host(),
        above: [
          TextButton(
            focusNode: before,
            onPressed: () {},
            child: const Text('Before'),
          ),
        ],
      );

      final import = Focus.of(
        tester.element(
          find.descendant(of: importButton, matching: find.byType(Text)),
        ),
      );
      final visited = <FocusNode>[];
      for (var i = 0; i < 20 && !import.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        visited.add(FocusManager.instance.primaryFocus!);
      }
      expect(import.hasPrimaryFocus, isTrue);
      // On the way it passed the stop above the panel, and the checklist.
      expect(visited, contains(before));
      expect(visited.length, greaterThan(2));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.byType(GameImportProgress), findsOneWidget);
      final status = Focus.of(
        tester.element(find.byKey(GameImportProgress.statusKey)),
      );
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);
      final where = focused!.context == null
          ? '$focused'
          : tester
                .getSemantics(
                  find.byElementPredicate((e) => e == focused.context),
                )
                .getSemanticsData()
                .label;
      expect(
        focused,
        isNot(isA<FocusScopeNode>()),
        reason: 'focus is on $where',
      );
      expect(focused, same(status), reason: 'focus is on "$where"');

      // A screen reader follows it to one node: the live region that says
      // where the import stands, not an unnamed node around it.
      await tester.pump();
      final node = tester.getSemantics(
        find.byKey(GameImportProgress.statusKey),
      );
      expect(
        node,
        isSemantics(
          label: 'Sending the import to the server…',
          isLiveRegion: true,
          isFocused: true,
        ),
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets(
    'a mouse press on Import leaves the status focused and unringed, and a '
    'key press brings the ring back (#1039)',
    (tester) async {
      remote.onFetchExpansions = (_) async => _expansions(2);
      final start = Completer<GameImportReceipt>();
      remote.onStartImport = (_, _, _) => start.future;
      await openQuickLook(tester, host());
      await tester.ensureVisible(importButton);
      await tester.pumpAndSettle();
      // At a desktop: a key press puts the highlight mode at the keyboard's,
      // where the opener's touch left it at touch's.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      final at = tester.getCenter(importButton);
      await mouse.addPointer(location: at);
      addTearDown(mouse.removePointer);
      await mouse.down(at);
      await mouse.up();
      await tester.pump();
      await tester.pump();

      // A mouse leaves the highlight mode as it was, the keyboard's, so only
      // the app's pointer flag can keep the ring hidden (#758).
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      final status = Focus.of(
        tester.element(find.byKey(GameImportProgress.statusKey)),
      );
      expect(status.hasPrimaryFocus, isTrue);

      bool ringDrawn() {
        final ring = find.ancestor(
          of: find.byKey(GameImportProgress.statusKey),
          matching: find.byType(BgeFocusRing),
        );
        final drawn = tester.widget<DecoratedBox>(
          find.descendant(of: ring, matching: find.byType(DecoratedBox)).first,
        );
        return (drawn.decoration as BoxDecoration).border != null;
      }

      expect(ringDrawn(), isFalse, reason: 'no ring after a click');

      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(status.hasPrimaryFocus, isTrue);
      expect(ringDrawn(), isTrue, reason: 'the keyboard is back');
    },
  );

  testWidgets('closing the quick look stops the import and opens nothing', (
    tester,
  ) async {
    remote.onFetchExpansions = (_) async => _expansions(2);
    queues();
    polls([
      _batch(ImportJobStatus.running),
      _batch(ImportJobStatus.completed, gameId: 'g1'),
    ]);
    await openQuickLook(tester, host());
    await pressImport(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(fetches(), 1);

    // Back, as a user leaving mid-import does. The sheet stays mounted
    // through its exit, while each pump below elapses a poll's wait first.
    expect(await tester.binding.handlePopRoute(), isTrue);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 2));
    }

    expect(find.byType(SearchHitQuickLook), findsNothing);
    expect(fetches(), 1);
    expect(imported, isEmpty);
  });

  testWidgets('a router dropping the page stops the import too', (
    tester,
  ) async {
    useViewSize(tester, const Size(400, 800));
    remote.onFetchExpansions = (_) async => _expansions(2);
    queues();
    polls([
      _batch(ImportJobStatus.running),
      _batch(ImportJobStatus.completed, gameId: 'g1'),
    ]);
    // A pages-driven root navigator, as go_router's is: replacing the page
    // completes it and the pop-up above it, which no PopScope hears.
    final pages = ValueNotifier<List<Page<void>>>([
      MaterialPage<void>(key: const ValueKey('search'), child: opener(host())),
    ]);
    addTearDown(pages.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: const [
          ...GameCatalogLocalizations.localizationsDelegates,
          GameFiltersLocalizations.delegate,
        ],
        supportedLocales: GameCatalogLocalizations.supportedLocales,
        builder: (context, _) => ValueListenableBuilder(
          valueListenable: pages,
          builder: (context, list, _) =>
              Navigator(pages: list, onDidRemovePage: (_) {}),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await pressImport(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(fetches(), 1);

    pages.value = [
      const MaterialPage<void>(
        key: ValueKey('elsewhere'),
        child: Scaffold(body: Text('elsewhere')),
      ),
    ];
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 2));
    }

    expect(find.text('elsewhere'), findsOneWidget);
    expect(find.byType(SearchHitQuickLook), findsNothing);
    expect(fetches(), 1);
    expect(imported, isEmpty);
  });

  testWidgets('the quick look removing itself under a page stops the import '
      'and opens nothing', (tester) async {
    queues();
    polls([
      _batch(ImportJobStatus.running),
      _batch(ImportJobStatus.completed, gameId: 'g1'),
    ]);
    await openQuickLook(tester, host(mayChooseExpansions: false));
    await pressImport(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(fetches(), 1);

    // A page pushed over the quick look: once it has arrived, the quick look
    // removes itself (#707), which no PopScope hears.
    Navigator.of(
      tester.element(find.byType(GameImportPanel)),
      rootNavigator: true,
    ).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('page')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      find.byType(SearchHitQuickLook, skipOffstage: false),
      findsNothing,
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 2));
    }

    expect(find.text('page'), findsOneWidget);
    expect(fetches(), 1);
    expect(imported, isEmpty);
  });

  testWidgets('a completion while a dialog covers the quick look waits for '
      'it to close', (tester) async {
    queues();
    polls([
      _batch(ImportJobStatus.running),
      _batch(ImportJobStatus.completed, gameId: 'g1'),
    ]);
    await openQuickLook(tester, host(mayChooseExpansions: false));
    await pressImport(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(fetches(), 1);

    // A dialog over the quick look leaves it in place (#707).
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(GameImportPanel)),
        builder: (_) => const AlertDialog(content: Text('cover')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('cover'), findsOneWidget);

    // The import completes under it: nothing opens over the dialog.
    await tester.pump(const Duration(seconds: 2));
    expect(fetches(), 2);
    await tester.pump();
    expect(imported, isEmpty);

    Navigator.of(tester.element(find.text('cover'))).pop();
    await tester.pump();
    await tester.pump();
    expect(imported, ['g1']);

    await tester.pump(const Duration(seconds: 2));
    expect(imported, ['g1']);
  });

  testWidgets("completion hands the panel's context to onImported", (
    tester,
  ) async {
    BuildContext? given;
    queues();
    polls([_batch(ImportJobStatus.completed, gameId: 'g1')]);
    await openQuickLook(
      tester,
      host(
        mayChooseExpansions: false,
        onImported: (context, gameId) {
          given = context;
          imported.add(gameId);
        },
      ),
    );
    await pressImport(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(imported, ['g1']);
    final context = given!;
    expect(context.mounted, isTrue);
    expect(context.widget, isA<GameImportPanel>());
    final popup = ModalRoute.of(
      tester.element(find.byType(SearchHitQuickLook)),
    );
    expect(popup, isA<PopupRoute<Object?>>());
    expect(ModalRoute.of(context), same(popup));
  });

  testWidgets('Import is disabled offline', (tester) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    remote.onFetchExpansions = (_) async => _expansions(2);
    await tester.pumpWidget(inPage(host(), offline: offline));
    await tester.pumpAndSettle();

    // Reading the expansions is not a write: they load offline.
    expect(remote.expansionTargets, hasLength(1));
    expect(find.text('Wingspan expansion 1'), findsOneWidget);
    // Disabled, not hidden, and it says why.
    expect(importButton, findsOneWidget);
    expect(button(tester).onPressed, isNull);
    expect(find.text(onlineOnlyCopy), findsOneWidget);

    offline.value = false;
    await tester.pump();
    expect(button(tester).onPressed, isNotNull);
    expect(find.text(onlineOnlyCopy), findsNothing);
  });

  group('Import is pinned below the quick look (#1037)', () {
    final selectAll = find.byKey(ExpansionChecklist.selectAllKey(_gateway));
    final lastOfFifty = find.byKey(ExpansionChecklist.rowKey(_gateway, '70'));
    final status = find.byKey(GameImportProgress.statusKey);

    /// Draws at 2.0 text, the largest the app supports.
    void doubleText(WidgetTester tester) {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    /// Scrolls [target] into the quick look's view.
    Future<void> reveal(WidgetTester tester, Finder target) async {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
    }

    ScrollPosition bodyPosition(WidgetTester tester) =>
        tester.state<ScrollableState>(body).position;

    testWidgets('Import sits in the pinned footer and stays on screen while '
        'the checklist scrolls', (tester) async {
      doubleText(tester);
      remote.onFetchExpansions = (_) async => _expansions(50);
      await openQuickLook(tester, host(hit: held), view: const Size(320, 640));
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(GameImportPanel)),
        ).scale(10),
        20,
      );
      expect(tester.takeException(), isNull);

      // In the footer, under the scroll view and not in it, and on screen
      // before anything is scrolled: the checklist is far below the view.
      expect(
        find.ancestor(of: importButton, matching: footer),
        findsOneWidget,
      );
      expect(find.descendant(of: body, matching: importButton), findsNothing);
      expect(
        tester.getRect(footer).top,
        moreOrLessEquals(tester.getRect(body).bottom),
      );
      expect(label(tester), 'Re-import');
      expect(importButton.hitTestable(), findsOneWidget);
      expect(selectAll.hitTestable(), findsNothing);

      await reveal(tester, selectAll);
      expect(selectAll.hitTestable(), findsOneWidget);
      await tester.tap(selectAll);
      await tester.pumpAndSettle();
      expect(label(tester), 'Re-import with 50 expansions');
      expect(importButton.hitTestable(), findsOneWidget);

      // The last expansion is in reach above the footer, and Import is
      // still there with its count.
      await reveal(tester, lastOfFifty);
      expect(lastOfFifty.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(lastOfFifty).bottom,
        lessThanOrEqualTo(tester.getRect(footer).top),
      );
      expect(label(tester), 'Re-import with 50 expansions');
      expect(importButton.hitTestable(), findsOneWidget);
      final shown = tester.getRect(importButton);
      expect(shown.left, greaterThanOrEqualTo(0), reason: '$shown');
      expect(shown.right, lessThanOrEqualTo(320), reason: '$shown');
      expect(shown.bottom, lessThanOrEqualTo(640), reason: '$shown');
      expect(tester.takeException(), isNull);
    });

    testWidgets('ticking an expansion updates the pinned count', (
      tester,
    ) async {
      remote.onFetchExpansions = (_) async => _expansions(50);
      await openQuickLook(tester, host());
      expect(label(tester), 'Import');

      // Ticked far apart, each out of view of the other: the count is in
      // view with either.
      await tick(tester, '21');
      expect(label(tester), 'Import with 1 expansion');
      expect(importButton.hitTestable(), findsOneWidget);
      await tick(tester, '70');
      expect(label(tester), 'Import with 2 expansions');
      expect(importButton.hitTestable(), findsOneWidget);
      await tick(tester, '70');
      expect(label(tester), 'Import with 1 expansion');
    });

    testWidgets('pressing Import empties the footer, puts the progress where '
        'the checklist was, and moves focus to its status', (tester) async {
      remote.onFetchExpansions = (_) async => _expansions(3);
      final start = Completer<GameImportReceipt>();
      remote.onStartImport = (_, _, _) => start.future;
      await openQuickLook(tester, host());
      final step = BgeTokens.of(
        tester.element(find.byType(GameImportPanel)),
      ).spaceMd;
      final description = find.byType(GameDescription);
      expect(tester.getSize(footer).height, greaterThan(0));
      expect(
        tester.getRect(find.byType(GameImportSection)).top -
            tester.getRect(description).bottom,
        step,
      );

      await tester.tap(importButton);
      await tester.pump();
      await tester.pump();

      // The button and the checklist give way together (#824).
      expect(importButton, findsNothing);
      expect(find.byType(ExpansionChecklist), findsNothing);
      // The footer leaves no strip behind.
      expect(tester.getSize(footer).height, 0);
      // The progress is in the scroll view, in the section's place.
      expect(
        find.descendant(of: body, matching: find.byType(GameImportProgress)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(GameImportSection),
          matching: find.byType(GameImportProgress),
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(find.byType(GameImportProgress)).top -
            tester.getRect(description).bottom,
        step,
      );
      expect(Focus.of(tester.element(status)).hasPrimaryFocus, isTrue);
      expect(status.hitTestable(), findsOneWidget);
    });

    testWidgets('pressing Import with the checklist out of view brings the '
        'status into view', (tester) async {
      doubleText(tester);
      remote.onFetchExpansions = (_) async => _expansions(3);
      final start = Completer<GameImportReceipt>();
      remote.onStartImport = (_, _, _) => start.future;
      await openQuickLook(tester, host(), view: const Size(320, 640));
      // At the top of a long description: the checklist, where the progress
      // will go, is below the view.
      expect(bodyPosition(tester).pixels, 0);
      expect(
        tester.getRect(find.byType(GameImportSection)).top,
        greaterThan(tester.getRect(body).bottom),
      );

      await tester.tap(importButton);
      await tester.pump();
      await tester.pump();

      final view = tester.getRect(body);
      final shown = tester.getRect(status);
      expect(shown.top, greaterThanOrEqualTo(view.top), reason: '$shown');
      expect(shown.bottom, lessThanOrEqualTo(view.bottom), reason: '$shown');
      expect(status.hitTestable(), findsOneWidget);
      expect(Focus.of(tester.element(status)).hasPrimaryFocus, isTrue);
    });

    testWidgets('pressing Import with the status in view leaves the page '
        'where it is', (tester) async {
      final start = Completer<GameImportReceipt>();
      remote.onStartImport = (_, _, _) => start.future;
      // A short summary, and a tall section under the import's: the status
      // arrives in view, part-way down it, with a long way left to scroll.
      final short = _wingspan.copyWith(summary: 'Attract birds.');
      await openQuickLook(
        tester,
        host(hit: short, mayChooseExpansions: false),
        hit: short,
        view: const Size(400, 500),
        below: const [SizedBox(height: 900)],
      );
      final position = bodyPosition(tester);
      expect(position.maxScrollExtent, greaterThan(400));
      position.jumpTo(30);
      await tester.pump();

      await tester.tap(importButton);
      await tester.pump();
      await tester.pump();

      final view = tester.getRect(body);
      final shown = tester.getRect(status);
      expect(shown.top, greaterThan(view.top + 40), reason: '$shown');
      expect(shown.bottom, lessThan(view.bottom), reason: '$shown');
      expect(position.pixels, 30);
      expect(Focus.of(tester.element(status)).hasPrimaryFocus, isTrue);
    });

    testWidgets('the scroll position survives the footer emptying', (
      tester,
    ) async {
      doubleText(tester);
      final start = Completer<GameImportReceipt>();
      remote.onStartImport = (_, _, _) => start.future;
      // Without the section, so that the footer is all that changes: with
      // it, the page moves to show the progress (see above).
      await openQuickLook(
        tester,
        host(mayChooseExpansions: false),
        view: const Size(320, 480),
        section: false,
      );
      final scrollable = tester.state<ScrollableState>(body);
      final position = scrollable.position;
      expect(position.maxScrollExtent, greaterThan(300));
      position.jumpTo(150);
      await tester.pump();
      final viewBefore = position.viewportDimension;
      final footerBefore = tester.getSize(footer).height;
      expect(footerBefore, greaterThan(0));

      await tester.tap(importButton);
      await tester.pump();
      await tester.pump();

      expect(importButton, findsNothing);
      expect(tester.getSize(footer).height, 0);
      // The same scroll view, where it was, taller by what the footer gave
      // back.
      expect(tester.state<ScrollableState>(body), same(scrollable));
      expect(position.pixels, 150);
      expect(
        position.viewportDimension,
        moreOrLessEquals(viewBefore + footerBefore),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a short view keeps the body scrollable under the footer', (
      tester,
    ) async {
      doubleText(tester);
      remote.onFetchExpansions = (_) async => _expansions(50);
      // 320 dp × 2.0 on its side: the height is what runs out.
      const view = Size(568, 320);
      await openQuickLook(tester, host(), view: view);
      expect(tester.takeException(), isNull);

      final layout = tester.getSize(find.byType(QuickLookLayout));
      final band = tester.getSize(footer);
      expect(band.height, greaterThan(0));
      expect(band.height, lessThanOrEqualTo(layout.height / 2));
      expect(band.height, lessThanOrEqualTo(view.height / 2));
      expect(
        tester.getSize(body).height,
        greaterThanOrEqualTo(layout.height / 2),
      );
      expect(bodyPosition(tester).maxScrollExtent, greaterThan(0));

      for (final target in [selectAll, lastOfFifty]) {
        await reveal(tester, target);
        expect(target.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(target).bottom,
          lessThanOrEqualTo(tester.getRect(footer).top),
        );
        expect(importButton.hitTestable(), findsOneWidget);
      }
      await tester.tap(lastOfFifty);
      await tester.pumpAndSettle();
      expect(label(tester), 'Import with 1 expansion');
      expect(tester.getRect(importButton).bottom, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    });

    testWidgets('offline the pinned Import is disabled and says why', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        final offline = ValueNotifier(true);
        addTearDown(offline.dispose);
        remote.onFetchExpansions = (_) async => _expansions(50);
        await openQuickLook(tester, host(), offline: offline);

        // Reading the expansions is not a write: they load offline.
        expect(remote.expansionTargets, hasLength(1));
        // Pinned still, disabled, not hidden, and it says why, in words and
        // to a screen reader.
        expect(
          find.ancestor(of: importButton, matching: footer),
          findsOneWidget,
        );
        expect(importButton.hitTestable(), findsOneWidget);
        expect(button(tester).onPressed, isNull);
        final note = find.descendant(
          of: footer,
          matching: find.text(onlineOnlyCopy),
        );
        expect(note.hitTestable(), findsOneWidget);
        expect(
          tester.getSemantics(importButton),
          isSemantics(
            label: 'Import',
            hint: onlineOnlyCopy,
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
          ),
        );
        // At the end of the checklist, both are still in view.
        await reveal(tester, lastOfFifty);
        expect(importButton.hitTestable(), findsOneWidget);
        expect(note.hitTestable(), findsOneWidget);
        expect(bodyPosition(tester).extentAfter, 0);

        // One tree online and offline: the button keeps its element as the
        // connection returns. The note goes, and the footer keeps the room
        // it leaves, so no row drops under a pointer.
        final element = tester.element(importButton);
        final pixels = bodyPosition(tester).pixels;
        final rows = tester.getRect(lastOfFifty);
        final withNote = tester.getSize(footer).height;
        offline.value = false;
        await tester.pumpAndSettle();
        expect(tester.element(importButton), same(element));
        expect(button(tester).onPressed, isNotNull);
        expect(find.text(onlineOnlyCopy), findsNothing);
        expect(bodyPosition(tester).pixels, pixels);
        expect(tester.getRect(lastOfFifty), rows);
        expect(tester.getSize(footer).height, withNote);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('at the end of the checklist, ticking the last expansion and '
        'then unticking it leaves the rows where they were', (tester) async {
      doubleText(tester);
      remote.onFetchExpansions = (_) async => _expansions(50);
      await openQuickLook(tester, host(), view: const Size(320, 640));
      final spaceSm = BgeTokens.of(
        tester.element(find.byType(GameImportPanel)),
      ).spaceSm;
      final position = bodyPosition(tester);
      Future<void> scrollToEnd() async {
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
      }

      await scrollToEnd();
      expect(label(tester), 'Import');
      final plain = tester.getSize(footer).height;
      var row = tester.getRect(lastOfFifty);

      // Ticked: the label with its count wraps, and the footer takes the
      // room for it from the foot of the view. No row moves.
      await tester.tap(lastOfFifty);
      await tester.pumpAndSettle();
      expect(label(tester), 'Import with 1 expansion');
      final counting = tester.getSize(footer).height;
      expect(counting, greaterThan(plain));
      expect(tester.getRect(lastOfFifty), row);

      // On to the new end, as the footer now covers the foot of the row.
      await scrollToEnd();
      row = tester.getRect(lastOfFifty);
      final pixels = position.pixels;

      // Unticked: the label is one line again. The footer keeps the room it
      // would give back, so the row under the pointer stays under it.
      await tester.tap(lastOfFifty);
      await tester.pumpAndSettle();
      expect(label(tester), 'Import');
      expect(position.pixels, pixels);
      expect(tester.getRect(lastOfFifty), row);
      expect(tester.getSize(footer).height, counting);
      // The button stays at the footer's foot, the room above it.
      expect(
        tester.getRect(importButton).bottom,
        moreOrLessEquals(tester.getRect(footer).bottom - spaceSm),
      );
      expect(importButton.hitTestable(), findsOneWidget);

      // The room goes back as the page leaves its end.
      position.jumpTo(pixels - 200);
      await tester.pumpAndSettle();
      expect(position.pixels, pixels - 200);
      expect(tester.getSize(footer).height, plain);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pressing Import at the end of the checklist leaves no room '
        'where the button was', (tester) async {
      doubleText(tester);
      remote.onFetchExpansions = (_) async => _expansions(50);
      final start = Completer<GameImportReceipt>();
      remote.onStartImport = (_, _, _) => start.future;
      await openQuickLook(tester, host(), view: const Size(320, 640));
      final position = bodyPosition(tester)
        ..jumpTo(bodyPosition(tester).maxScrollExtent);
      await tester.pumpAndSettle();
      expect(tester.getSize(footer).height, greaterThan(0));

      await tester.tap(importButton);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The body is redrawn around the progress, at its new end: there is
      // no row to hold still, so the emptied footer keeps nothing.
      expect(position.pixels, position.maxScrollExtent);
      expect(position.pixels, greaterThan(0));
      expect(tester.getSize(footer).height, 0);
      expect(
        tester.getSize(body).height,
        tester.getSize(find.byType(QuickLookLayout)).height,
      );
      expect(status.hitTestable(), findsOneWidget);
    });

    testWidgets('Tab reaches the pinned Import after the last expansion, and '
        'Shift+Tab goes back to it', (tester) async {
      remote.onFetchExpansions = (_) async => _expansions(12);
      await openQuickLook(tester, host(), view: const Size(400, 500));
      final lastRow = find.byKey(ExpansionChecklist.rowKey(_gateway, '32'));
      // The list runs on below the view, past where Import is pinned: by
      // where each is on screen, Import would come up part-way down it.
      expect(
        tester.getRect(lastRow).top,
        greaterThan(tester.getRect(importButton).bottom),
      );

      final import = Focus.of(
        tester.element(
          find.descendant(of: importButton, matching: find.byType(Text)),
        ),
      );
      final last = tester.widget<CheckboxListTile>(lastRow).focusNode!;
      final visited = <FocusNode>[];
      for (var i = 0; i < 40 && !import.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        visited.add(FocusManager.instance.primaryFocus!);
      }
      expect(import.hasPrimaryFocus, isTrue);
      // Select all, the twelve rows, then Import.
      expect(visited, hasLength(14));
      expect(visited[visited.length - 2], same(last));
      expect(importButton.hitTestable(), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(last.hasPrimaryFocus, isTrue);
      // Scrolled into view, clear of the footer.
      expect(lastRow.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(lastRow).bottom,
        lessThanOrEqualTo(tester.getRect(footer).top),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(import.hasPrimaryFocus, isTrue);
    });

    testWidgets('the section or the button without the host says what is '
        'missing', (tester) async {
      await tester.pumpWidget(
        catalogApp(const Scaffold(body: GameImportButton())),
      );
      expect(
        tester.takeException(),
        isA<FlutterError>().having(
          (error) => error.message,
          'message',
          contains('GameImportPanel'),
        ),
      );
    });
  });

  group("a held game's quick look keeps the host as the read answers", () {
    testWidgets('the ticked expansions and the import being followed outlive '
        'the answer', (tester) async {
      final read = Completer<GameWithPlatformGames>();
      remote
        ..onFetchGame = ((_) => read.future)
        ..onFetchExpansions = ((_) async => _expansions(3));
      queues();
      polls([_batch(ImportJobStatus.running)]);
      await openHeldQuickLook(tester, host(hit: held));
      await tester.pumpAndSettle();
      final panel = tester.state(find.byType(GameImportPanel));

      // Chosen while the seed shows.
      await tick(tester, '22');
      expect(label(tester), 'Re-import with 1 expansion');

      read.complete(wingspanRead());
      await tester.pumpAndSettle();
      expect(find.text('Tabletop'), findsOneWidget);
      expect(tester.state(find.byType(GameImportPanel)), same(panel));
      expect(label(tester), 'Re-import with 1 expansion');
      expect(remote.expansionTargets, hasLength(1));

      await pressImport(tester);
      expect(remote.importedExpansions, [
        ['22'],
      ]);
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 1);
      expect(find.byType(GameImportProgress), findsOneWidget);

      // Closed, so no poll outlives the test.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('an import pressed before the read answers is the one '
        'followed after it', (tester) async {
      final read = Completer<GameWithPlatformGames>();
      remote.onFetchGame = (_) => read.future;
      queues();
      polls([_batch(ImportJobStatus.running)]);
      await openHeldQuickLook(
        tester,
        host(hit: held, mayChooseExpansions: false),
      );
      await pressImport(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 1);
      final panel = tester.state(find.byType(GameImportPanel));

      read.complete(wingspanRead());
      await tester.pump();
      await tester.pump();

      expect(find.text('Tabletop'), findsOneWidget);
      expect(tester.state(find.byType(GameImportPanel)), same(panel));
      expect(find.byType(GameImportProgress), findsOneWidget);
      expect(importButton, findsNothing);
      // Still polled, and never started again.
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 2);
      expect(remote.importedExpansions, [<String>[]]);

      // Closed, so no poll outlives the test.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('a read refused after Import was pressed takes the progress '
        'away and throws nothing, and the import ends unseen', (
      tester,
    ) async {
      final read = Completer<GameWithPlatformGames>();
      remote.onFetchGame = (_) => read.future;
      queues();
      polls([
        _batch(ImportJobStatus.running),
        _batch(ImportJobStatus.running),
        _batch(ImportJobStatus.completed, gameId: 'g1'),
        _batch(ImportJobStatus.completed, gameId: 'g1'),
      ]);
      await openHeldQuickLook(
        tester,
        host(hit: held, mayChooseExpansions: false),
      );
      // Before the read answers, the import is offered (#1040 governs the
      // answer).
      await pressImport(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 1);
      expect(find.byType(GameImportProgress), findsOneWidget);
      final panel = tester.state(find.byType(GameImportPanel));

      read.completeError(const GamesForbiddenException('403'));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
      expect(find.byType(GameImportSection), findsNothing);
      expect(find.byType(GameImportProgress), findsNothing);
      expect(importButton, findsNothing);
      expect(tester.getSize(footer).height, 0);
      expect(tester.takeException(), isNull);
      // Focus, which was on the status, stays inside the pop-up.
      expect(
        FocusScope.of(tester.element(find.byType(GameQuickLook))).hasFocus,
        isTrue,
        reason: 'focus is on ${FocusManager.instance.primaryFocus}',
      );
      // The host stays, with the import it follows, which nothing draws.
      expect(tester.state(find.byType(GameImportPanel)), same(panel));
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 2);

      // It ends unseen: no page opens from a game the server refuses.
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 3);
      await tester.pump();
      expect(imported, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an import that completes in the frame the read is refused '
        'opens nothing', (tester) async {
      final read = Completer<GameWithPlatformGames>();
      remote.onFetchGame = (_) => read.future;
      queues();
      polls([
        _batch(ImportJobStatus.running),
        _batch(ImportJobStatus.completed, gameId: 'g1'),
        _batch(ImportJobStatus.completed, gameId: 'g1'),
      ]);
      await openHeldQuickLook(
        tester,
        host(hit: held, mayChooseExpansions: false),
      );
      await pressImport(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 1);
      expect(find.byType(GameImportProgress), findsOneWidget);

      // The refusal and the completing poll land before the quick look has
      // rebuilt without the progress.
      read.completeError(const GamesForbiddenException('403'));
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 2);
      expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
      expect(find.byType(GameImportProgress), findsNothing);
      await tester.pump();
      expect(imported, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing after such a refusal stops the import', (
      tester,
    ) async {
      final read = Completer<GameWithPlatformGames>();
      remote.onFetchGame = (_) => read.future;
      queues();
      polls([_batch(ImportJobStatus.running)]);
      await openHeldQuickLook(
        tester,
        host(hit: held, mayChooseExpansions: false),
      );
      await pressImport(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(fetches(), 1);
      read.completeError(const GamesForbiddenException('403'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(GameImportProgress), findsNothing);

      expect(await tester.binding.handlePopRoute(), isTrue);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 2));
      }

      expect(find.byType(GameQuickLook), findsNothing);
      expect(fetches(), 1);
      expect(imported, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('the Expansions heading sits a step below what precedes it, as '
      'Available on does', () {
    /// The space between [above]'s bottom and the top of the heading [text].
    double gapAbove(WidgetTester tester, Finder above, String text) =>
        tester.getRect(find.text(text)).top - tester.getRect(above).bottom;

    Future<void> expectStep(WidgetTester tester) async {
      final step = BgeTokens.of(
        tester.element(find.byType(GameImportPanel)),
      ).spaceMd;
      expect(find.text('Available on'), findsOneWidget);
      expect(
        gapAbove(tester, find.byType(GameDescription), 'Expansions'),
        step,
      );
      expect(
        gapAbove(
          tester,
          find.byKey(SearchHitQuickLook.factsKey),
          'Available on',
        ),
        step,
      );
    }

    testWidgets("in a search hit's quick look", (tester) async {
      remote.onFetchExpansions = (_) async => _expansions(2);
      final hit = _wingspan.copyWith(
        platforms: const [
          GameSearchPlatform(
            name: 'Tabletop',
            platformType: PlatformType.tabletop,
          ),
        ],
      );
      await openQuickLook(tester, host(hit: hit), hit: hit);

      await expectStep(tester);
    });

    testWidgets("in a held game's quick look", (tester) async {
      remote
        ..onFetchExpansions = ((_) async => _expansions(2))
        ..onFetchGame = ((_) async => wingspanRead());
      await openHeldQuickLook(tester, host(hit: held));
      await tester.pumpAndSettle();

      await expectStep(tester);
    });
  });

  group('accessibility audit', () {
    auditScreen(
      'two expansions, one ticked',
      build: (theme) {
        remote.onFetchExpansions = (_) async => _expansions(2);
        return catalogApp(opener(host()), theme: theme);
      },
      arrange: (tester) async {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tick(tester, '21');
        expect(label(tester), 'Import with 1 expansion');
      },
    );
  });
}
