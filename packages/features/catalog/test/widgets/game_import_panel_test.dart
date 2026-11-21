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
import 'package:game_catalog/src/widgets/folded_description.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

const _gateway = 'bgg';

/// Many lines of one paragraph at any width these tests use, so the quick
/// look's description folds and offers More: a control above the panel
/// that keeps focus history of its own.
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

  GameImportPanel panel({
    GameSearchHit? hit,
    bool mayChooseExpansions = true,
    DataGatewaySearchGrant? grant,
    void Function(BuildContext context, String gameId)? onImported,
  }) => GameImportPanel(
    remote: remote,
    gatewayId: _gateway,
    hit: hit ?? _wingspan,
    mayChooseExpansions: mayChooseExpansions,
    grant: grant,
    sourceNames: const {_gateway: 'BoardGameGeek'},
    onImported: onImported ?? (_, gameId) => imported.add(gameId),
  );

  /// [panel] in a scroll view, as a quick look's section sits in its own.
  Widget inPage(Widget panel, {ValueListenable<bool>? offline}) => catalogApp(
    Scaffold(body: SingleChildScrollView(child: panel)),
    offline: offline,
  );

  /// A page whose button opens [hit]'s quick look, with [panel] as its
  /// section, as the search will.
  Widget opener(Widget panel, {GameSearchHit? hit}) => Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => TextButton(
          onPressed: () => unawaited(
            showSearchHitQuickLook(
              context,
              hit: hit ?? _wingspan,
              sourceName: 'BoardGameGeek',
              sections: [panel],
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
    Widget panel, {
    GameSearchHit? hit,
    Size view = const Size(400, 800),
  }) async {
    useViewSize(tester, view);
    await tester.pumpWidget(catalogApp(opener(panel, hit: hit)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  }

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
    await tester.pumpWidget(inPage(panel(mayChooseExpansions: false)));
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
    await tester.pumpWidget(inPage(panel()));
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
      inPage(panel(hit: _wingspan.copyWith(gameId: 'g_wingspan'))),
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
    await tester.pumpWidget(inPage(panel()));
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
    await tester.pumpWidget(inPage(panel()));
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
    await tester.pumpWidget(inPage(panel(grant: grant)));
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
      await openQuickLook(tester, panel());
      // A control above the panel that focus history can fall back to.
      expect(find.byKey(FoldedDescription.toggleKey), findsOneWidget);

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
      // On the way it passed the description's More and the checklist.
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
      await openQuickLook(tester, panel());
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
    await openQuickLook(tester, panel());
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
      MaterialPage<void>(key: const ValueKey('search'), child: opener(panel())),
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
    await openQuickLook(tester, panel(mayChooseExpansions: false));
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
    await openQuickLook(tester, panel(mayChooseExpansions: false));
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
      panel(
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
    await tester.pumpWidget(inPage(panel(), offline: offline));
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

  testWidgets('no overflow at 320 dp × 2.0 with 50 expansions', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    remote.onFetchExpansions = (_) async => _expansions(50);
    await openQuickLook(
      tester,
      panel(hit: _wingspan.copyWith(gameId: 'g_wingspan')),
      view: const Size(320, 640),
    );
    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byType(GameImportPanel)),
      ).scale(10),
      20,
    );
    expect(tester.takeException(), isNull);

    final scrollable = find
        .descendant(
          of: find.byType(SearchHitQuickLook),
          matching: find.byType(Scrollable),
        )
        .first;
    final selectAll = find.byKey(ExpansionChecklist.selectAllKey(_gateway));
    await tester.scrollUntilVisible(selectAll, 200, scrollable: scrollable);
    await tester.ensureVisible(selectAll);
    await tester.pumpAndSettle();
    expect(selectAll.hitTestable(), findsOneWidget);
    await tester.tap(selectAll);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(importButton, 400, scrollable: scrollable);
    await tester.ensureVisible(importButton);
    await tester.pumpAndSettle();
    expect(label(tester), 'Re-import with 50 expansions');
    expect(importButton.hitTestable(), findsOneWidget);
    final shown = tester.getRect(importButton);
    expect(shown.left, greaterThanOrEqualTo(0), reason: '$shown');
    expect(shown.right, lessThanOrEqualTo(320), reason: '$shown');
    expect(shown.bottom, lessThanOrEqualTo(640), reason: '$shown');
    expect(tester.takeException(), isNull);
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
        gapAbove(tester, find.byType(FoldedDescription), 'Expansions'),
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
      await openQuickLook(tester, panel(hit: hit), hit: hit);

      await expectStep(tester);
    });

    testWidgets("in a held game's quick look", (tester) async {
      remote
        ..onFetchExpansions = ((_) async => _expansions(2))
        ..onFetchGame = (_) async => (
          game: game('g_wingspan', title: 'Wingspan').copyWith(
            minPlayers: 1,
            maxPlayers: 5,
            description: _long,
          ),
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
      useViewSize(tester, const Size(400, 800));
      final held = _wingspan.copyWith(gameId: 'g_wingspan');
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
                      sections: [panel(hit: held)],
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
      await tester.pumpAndSettle();
      expect(find.byType(GameQuickLook), findsOneWidget);

      await expectStep(tester);
    });
  });

  group('accessibility audit', () {
    auditScreen(
      'two expansions, one ticked',
      build: (theme) {
        remote.onFetchExpansions = (_) async => _expansions(2);
        return catalogApp(opener(panel()), theme: theme);
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
