import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

import '../support/catalog_app.dart';
import '../support/fake_game_search_channel.dart';
import '../support/fake_games_remote.dart';

void main() {
  late FakeGamesRemote remote;

  setUp(() => remote = FakeGamesRemote());

  final results = GameSearchResults(
    local: [hit('g_catan', gameId: 'g_catan', title: 'Catan')],
    byDataGateway: {
      'dg_bgg': [
        // Already on the server: the section above lists it.
        hit('13', gameId: 'g_catan', title: 'Catan'),
        hit('926', title: 'Catan: Seafarers'),
        hit('1', gameId: 'g_imported', title: 'Catan Junior'),
      ],
    },
    unavailableDataGateways: const {'dg_down'},
  );

  Future<void> show(
    WidgetTester tester, {
    FakeGamesCache? cache,
    Future<Map<String, String>> Function()? sourceNames,
    Stream<String>? gone,
    void Function(BuildContext context, String gameId)? onOpen,
    CallerAccessRepository? access,
    void Function(String gameId)? onGone,
    ValueListenable<bool>? offline,
    ThemeData? theme,
    DataGatewaySearchGrant? grant,
    GameSearchStreamSource? streamSource,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        theme: theme,
        GameSearchScreen(
          remote: remote,
          streamSource: streamSource,
          grant: grant,
          cache: cache,
          sourceNames: sourceNames,
          gone: gone,
          onOpen: onOpen,
          access: access,
          onGone: onGone,
        ),
        offline: offline,
      ),
    );
    await tester.pump();
  }

  /// A session that may import games: `create` on `Game` (#713).
  FakeCallerAccessRepository mayImport() => FakeCallerAccessRepository(
    const CallerAccess.known({
      ResourceType.game: ResourceAccess(
        create: AccessExtent.all,
        read: AccessExtent.all,
        update: AccessExtent.none,
        delete: AccessExtent.none,
        manage: AccessExtent.none,
      ),
    }),
  );

  /// Every detail read answers [game], with no platforms.
  void readsAs(Game game) =>
      remote.onFetchGame = (_) async =>
          (game: game, platformGames: const <PlatformGame>[]);

  /// Taps [row] and waits for its quick look to open.
  Future<void> openQuickLook(WidgetTester tester, Finder row) async {
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  final importButton = find.byKey(GameImportPanel.importKey);

  /// The import button's label.
  String? importLabel(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(of: importButton, matching: find.byType(Text)),
      )
      .data;

  /// Types [text] and waits out the debounce and the answer.
  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(GameSearchScreen.fieldKey), text);
    await tester.pump(GameSearchBloc.defaultDebounce);
    await tester.pumpAndSettle();
  }

  /// Opens the filter sheet and waits for it to finish opening.
  Future<void> openFilters(WidgetTester tester) async {
    await tester.tap(find.byKey(GameSearchScreen.filtersButtonKey));
    await tester.pumpAndSettle();
  }

  /// Closes the filter sheet by tapping the barrier above it.
  Future<void> closeFilters(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  /// The Filters button's label.
  String? filtersButtonLabel(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(GameSearchScreen.filtersButtonKey),
          matching: find.byType(Text),
        ),
      )
      .data;

  /// The open filter sheet's own scrollable.
  Finder sheetScrollable() => find
      .descendant(
        of: find.byKey(GameSearchScreen.filterSheetKey),
        matching: find.byType(Scrollable),
      )
      .first;

  /// Scrolls the open filter sheet until [finder] is in view. A widget below
  /// the fold can already be built, in the list's cache, so it is then
  /// brought fully on screen.
  Future<Finder> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 100, scrollable: sheetScrollable());
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    return finder;
  }

  /// Types [text] into [range]'s [end] field in the open filter sheet, and
  /// submits it.
  Future<void> enterBound(
    WidgetTester tester,
    String range,
    String end,
    String text,
  ) async {
    final field = await reveal(
      tester,
      find.byKey(GameSearchScreen.rangeFieldKey(range, end)),
    );
    await tester.enterText(field, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  /// The label of the chip under the field for the filter in use [id].
  String? inUseLabel(WidgetTester tester, String id) => tester
      .widget<Text>(
        find
            .descendant(
              of: find.byKey(GameSearchScreen.inUseKey(id)),
              matching: find.byType(Text),
            )
            .first,
      )
      .data;

  /// Narrows the search to [filter] through the screen's bloc, as its
  /// controls do, and waits for the answer.
  Future<void> narrow(WidgetTester tester, GameSearchFilter filter) async {
    tester
        .element(find.byKey(GameSearchScreen.fieldKey))
        .read<GameSearchBloc>()
        .add(GameSearchFilterChanged(filter));
    await tester.pumpAndSettle();
  }

  testWidgets('before anything is typed, says what it searches', (
    tester,
  ) async {
    await show(tester);

    expect(find.byKey(GameSearchScreen.idleKey), findsOneWidget);
  });

  testWidgets('search idle is announced', (tester) async {
    final handle = tester.ensureSemantics();
    await show(tester);

    final message = tester.getSemantics(
      find.text('Search this server and its data sources for a game.'),
    );
    expect(message, isSemantics(isLiveRegion: true));
    expect(
      message.label,
      contains('Search this server and its data sources for a game.'),
    );
    handle.dispose();
  });

  testWidgets('search no-results is announced', (tester) async {
    final handle = tester.ensureSemantics();
    remote.onSearch = (_, _, _) async => const GameSearchResults();
    await show(tester);
    await search(tester, 'zzz');

    final message = tester.getSemantics(find.text('No games match “zzz”.'));
    expect(message, isSemantics(isLiveRegion: true));
    expect(message.label, contains('No games match “zzz”.'));
    handle.dispose();
  });

  testWidgets('shows this server first, then what data sources found', (
    tester,
  ) async {
    remote.onSearch = (_, _, _) async => results;

    await show(tester);
    await search(tester, 'catan');

    expect(find.text('On this server'), findsOneWidget);
    expect(find.text('From data sources'), findsOneWidget);
    expect(
      find.byKey(GameSearchScreen.serverRowKey('g_catan')),
      findsOneWidget,
    );
    expect(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
      findsOneWidget,
    );
    // The DataGateway's copy of the game the server lists is not shown twice.
    expect(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '13')),
      findsNothing,
    );
    expect(find.text('3 results'), findsOneWidget);
  });

  testWidgets('every game row is outlined (#647)', (tester) async {
    remote.onSearch = (_, _, _) async => results;

    await show(tester);
    await search(tester, 'catan');

    // One server row and two data-source rows: the third hit is the server's
    // game again, listed once above.
    expect(find.byType(BgeOutlinedRow), findsNWidgets(3));
    for (final row in [
      GameSearchScreen.serverRowKey('g_catan'),
      GameSearchScreen.sourceRowKey('dg_bgg', '926'),
      GameSearchScreen.sourceRowKey('dg_bgg', '1'),
    ]) {
      expect(
        find.descendant(
          of: find.byKey(row),
          matching: find.byType(BgeOutlinedRow),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('a DataGateway row shows its summary as plain text', (
    tester,
  ) async {
    remote.onSearch = (_, _, _) async => const GameSearchResults(
      byDataGateway: {
        'dg_bgg': [
          GameSearchHit(
            externalId: '926',
            title: 'Catan: Seafarers',
            contentType: ContentType.expansion,
            summary: '**Settle** the _seas_.\n\n- ships',
          ),
        ],
      },
    );

    await show(tester);
    await search(tester, 'catan');

    expect(find.text('Settle the seas. ships'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets("this server's rows show no summary line", (tester) async {
    remote.onSearch = (_, _, _) async => results;

    await show(tester);
    await search(tester, 'catan');

    final row = find.byKey(GameSearchScreen.serverRowKey('g_catan'));
    final lines = find.descendant(of: row, matching: find.byType(Text));
    // Title and facts only: no summary.
    expect(
      tester.widgetList<Text>(lines).where((t) => t.maxLines == 1),
      isEmpty,
    );
  });

  testWidgets('announces the result count when results arrive', (tester) async {
    final handle = tester.ensureSemantics();
    remote.onSearch = (_, _, _) async => results;

    await show(tester);
    await search(tester, 'catan');

    expect(
      tester.getSemantics(find.byKey(GameSearchScreen.countKey)),
      isSemantics(label: '3 results', isLiveRegion: true),
    );
    handle.dispose();
  });

  testWidgets('counts the result rows, not the headings, for a screen '
      'reader', (tester) async {
    remote.onSearch = (_, _, _) async => results;

    await show(tester);
    await search(tester, 'catan');

    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollView.semanticChildCount, 3);
  });

  testWidgets('a game found gone is taken down', (tester) async {
    remote.onSearch = (_, _, _) async => results;
    final gone = StreamController<String>.broadcast();
    addTearDown(gone.close);

    await show(tester, gone: gone.stream);
    await search(tester, 'catan');
    gone.add('g_catan');
    await tester.pumpAndSettle();

    expect(find.byKey(GameSearchScreen.serverRowKey('g_catan')), findsNothing);
    expect(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '1')),
      findsOneWidget,
    );
  });

  group('a result opens its quick look (#713)', () {
    Finder serverRow(String gameId) =>
        find.byKey(GameSearchScreen.serverRowKey(gameId));
    Finder sourceRow(String externalId) =>
        find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', externalId));

    /// Closes the open quick look, as Escape does.
    Future<void> closeQuickLook(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }

    Future<void> pressViewDetails(WidgetTester tester) async {
      final button = find.byKey(GameQuickLook.viewDetailsKey);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
    }

    testWidgets('a DataGateway result opens its quick look, not an import', (
      tester,
    ) async {
      remote.onSearch = (_, _, _) async => results;
      await show(
        tester,
        sourceNames: () async => {'dg_bgg': 'BoardGameGeek'},
        access: mayImport(),
        onOpen: (_, _) {},
      );
      await search(tester, 'catan');
      await openQuickLook(tester, sourceRow('926'));

      expect(find.byType(SearchHitQuickLook), findsOneWidget);
      expect(remote.calls, isNot(contains(startsWith('startImport'))));
      // Import waits in the quick look, with the hit's expansions read from
      // the DataGateway it came from, which the checklist names.
      expect(importLabel(tester), 'Import');
      final panel = tester.widget<GameImportPanel>(
        find.byType(GameImportPanel),
      );
      expect(panel.gatewayId, 'dg_bgg');
      expect(panel.hit.externalId, '926');
      expect(panel.sourceNames, {'dg_bgg': 'BoardGameGeek'});
      expect(remote.expansionTargets, [
        const GameExpansionsTarget.dataGateway(
          gatewayId: 'dg_bgg',
          externalId: '926',
        ),
      ]);
    });

    testWidgets("a local result opens the game's quick look", (tester) async {
      remote.onSearch = (_, _, _) async => results;
      readsAs(game('g_catan', title: 'Catan'));
      final opened = <String>[];

      await show(
        tester,
        access: mayImport(),
        onOpen: (_, gameId) => opened.add(gameId),
      );
      await search(tester, 'catan');
      await openQuickLook(tester, serverRow('g_catan'));

      expect(find.byType(GameQuickLook), findsOneWidget);
      expect(remote.calls, contains('fetchGame(g_catan)'));
      // This server's own result came from no DataGateway to import from.
      expect(find.byType(GameImportPanel), findsNothing);

      await pressViewDetails(tester);
      expect(opened, ['g_catan']);
    });

    testWidgets('a DataGateway result on the server offers Re-import', (
      tester,
    ) async {
      remote.onSearch = (_, _, _) async => results;
      readsAs(game('g_imported', title: 'Catan Junior'));
      final opened = <String>[];

      await show(
        tester,
        access: mayImport(),
        onOpen: (_, gameId) => opened.add(gameId),
      );
      await search(tester, 'catan');
      await openQuickLook(tester, sourceRow('1'));

      // The ordinary quick look, read by the game's id on this server.
      expect(find.byType(GameQuickLook), findsOneWidget);
      expect(find.byType(SearchHitQuickLook), findsNothing);
      expect(remote.calls, contains('fetchGame(g_imported)'));
      expect(importLabel(tester), 'Re-import');
      expect(remote.expansionTargets, [
        const GameExpansionsTarget.dataGateway(
          gatewayId: 'dg_bgg',
          externalId: '1',
        ),
      ]);
      // The DataGateway's name was never read, so the checklist has none.
      expect(
        tester
            .widget<GameImportPanel>(find.byType(GameImportPanel))
            .sourceNames,
        isEmpty,
      );

      await pressViewDetails(tester);
      expect(opened, ['g_imported']);
    });

    testWidgets('without create on Game there is no Import', (tester) async {
      remote.onSearch = (_, _, _) async => results;
      readsAs(game('g_imported', title: 'Catan Junior'));

      // Known, and allowing nothing.
      await show(
        tester,
        access: FakeCallerAccessRepository(const CallerAccess.known({})),
        onOpen: (_, _) {},
      );
      await search(tester, 'catan');

      await openQuickLook(tester, sourceRow('926'));
      expect(find.byType(SearchHitQuickLook), findsOneWidget);
      expect(find.byType(GameImportPanel), findsNothing);
      await closeQuickLook(tester);

      await openQuickLook(tester, sourceRow('1'));
      expect(find.byType(GameQuickLook), findsOneWidget);
      expect(find.byType(GameImportPanel), findsNothing);
      // Information only: nothing is read for an import that can't happen.
      expect(remote.expansionTargets, isEmpty);
    });

    testWidgets('with no access to ask, there is no Import either', (
      tester,
    ) async {
      remote.onSearch = (_, _, _) async => results;

      await show(tester, onOpen: (_, _) {});
      await search(tester, 'catan');
      await openQuickLook(tester, sourceRow('926'));

      expect(find.byType(SearchHitQuickLook), findsOneWidget);
      expect(find.byType(GameImportPanel), findsNothing);
    });

    testWidgets('access is read as the quick look opens', (tester) async {
      remote.onSearch = (_, _, _) async => results;
      // No answer yet when the screen is built.
      final access = FakeCallerAccessRepository();

      await show(tester, access: access, onOpen: (_, _) {});
      await search(tester, 'catan');
      access.current = mayImport().current;
      await openQuickLook(tester, sourceRow('926'));

      expect(importButton, findsOneWidget);
    });

    // A signed-out grant shows no DataGateway rows to open at all (#795), so
    // the session's grant is refused after the rows have shown, as another
    // quick look's expansions read can refuse it.
    testWidgets('a grant that may not ask loads no expansions', (tester) async {
      remote.onSearch = (_, _, _) async => results;
      final grant = DataGatewaySearchGrant();

      await show(tester, grant: grant, access: mayImport(), onOpen: (_, _) {});
      await search(tester, 'catan');
      grant.refuse(null);
      await openQuickLook(tester, sourceRow('926'));

      // Import takes the game alone.
      expect(importLabel(tester), 'Import');
      expect(
        tester
            .widget<GameImportPanel>(find.byType(GameImportPanel))
            .mayChooseExpansions,
        isFalse,
      );
      expect(remote.expansionTargets, isEmpty);
    });

    testWidgets("the import shares the screen's grant: an expansions read "
        'refused leaves the DataGateways out of the next search', (
      tester,
    ) async {
      remote
        ..onSearch = ((_, _, _) async => results)
        ..onFetchExpansions = ((_) async => throw const GamesForbiddenException(
          '403',
          apiMessage: 'Not for you',
        ));

      // No grant given: the screen remembers for itself.
      await show(tester, access: mayImport(), onOpen: (_, _) {});
      await search(tester, 'catan');
      await openQuickLook(tester, sourceRow('926'));
      await closeQuickLook(tester);
      await search(tester, 'catan seafarers');

      expect(remote.calls, contains('search(catan seafarers -external)'));
      expect(
        find.byKey(GameSearchScreen.dataGatewaysRefusedKey),
        findsOneWidget,
      );
    });

    testWidgets('a row opens its quick look offline', (tester) async {
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      remote.onSearch = (_, _, _) async => results;
      readsAs(game('g_catan', title: 'Catan'));

      await show(
        tester,
        offline: offline,
        access: mayImport(),
        onOpen: (_, _) {},
      );
      await search(tester, 'catan');

      // Opening one is a read: no row waits for the connection.
      expect(find.text(onlineOnlyCopy), findsNothing);
      await openQuickLook(tester, sourceRow('926'));
      expect(find.byType(SearchHitQuickLook), findsOneWidget);
      // The import is a write, so its button does.
      expect(tester.widget<FilledButton>(importButton).onPressed, isNull);
      expect(find.text(onlineOnlyCopy), findsOneWidget);
      await closeQuickLook(tester);

      await openQuickLook(tester, serverRow('g_catan'));
      expect(find.byType(GameQuickLook), findsOneWidget);
    });

    testWidgets('an import that ends opens the game through onOpen, from the '
        "quick look's context", (tester) async {
      const imported = ImportBatch(
        batchId: 'b1',
        correlationId: 'c1',
        status: ImportBatchStatus.completed,
        jobs: [
          ImportJob(
            jobId: 'j1',
            status: ImportJobStatus.completed,
            origin: ImportJobOrigin.requested,
            externalId: '926',
            gameId: 'g_seafarers',
          ),
        ],
      );
      // The first poll finds the game imported.
      remote
        ..onSearch = ((_, _, _) async => results)
        ..onStartImport = ((_, _, correlationId) async => GameImportReceipt(
          batchId: 'b1',
          baseJobId: 'j1',
          correlationId: correlationId,
        ))
        ..onFetchImport = ((_) async => imported);
      final opened = <String>[];
      BuildContext? openedFrom;

      await show(
        tester,
        access: mayImport(),
        onOpen: (context, gameId) {
          openedFrom = context;
          opened.add(gameId);
        },
      );
      await search(tester, 'catan');
      await openQuickLook(tester, sourceRow('926'));
      await tester.ensureVisible(importButton);
      await tester.pumpAndSettle();
      await tester.tap(importButton);
      await tester.pump();
      // The first poll waits its interval; the progress's spinner never
      // settles.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(opened, ['g_seafarers']);
      expect(openedFrom?.mounted, isTrue);
      expect(
        openedFrom?.findAncestorWidgetOfExactType<SearchHitQuickLook>(),
        isNotNull,
      );
    });

    testWidgets("with no onOpen, a local result's quick look offers no View "
        'full details', (tester) async {
      remote.onSearch = (_, _, _) async => results;
      readsAs(game('g_catan', title: 'Catan'));

      await show(tester);
      await search(tester, 'catan');
      await openQuickLook(tester, serverRow('g_catan'));

      expect(find.byType(GameQuickLook), findsOneWidget);
      expect(find.byKey(GameQuickLook.viewDetailsKey), findsNothing);
    });

    for (final (name, onOpen)
        in <(String, void Function(BuildContext, String)?)>[
          ('without onOpen', null),
          ('with onOpen', (_, _) {}),
        ]) {
      testWidgets('every row is a control, $name', (tester) async {
        final handle = tester.ensureSemantics();
        remote.onSearch = (_, _, _) async => results;

        await show(tester, onOpen: onOpen);
        await search(tester, 'catan');

        for (final row in [serverRow('g_catan'), sourceRow('926')]) {
          expect(
            tester.getSemantics(
              find.descendant(of: row, matching: find.byType(MergeSemantics)),
            ),
            isSemantics(hasTapAction: true, isFocusable: true),
          );
        }
        handle.dispose();
      });
    }

    testWidgets('a game its quick look finds gone is told to onGone', (
      tester,
    ) async {
      remote
        ..onSearch = ((_, _, _) async => results)
        ..onFetchGame = ((_) async => throw const GameNotFoundException('404'));
      final found = <String>[];

      await show(tester, onGone: found.add);
      await search(tester, 'catan');
      await openQuickLook(tester, serverRow('g_catan'));

      expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
      expect(found, ['g_catan']);
    });
  });

  group('the data sources that did not answer', () {
    testWidgets('are counted where they cannot be named', (tester) async {
      remote.onSearch = (_, _, _) async => results;

      await show(tester);
      await search(tester, 'catan');

      expect(
        find.text(
          "A data source didn't answer, so some results may be missing.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('are named where they can be, as are the results', (
      tester,
    ) async {
      remote.onSearch = (_, _, _) async => results;

      await show(
        tester,
        sourceNames: () async => {
          'dg_bgg': 'BoardGameGeek',
          'dg_down': 'Steam',
        },
      );
      await search(tester, 'catan');
      expect(find.text('BoardGameGeek'), findsNWidgets(2));

      // Named rows are two lines tall, which puts the note below the fold.
      await tester.scrollUntilVisible(
        find.byKey(GameSearchScreen.missingSourcesKey),
        100,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );

      expect(
        find.text('No answer from Steam, so some results may be missing.'),
        findsOneWidget,
      );
    });
  });

  group('the data sources a filter skipped', () {
    const fourPlayers = GameSearchFilter(playerCount: GameSearchRange(min: 4));

    testWidgets('get a note naming the filter and the way back', (
      tester,
    ) async {
      remote.onSearch = (_, filter, _) async => GameSearchResults(
        unfilterableDataGateways: {if (filter.playerCount.narrows) 'dg_bgg'},
      );

      await show(tester, sourceNames: () async => {'dg_bgg': 'BoardGameGeek'});
      await search(tester, 'catan');
      expect(find.byKey(GameSearchScreen.unfilterableNoteKey), findsNothing);

      await narrow(tester, fourPlayers);

      expect(
        tester
            .widget<Text>(find.byKey(GameSearchScreen.unfilterableNoteKey))
            .data,
        "BoardGameGeek can't filter by player count, so its games aren't "
        'shown. Include games with no player count to see them.',
      );
    });

    testWidgets('are counted where they cannot be named', (tester) async {
      remote.onSearch = (_, _, _) async => const GameSearchResults(
        unfilterableDataGateways: {'dg_bgg', 'dg_igdb'},
      );

      await show(tester);
      await search(tester, 'catan');
      await narrow(tester, fourPlayers);

      expect(
        tester
            .widget<Text>(find.byKey(GameSearchScreen.unfilterableNoteKey))
            .data,
        "2 data sources can't filter by player count, so their games aren't "
        'shown. Include games with no player count to see them.',
      );
    });
  });

  group('the range controls', () {
    setUp(() => remote.onSearch = (_, _, _) async => const GameSearchResults());

    /// Shows the screen with "catan" searched for and the filter sheet open.
    Future<void> showSheet(WidgetTester tester) async {
      await show(tester);
      await search(tester, 'catan');
      await openFilters(tester);
    }

    const rangeErrors = [
      "From can't be after To",
      'Must be at least 1',
      'Too large',
    ];

    testWidgets('a year range searches once it is committed', (tester) async {
      await showSheet(tester);
      final before = remote.calls.length;

      await enterBound(tester, 'year', 'from', '-3000');
      await enterBound(tester, 'year', 'to', '500');

      expect(remote.calls, hasLength(before + 2));
      expect(remote.calls.last, 'search(catan year(-3000..500))');
      expect(inUseLabel(tester, 'year'), '3000 BCE–500');
    });

    testWidgets('a reversed range shows the error and sends nothing, until '
        'it is fixed', (tester) async {
      await showSheet(tester);
      await enterBound(tester, 'year', 'from', '2000');
      expect(remote.calls.last, 'search(catan year(2000..))');
      final before = remote.calls.length;

      await enterBound(tester, 'year', 'to', '1990');

      expect(remote.calls, hasLength(before));
      expect(find.text("From can't be after To"), findsOneWidget);

      await enterBound(tester, 'year', 'to', '2010');

      expect(remote.calls, hasLength(before + 1));
      expect(remote.calls.last, 'search(catan year(2000..2010))');
      expect(find.text("From can't be after To"), findsNothing);
    });

    testWidgets('a bound typed and not submitted is committed when the '
        'sheet closes', (tester) async {
      await showSheet(tester);
      final field = await reveal(
        tester,
        find.byKey(GameSearchScreen.rangeFieldKey('year', 'from')),
      );
      await tester.enterText(field, '1990');
      await tester.pump();

      await closeFilters(tester);

      expect(remote.calls.last, 'search(catan year(1990..))');
      expect(inUseLabel(tester, 'year'), 'From 1990');
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets("a range that can't be sent says so when the sheet closes", (
      tester,
    ) async {
      await showSheet(tester);
      final before = remote.calls.length;
      final field = await reveal(
        tester,
        find.byKey(GameSearchScreen.rangeFieldKey('players', 'from')),
      );
      await tester.enterText(field, '0');
      await tester.pump();

      await closeFilters(tester);

      expect(remote.calls, hasLength(before));
      expect(find.byKey(GameSearchScreen.inUseKey('players')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Player count not applied. Must be at least 1.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('ranges dropped as the sheet closes are said in one bar', (
      tester,
    ) async {
      // Each would replace the last in a bar of its own (#343).
      await showSheet(tester);
      await enterBound(tester, 'year', 'from', '2000');
      await enterBound(tester, 'year', 'to', '1990');
      final players = await reveal(
        tester,
        find.byKey(GameSearchScreen.rangeFieldKey('players', 'from')),
      );
      await tester.enterText(players, '0');
      await tester.pump();

      await closeFilters(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(
            "Publish year not applied. From can't be after To.\n"
            'Player count not applied. Must be at least 1.',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets("a range's typing and its error outlive scrolling it out of "
        'view', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await showSheet(tester);
      await enterBound(tester, 'year', 'from', '2000');
      await enterBound(tester, 'year', 'to', '1990');
      expect(find.text("From can't be after To"), findsOneWidget);

      await tester.drag(sheetScrollable(), const Offset(0, -5000));
      await tester.pumpAndSettle();
      await tester.drag(sheetScrollable(), const Offset(0, 5000));
      await tester.pumpAndSettle();

      final to = await reveal(
        tester,
        find.byKey(GameSearchScreen.rangeFieldKey('year', 'to')),
      );
      expect(tester.widget<TextField>(to).controller!.text, '1990');
      expect(find.text("From can't be after To"), findsOneWidget);
    });

    testWidgets('the keyboard leaves the field being typed in on screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      await showSheet(tester);

      final field = await reveal(
        tester,
        find.byKey(GameSearchScreen.rangeFieldKey('time', 'to')),
      );
      await tester.showKeyboard(field);
      await tester.pumpAndSettle();

      expect(tester.getRect(field).bottom, lessThanOrEqualTo(640 - 300));
    });

    testWidgets('clear all drops a bound typed and not yet sent', (
      tester,
    ) async {
      await showSheet(tester);
      await tester.tap(
        find.byKey(GameSearchScreen.filterKey(ContentType.expansion)),
      );
      await tester.pumpAndSettle();
      final from = await reveal(
        tester,
        find.byKey(GameSearchScreen.rangeFieldKey('year', 'from')),
      );
      await tester.enterText(from, '1990');
      await tester.pump();

      await tester.tap(
        await reveal(tester, find.byKey(GameSearchScreen.clearAllKey)),
      );
      await tester.pumpAndSettle();
      await closeFilters(tester);

      expect(remote.calls.last, 'search(catan)');
      expect(find.byKey(GameSearchScreen.inUseKey('year')), findsNothing);
      await openFilters(tester);
      expect(
        tester
            .widget<TextField>(
              await reveal(
                tester,
                find.byKey(GameSearchScreen.rangeFieldKey('year', 'from')),
              ),
            )
            .controller!
            .text,
        isEmpty,
      );
    });

    testWidgets('the range fields take numbers, not prose', (tester) async {
      await showSheet(tester);

      for (final range in ['year', 'players', 'time']) {
        for (final end in ['from', 'to']) {
          final field = tester.widget<TextField>(
            find.byKey(GameSearchScreen.rangeFieldKey(range, end)),
          );
          expect(field.autocorrect, isFalse, reason: '$range $end');
          expect(field.enableSuggestions, isFalse, reason: '$range $end');
        }
      }
    });

    testWidgets("a range's error is announced as it appears", (tester) async {
      final handle = tester.ensureSemantics();
      await showSheet(tester);
      await enterBound(tester, 'year', 'from', '2000');

      await enterBound(tester, 'year', 'to', '1990');

      final announcer = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            (widget.properties.liveRegion ?? false) &&
            widget.properties.label == "From can't be after To",
      );
      expect(announcer, findsOneWidget);
      expect(
        tester.getSemantics(announcer),
        isSemantics(label: "From can't be after To", isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('a lone minus sign is no bound', (tester) async {
      await showSheet(tester);
      final before = remote.calls.length;

      await enterBound(tester, 'year', 'from', '-');

      expect(remote.calls, hasLength(before));
      for (final error in rangeErrors) {
        expect(find.text(error), findsNothing);
      }
    });

    testWidgets('one player count is an exact count', (tester) async {
      await showSheet(tester);

      await enterBound(tester, 'players', 'from', '4');

      expect(remote.calls.last, 'search(catan players(4..))');
      expect(inUseLabel(tester, 'players'), '4 players');
    });

    testWidgets('a player count below 1 is refused', (tester) async {
      await showSheet(tester);
      final before = remote.calls.length;

      await enterBound(tester, 'players', 'from', '0');

      expect(find.text('Must be at least 1'), findsOneWidget);
      expect(remote.calls, hasLength(before));
    });

    testWidgets('a band sends its minutes, and Marathon sends only a '
        'minimum', (tester) async {
      await showSheet(tester);

      await tester.tap(
        await reveal(
          tester,
          find.byKey(GameSearchScreen.bandKey(GameLengthBand.medium)),
        ),
      );
      await tester.pumpAndSettle();

      expect(remote.calls.last, 'search(catan time(60..120))');
      expect(inUseLabel(tester, 'time'), 'Medium');

      await tester.tap(
        await reveal(
          tester,
          find.byKey(GameSearchScreen.bandKey(GameLengthBand.marathon)),
        ),
      );
      await tester.pumpAndSettle();

      expect(remote.calls.last, 'search(catan time(480..))');
    });

    testWidgets('typing a time makes a custom range and unselects the band', (
      tester,
    ) async {
      await showSheet(tester);
      await tester.tap(
        await reveal(
          tester,
          find.byKey(GameSearchScreen.bandKey(GameLengthBand.medium)),
        ),
      );
      await tester.pumpAndSettle();

      await enterBound(tester, 'time', 'to', '90');

      expect(remote.calls.last, 'search(catan time(60..90))');
      for (final band in GameLengthBand.values) {
        expect(
          tester
              .widget<ChoiceChip>(find.byKey(GameSearchScreen.bandKey(band)))
              .selected,
          isFalse,
          reason: '$band',
        );
      }
      expect(inUseLabel(tester, 'time'), '1 hr–1 hr 30 min');
    });

    testWidgets('keeping unknown values goes with a bound, not without', (
      tester,
    ) async {
      await showSheet(tester);
      final before = remote.calls.length;

      await tester.tap(
        await reveal(
          tester,
          find.byKey(GameSearchScreen.includeUnknownKey('year')),
        ),
      );
      await tester.pumpAndSettle();

      expect(remote.calls, hasLength(before));

      await enterBound(tester, 'year', 'from', '1990');

      expect(remote.calls, hasLength(before + 1));
      expect(remote.calls.last, 'search(catan year(1990..+?))');
    });

    testWidgets('a range cleared by its chip empties its fields', (
      tester,
    ) async {
      await showSheet(tester);
      await tester.tap(
        await reveal(
          tester,
          find.byKey(GameSearchScreen.includeUnknownKey('year')),
        ),
      );
      await tester.pumpAndSettle();
      await enterBound(tester, 'year', 'from', '1990');
      await enterBound(tester, 'year', 'to', '2000');
      await closeFilters(tester);

      await tester.tap(find.byTooltip('Remove 1990 to 2000 or no year'));
      await tester.pumpAndSettle();
      expect(remote.calls.last, 'search(catan)');

      await openFilters(tester);
      for (final end in ['from', 'to']) {
        final field = await reveal(
          tester,
          find.byKey(GameSearchScreen.rangeFieldKey('year', end)),
        );
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      }
      final keep = await reveal(
        tester,
        find.byKey(GameSearchScreen.includeUnknownKey('year')),
      );
      expect(tester.widget<SwitchListTile>(keep).value, isFalse);
    });
  });

  testWidgets('a source both ranges skipped asks for both kinds of game '
      'back', (tester) async {
    remote.onSearch = (_, _, _) async =>
        const GameSearchResults(unfilterableDataGateways: {'dg_bgg'});

    await show(tester, sourceNames: () async => {'dg_bgg': 'BoardGameGeek'});
    await search(tester, 'catan');
    await narrow(
      tester,
      const GameSearchFilter(
        playerCount: GameSearchRange(min: 4),
        playTime: GameSearchRange(max: 60),
      ),
    );

    // The server doesn't say which range skipped it, so the note can't
    // either. Both switches bring it back; one alone may not.
    expect(
      tester
          .widget<Text>(find.byKey(GameSearchScreen.unfilterableNoteKey))
          .data,
      "BoardGameGeek can't filter by player count, play time or both, so its "
      "games aren't shown. Include games with no player count and games with "
      'no play time to see them.',
    );
  });

  testWidgets('offline, a platform-type filter says why nothing matches', (
    tester,
  ) async {
    remote.onSearch = (_, _, _) async => throw unreachable();

    await show(
      tester,
      cache: FakeGamesCache([game('g_catan', title: 'Catan')]),
    );
    await search(tester, 'catan');
    expect(find.byKey(GameSearchScreen.platformOfflineNoteKey), findsNothing);
    expect(
      find.byKey(GameSearchScreen.serverRowKey('g_catan')),
      findsOneWidget,
    );

    await narrow(
      tester,
      const GameSearchFilter(platformTypes: {PlatformType.console}),
    );

    expect(find.byKey(GameSearchScreen.fromCacheBannerKey), findsOneWidget);
    expect(find.byKey(GameSearchScreen.platformOfflineNoteKey), findsOneWidget);
    expect(find.byKey(GameSearchScreen.serverRowKey('g_catan')), findsNothing);
  });

  group('the filter sheet', () {
    setUp(() => remote.onSearch = (_, _, _) async => const GameSearchResults());

    testWidgets('offers every content type and every platform type', (
      tester,
    ) async {
      await show(tester);
      await openFilters(tester);

      expect(find.byKey(GameSearchScreen.filterSheetKey), findsOneWidget);
      expect(GameSearchScreen.filterTypes, hasLength(11));
      for (final type in GameSearchScreen.filterTypes) {
        expect(find.byKey(GameSearchScreen.filterKey(type)), findsOneWidget);
      }
      expect(GameSearchScreen.platformFilterTypes, hasLength(7));
      for (final type in GameSearchScreen.platformFilterTypes) {
        expect(
          find.byKey(GameSearchScreen.platformFilterKey(type)),
          findsOneWidget,
        );
      }
    });

    // A drafted finding, skipped until it is fixed (#50). Opening the sheet
    // opens a route, and a screen reader says the route's name. Material
    // leaves it empty on iOS and macOS, on a node the sheet's builder can't
    // reach, since the route's children are nodes of their own.
    group("the sheet's route is named on every platform", skip: 'see #762', () {
      testWidgets('its route node', (tester) async {
        final handle = tester.ensureSemantics();
        await show(tester);
        await openFilters(tester);

        final route = find.semantics.ancestor(
          of: find.semantics.byLabel('Base game'),
          matching: find.semantics.byFlag(SemanticsFlag.namesRoute),
        );
        final data = route.evaluate().single.getSemanticsData();
        expect(data.flagsCollection.scopesRoute, isTrue);
        expect(data.label, 'Dialog');

        handle.dispose();
      }, variant: TargetPlatformVariant.all());
    });

    testWidgets('a content-type chip searches again, narrowed', (tester) async {
      await show(tester);
      await search(tester, 'catan');
      await openFilters(tester);
      await tester.tap(
        find.byKey(GameSearchScreen.filterKey(ContentType.expansion)),
      );
      await tester.pumpAndSettle();

      expect(remote.calls, ['search(catan)', 'search(catan [expansion])']);
      expect(find.byKey(GameSearchScreen.noResultsKey), findsOneWidget);
    });

    testWidgets('choosing a platform type searches again, narrowed', (
      tester,
    ) async {
      await show(tester);
      await search(tester, 'catan');
      await openFilters(tester);
      await tester.tap(
        find.byKey(GameSearchScreen.platformFilterKey(PlatformType.console)),
      );
      await tester.pumpAndSettle();

      expect(remote.calls.last, 'search(catan {console})');
    });

    testWidgets('each filter in use shows as a chip, and the button counts '
        'them', (tester) async {
      await show(tester);
      await search(tester, 'catan');
      expect(filtersButtonLabel(tester), 'Filters');

      await openFilters(tester);
      await tester.tap(
        find.byKey(GameSearchScreen.filterKey(ContentType.expansion)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(GameSearchScreen.platformFilterKey(PlatformType.pc)),
      );
      await tester.pumpAndSettle();
      await closeFilters(tester);

      expect(find.byKey(GameSearchScreen.filterSheetKey), findsNothing);
      expect(
        find.byKey(GameSearchScreen.inUseKey('content_expansion')),
        findsOneWidget,
      );
      expect(
        find.byKey(GameSearchScreen.inUseKey('platform_pc')),
        findsOneWidget,
      );
      expect(filtersButtonLabel(tester), 'Filters (2)');
    });

    testWidgets('two changes made in one turn both apply', (tester) async {
      await show(tester);
      await search(tester, 'catan');
      await openFilters(tester);

      // Neither waits for the bloc to take the other, as a field committing
      // as it loses focus and the tap that took it may not.
      tester
          .widget<FilterChip>(
            find.byKey(GameSearchScreen.filterKey(ContentType.expansion)),
          )
          .onSelected!(true);
      tester
          .widget<FilterChip>(
            find.byKey(GameSearchScreen.platformFilterKey(PlatformType.pc)),
          )
          .onSelected!(true);
      await tester.pumpAndSettle();
      await closeFilters(tester);

      expect(
        find.byKey(GameSearchScreen.inUseKey('content_expansion')),
        findsOneWidget,
      );
      expect(
        find.byKey(GameSearchScreen.inUseKey('platform_pc')),
        findsOneWidget,
      );
    });

    testWidgets('a range that keeps games with no value says so on its chip', (
      tester,
    ) async {
      await show(tester);
      await search(tester, 'catan');

      await narrow(
        tester,
        GameSearchFilter(
          publishYear: const GameSearchRange(min: 1990, includeUnknown: true),
          playerCount: const GameSearchRange(min: 4, includeUnknown: true),
          playTime: GameLengthBand.medium.range.copyWith(includeUnknown: true),
        ),
      );

      expect(inUseLabel(tester, 'year'), 'From 1990 or no year');
      expect(inUseLabel(tester, 'players'), '4 players or no player count');
      expect(inUseLabel(tester, 'time'), 'Medium or no play time');
      expect(find.byTooltip('Remove 4 players or no player count'), findsOne);
    });

    testWidgets('the last chip, removed while focused, hands focus to the '
        'Filters button (#715)', (tester) async {
      await show(tester);
      await search(tester, 'catan');
      await narrow(
        tester,
        const GameSearchFilter(platformTypes: {PlatformType.pc}),
      );
      final chip = Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(GameSearchScreen.inUseKey('platform_pc')),
            matching: find.text('PC'),
          ),
        ),
      )..requestFocus();
      await tester.pump();
      expect(chip.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        find.byKey(GameSearchScreen.inUseKey('platform_pc')),
        findsNothing,
      );
      expect(
        Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(GameSearchScreen.filtersButtonKey),
              matching: find.text('Filters'),
            ),
          ),
        ).hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('removing an in-use chip clears it, and the sheet agrees', (
      tester,
    ) async {
      await show(tester);
      await search(tester, 'catan');
      await narrow(
        tester,
        const GameSearchFilter(
          contentTypes: {ContentType.expansion},
          platformTypes: {PlatformType.pc},
        ),
      );

      await tester.tap(find.byTooltip('Remove PC'));
      await tester.pumpAndSettle();

      expect(remote.calls.last, 'search(catan [expansion])');
      expect(
        find.byKey(GameSearchScreen.inUseKey('platform_pc')),
        findsNothing,
      );

      await openFilters(tester);
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(GameSearchScreen.platformFilterKey(PlatformType.pc)),
            )
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(GameSearchScreen.filterKey(ContentType.expansion)),
            )
            .selected,
        isTrue,
      );
    });

    testWidgets('clear all removes every filter', (tester) async {
      await show(tester);
      await search(tester, 'catan');
      await narrow(
        tester,
        const GameSearchFilter(
          contentTypes: {ContentType.expansion},
          platformTypes: {PlatformType.pc},
        ),
      );
      final searches = remote.calls.length;

      await openFilters(tester);
      await tester.tap(find.byKey(GameSearchScreen.clearAllKey));
      await tester.pumpAndSettle();
      await closeFilters(tester);

      expect(remote.calls, hasLength(searches + 1));
      expect(remote.calls.last, 'search(catan)');
      expect(filtersButtonLabel(tester), 'Filters');
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'catalog_search.in_use_',
              ),
        ),
        findsNothing,
      );
    });
  });

  group('at 320dp and twice the text size', () {
    setUp(() => remote.onSearch = (_, _, _) async => const GameSearchResults());

    void narrowScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    /// Fails for a label in [chips] that is cut: wider than its line with no
    /// wrapping, or taller than its chip lets it be.
    void expectWholeLabels(WidgetTester tester, Finder chips) {
      final labels = find.descendant(
        of: chips,
        matching: find.byType(RichText),
      );
      expect(labels, findsWidgets);
      for (final label in labels.evaluate()) {
        final paragraph = label.renderObject! as RenderParagraph;
        final text = paragraph.text.toPlainText();
        expect(
          paragraph.softWrap ||
              paragraph.getMaxIntrinsicWidth(double.infinity) <=
                  paragraph.size.width,
          isTrue,
          reason: '"$text" is cut at its end',
        );
        expect(
          paragraph.size.height,
          greaterThanOrEqualTo(
            paragraph.getMaxIntrinsicHeight(paragraph.size.width) - 0.5,
          ),
          reason: '"$text" is cut at its foot',
        );
      }
    }

    testWidgets('the Filters button goes under the field, leaving it the '
        'row', (tester) async {
      narrowScreen(tester);
      await show(tester);

      final field = tester.getRect(find.byKey(GameSearchScreen.fieldKey));
      final button = tester.getRect(
        find.byKey(GameSearchScreen.filtersButtonKey),
      );
      expect(button.top, greaterThanOrEqualTo(field.bottom));
    });

    testWidgets('every chip label reads whole, under the field and in the '
        'sheet', (tester) async {
      narrowScreen(tester);
      await show(tester);
      await search(tester, 'catan');
      await narrow(
        tester,
        const GameSearchFilter(
          contentTypes: {...GameSearchScreen.filterTypes},
          platformTypes: {...GameSearchScreen.platformFilterTypes},
        ),
      );
      expectWholeLabels(tester, find.byType(InputChip));

      await openFilters(tester);

      expectWholeLabels(tester, find.byType(RawChip));
    });
  });

  testWidgets('the Filters button sits beside the field where there is '
      'room', (tester) async {
    await show(tester);

    final field = tester.getRect(find.byKey(GameSearchScreen.fieldKey));
    final button = tester.getRect(
      find.byKey(GameSearchScreen.filtersButtonKey),
    );
    expect(button.top, lessThan(field.bottom));
    expect(button.left, greaterThanOrEqualTo(field.right));
  });

  testWidgets(
    'when the server fails, searches the games saved on this device',
    (tester) async {
      remote.onSearch = (_, _, _) async => throw unreachable();

      await show(
        tester,
        cache: FakeGamesCache([game('g_catan', title: 'Catan')]),
      );
      await search(tester, 'catan');

      expect(find.byKey(GameSearchScreen.fromCacheBannerKey), findsOneWidget);
      expect(find.text('Saved on this device'), findsOneWidget);
      expect(find.text('Catan'), findsOneWidget);
    },
  );

  group('the DataGateways refused (#795)', () {
    const message = 'Not for you, and the server says so.';
    const copy =
        'Searching beyond this server is not available to you. You can '
        'still search the games this server knows about.';
    const refused = GamesForbiddenException('403', apiMessage: message);

    /// A search the server refuses the DataGateways, and answers without:
    /// with [local], or one game of its own.
    void refuseDataGateways([List<GameSearchHit>? local]) =>
        remote.onSearch = (_, _, includeExternal) async => includeExternal
        ? throw refused
        : GameSearchResults(
            local: local ?? [hit('g_catan', gameId: 'g_catan', title: 'Catan')],
          );

    /// The note in the page's footer: the one a screen reader hears.
    Finder footerNote() =>
        find.byKey(GameSearchScreen.footerDataGatewaysRefusedKey);

    testWidgets("a refused search shows the server's message under the data "
        'sources heading', (tester) async {
      refuseDataGateways();

      await show(tester);
      await search(tester, 'catan');

      final note = find.byKey(GameSearchScreen.dataGatewaysRefusedKey);
      expect(tester.widget<Text>(note).data, message);
      final heading = tester.getTopLeft(find.text('From data sources'));
      expect(tester.getTopLeft(note).dy, greaterThan(heading.dy));
      expect(find.byKey(GameSearchScreen.serverRowKey('g_catan')), findsOne);
      // The server's own results stand, and no DataGateway row.
      expect(
        find.byWidgetPredicate(
          (w) => w.key.toString().contains('catalog_search.source_'),
        ),
        findsNothing,
      );
    });

    testWidgets("a refusal without a server message shows the client's copy, "
        'in both places', (tester) async {
      remote.onSearch = (_, _, _) async => results;

      await show(tester, grant: DataGatewaySearchGrant.signedOut());
      await search(tester, 'catan');

      expect(
        tester.widget<Text>(
          find.byKey(GameSearchScreen.dataGatewaysRefusedKey),
        ),
        isA<Text>().having((t) => t.data, 'data', copy),
      );
      expect(
        find.descendant(of: footerNote(), matching: find.text(copy)),
        findsOneWidget,
      );
      expect(remote.calls.single, contains('-external'));
    });

    testWidgets('the refusal is heard once, from the foot of the page, not '
        'from the list', (tester) async {
      final handle = tester.ensureSemantics();
      final gone = StreamController<String>.broadcast();
      addTearDown(gone.close);
      refuseDataGateways([
        hit('g_catan', gameId: 'g_catan', title: 'Catan'),
        hit('g_azul', gameId: 'g_azul', title: 'Azul'),
      ]);
      await show(tester, gone: gone.stream);
      final heard = _Heard()..listen();

      await search(tester, 'catan');

      // The count above the results, then the note at the foot of the page.
      expect(heard.listen(), ['2 results', message]);
      expect(
        tester.getSemantics(footerNote()),
        isSemantics(label: message, isLiveRegion: true),
      );
      // Where the DataGateways' rows would be, the note says the same,
      // quietly.
      expect(
        tester.getSemantics(
          find.byKey(GameSearchScreen.dataGatewaysRefusedKey),
        ),
        isSemantics(label: message, isLiveRegion: false),
      );

      // The answer shown again, less a game found gone: the count is heard,
      // and the note isn't again.
      gone.add('g_azul');
      await tester.pumpAndSettle();

      expect(heard.listen(), ['1 result']);
      handle.dispose();
    });

    testWidgets('each refused search is heard once: the note goes as the next '
        'search starts, and comes back with its answer', (tester) async {
      final handle = tester.ensureSemantics();
      refuseDataGateways();
      await show(tester);
      final heard = _Heard()..listen();
      await search(tester, 'catan');
      expect(heard.listen(), ['1 result', message]);
      final first = tester.getSemantics(footerNote()).id;

      // The next search waits on the server, and the note waits with it.
      final answer = Completer<GameSearchResults>();
      remote.onSearch = (_, _, _) => answer.future;
      await tester.enterText(find.byKey(GameSearchScreen.fieldKey), 'azul');
      await tester.pump(GameSearchBloc.defaultDebounce);
      await tester.pump();
      expect(find.byKey(GameSearchScreen.loadingKey), findsOneWidget);
      expect(footerNote(), findsNothing);
      heard.listen();

      answer.complete(
        GameSearchResults(local: [hit('g_azul', gameId: 'g_azul')]),
      );
      await tester.pumpAndSettle();

      expect(heard.listen(), ['1 result', message]);
      expect(tester.getSemantics(footerNote()).id, isNot(first));

      // Cleared, the page goes back to its start, and the note goes too.
      await tester.tap(find.byKey(GameSearchScreen.clearKey));
      await tester.pumpAndSettle();

      expect(find.byKey(GameSearchScreen.idleKey), findsOneWidget);
      expect(footerNote(), findsNothing);
      handle.dispose();
    });

    testWidgets("a new text's refused answer is a new note, even with no "
        'frame of loading before it', (tester) async {
      final handle = tester.ensureSemantics();
      refuseDataGateways();
      await show(tester);
      final heard = _Heard()..listen();
      await search(tester, 'catan');
      heard.listen();
      final first = tester.getSemantics(footerNote()).id;

      // The server answers within the frame the search starts in.
      await search(tester, 'catan junior');

      // The count reads as it did, so only the note is heard.
      expect(heard.listen(), [message]);
      expect(tester.getSemantics(footerNote()).id, isNot(first));
      handle.dispose();
    });

    // Measured on review: the note among the results, after a page of this
    // server's games, was out of the semantics tree as the answer landed, so
    // it was never heard.
    group("at phone sizes, under a page of this server's games", () {
      final page = [
        for (var n = 0; n < GamesRemoteDataSource.searchPageSize; n++)
          hit('g_$n', gameId: 'g_$n', title: 'Server game $n'),
      ];
      const total = '${GamesRemoteDataSource.searchPageSize} results';

      for (final (name, size, textScale) in const [
        ('390dp', Size(390, 844), 1.0),
        ('320dp at twice the text size', Size(320, 800), 2.0),
      ]) {
        testWidgets('$name: the note is heard as the answer lands, and stays '
            'as the page scrolls', (tester) async {
          useViewSize(tester, size);
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final handle = tester.ensureSemantics();
          refuseDataGateways(page);
          await show(tester);
          final heard = _Heard()..listen();

          await search(tester, 'game');

          expect(heard.listen(), [total, message]);
          // In the tree, and not hidden, as it lands.
          final note = tester.getSemantics(footerNote());
          expect(note, isSemantics(label: message, isLiveRegion: true));
          expect(note.getSemanticsData().flagsCollection.isHidden, isFalse);

          // The user reads on, to the end of the page.
          final position = tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: find.byType(CustomScrollView),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              )
              .position;
          position.jumpTo(position.maxScrollExtent);
          await tester.pump();

          expect(position.pixels, greaterThan(0));
          expect(heard.listen(), isEmpty);
          final after = tester.getSemantics(footerNote());
          expect(after.id, note.id);
          expect(after.getSemanticsData().flagsCollection.isHidden, isFalse);
          handle.dispose();
        });
      }
    });

    testWidgets('the page counts the rows it holds, not the note', (
      tester,
    ) async {
      refuseDataGateways();

      await show(tester);
      await search(tester, 'catan');

      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(scrollView.semanticChildCount, 1);
    });

    testWidgets('a user the server allows sees no note, and the foot of the '
        'page says nothing', (tester) async {
      remote.onSearch = (_, _, _) async => results;

      await show(tester);
      await search(tester, 'catan');

      expect(find.byKey(GameSearchScreen.dataGatewaysRefusedKey), findsNothing);
      expect(footerNote(), findsNothing);
      // The footer is passed on every build, and draws nothing here.
      final footer = tester.widget<BgePage>(find.byType(BgePage)).footer;
      expect(footer, isNotNull);
      expect(tester.getSize(find.byWidget(footer!)).height, 0);
    });
  });

  testWidgets('a refusal says the user has no access, and searches nothing '
      'saved', (tester) async {
    remote.onSearch = (_, _, _) async =>
        throw const GamesForbiddenException('403');

    await show(
      tester,
      cache: FakeGamesCache([game('g_catan', title: 'Catan')]),
    );
    await search(tester, 'catan');

    expect(find.byKey(GameSearchScreen.deniedKey), findsOneWidget);
    expect(find.byKey(GameSearchScreen.serverRowKey('g_catan')), findsNothing);
  });

  testWidgets('clearing the field returns to the start', (tester) async {
    remote.onSearch = (_, _, _) async => results;

    await show(tester);
    await search(tester, 'catan');
    await tester.tap(find.byKey(GameSearchScreen.clearKey));
    await tester.pump(GameSearchBloc.defaultDebounce);
    await tester.pumpAndSettle();

    expect(find.byKey(GameSearchScreen.idleKey), findsOneWidget);
  });

  group('as results arrive (#473)', () {
    late FakeGameSearchChannel channel;

    setUp(() => channel = FakeGameSearchChannel());

    const stillSearching =
        'Showing the first results. Still searching data sources…';
    const cutShortNote =
        'The search ended before every data source answered, so some '
        'results may be missing.';

    final local = GameSearchResults(
      local: [hit('g_catan', gameId: 'g_catan', title: 'Catan')],
    );
    // A row from each of two data sources, each a row a keyboard user can be
    // on. The second's is a game the server holds.
    final found = local.copyWith(
      byDataGateway: {
        'dg_bgg': [hit('926', title: 'Catan: Seafarers')],
        'dg_igdb': [hit('c-1', gameId: 'g_online', title: 'Catan Online')],
      },
    );
    // A second row from the first data source. A source's rows stay
    // together, so it lands above the second source's row.
    final more = found.copyWith(
      byDataGateway: {
        'dg_bgg': [
          hit('926', title: 'Catan: Seafarers'),
          hit('927', title: 'Catan: Cities & Knights'),
        ],
        'dg_igdb': [hit('c-1', gameId: 'g_online', title: 'Catan Online')],
      },
    );

    /// Shows the screen over [channel], types [text] and waits out the
    /// debounce, so its search is open on the channel and not yet answered.
    Future<FakeChannelSearch> startSearch(
      WidgetTester tester, {
      String text = 'catan',
      void Function(BuildContext context, String gameId)? onOpen,
      DataGatewaySearchGrant? grant,
      Stream<String>? gone,
    }) async {
      await show(
        tester,
        streamSource: _StreamSource(channel: channel),
        onOpen: onOpen,
        grant: grant,
        gone: gone,
      );
      await tester.enterText(find.byKey(GameSearchScreen.fieldKey), text);
      await tester.pump(GameSearchBloc.defaultDebounce);
      return channel.searches.single;
    }

    /// Answers [search] with everything it has found so far, this server's
    /// half finished, and shows the answer.
    ///
    /// While the search runs a spinner turns, which never settles, so this
    /// pumps rather than settling: once for the answer to reach the screen,
    /// which schedules a frame, and once to draw it.
    Future<void> answer(
      WidgetTester tester,
      FakeChannelSearch search,
      GameSearchResults results, {
      bool done = false,
      bool cutShort = false,
    }) async {
      search.answer(results, localDone: true, done: done, cutShort: cutShort);
      await tester.pump();
      await tester.pump();
    }

    SemanticsNode countNode(WidgetTester tester) =>
        tester.getSemantics(find.byKey(GameSearchScreen.countKey));

    /// The footer's word that the search goes on.
    SemanticsNode footerStatusNode(WidgetTester tester) => tester.getSemantics(
      find.byKey(GameSearchScreen.footerStillSearchingKey),
    );

    /// The footer's count, once a streamed search has ended.
    SemanticsNode footerCountNode(WidgetTester tester) =>
        tester.getSemantics(find.byKey(GameSearchScreen.footerCountKey));

    /// The footer's note saying why the DataGateways were left out (#795).
    SemanticsNode footerNoteNode(WidgetTester tester) => tester.getSemantics(
      find.byKey(GameSearchScreen.footerDataGatewaysRefusedKey),
    );

    /// The nodes in the semantics tree that say [label], by id.
    List<int> saying(String label) => [
      for (final node
          in find.semantics
              .byPredicate((node) => node.getSemanticsData().label == label)
              .evaluate())
        node.id,
    ];

    testWidgets('while searching, the still-searching row shows under the '
        'data sources heading, and the footer says it as a live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final search = await startSearch(tester);

      // This server's half: the data sources' heading is up before any of
      // their rows, over the row saying they are still being searched.
      await answer(tester, search, local);

      final tail = find.byKey(GameSearchScreen.stillSearchingKey);
      expect(
        find.byKey(GameSearchScreen.serverRowKey('g_catan')),
        findsOneWidget,
      );
      expect(tail, findsOneWidget);
      expect(
        tester.getTopLeft(tail).dy,
        greaterThan(tester.getTopLeft(find.text('From data sources')).dy),
      );
      // The section's row is drawn there, and left out of the semantics
      // tree: the footer, always on screen, says it, and is what is heard.
      expect(
        find.descendant(of: tail, matching: find.text(stillSearching)),
        findsOneWidget,
      );
      expect(
        footerStatusNode(tester),
        isSemantics(label: stillSearching, isLiveRegion: true),
      );
      expect(saying(stillSearching), [footerStatusNode(tester).id]);
      // A section's loading tail, with a small spinner of its own, and not
      // the whole-surface wait.
      expect(
        find.descendant(
          of: tail,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(find.byType(BgeLoadingState), findsNothing);

      // Their rows arrive above it: it stays the section's last row.
      await answer(tester, search, found);

      expect(
        tester.getTopLeft(tail).dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(
                find.byKey(GameSearchScreen.sourceRowKey('dg_igdb', 'c-1')),
              )
              .dy,
        ),
      );
      handle.dispose();
    });

    testWidgets('while searching, the count is not a live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final search = await startSearch(tester);

      await answer(tester, search, local);
      expect(
        countNode(tester),
        isSemantics(label: '1 result', isLiveRegion: false),
      );

      // A count that changes as answers arrive says nothing.
      await answer(tester, search, found);
      expect(
        countNode(tester),
        isSemantics(label: '3 results', isLiveRegion: false),
      );
      handle.dispose();
    });

    testWidgets('when done, the tail goes and the footer holds the count as '
        'a live region', (tester) async {
      final handle = tester.ensureSemantics();
      final search = await startSearch(tester);
      await answer(tester, search, found);

      await answer(tester, search, more, done: true);

      expect(find.byKey(GameSearchScreen.stillSearchingKey), findsNothing);
      expect(
        find.byKey(GameSearchScreen.footerStillSearchingKey),
        findsNothing,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        footerCountNode(tester),
        isSemantics(label: '4 results', isLiveRegion: true),
      );
      // The count above the results shows it too, and says nothing.
      expect(
        countNode(tester),
        isSemantics(label: '4 results', isLiveRegion: false),
      );
      // What the data sources found stays, under their heading.
      expect(find.text('From data sources'), findsOneWidget);
      expect(
        find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '927')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets("the count's live region is a new node in the footer when "
        'the search finishes', (tester) async {
      final handle = tester.ensureSemantics();
      final search = await startSearch(tester);
      await answer(tester, search, found);
      final before = footerStatusNode(tester).id;

      // The last answer found nothing more, so the count reads as the one
      // above the results did: only a new node is heard.
      await answer(tester, search, found, done: true);

      final after = footerCountNode(tester);
      expect(after, isSemantics(label: '3 results', isLiveRegion: true));
      expect(after.id, isNot(before));
      handle.dispose();
    });

    testWidgets('the footer says the search goes on once, not once per '
        'answer', (tester) async {
      final handle = tester.ensureSemantics();
      final search = await startSearch(tester);
      await answer(tester, search, local);
      final first = footerStatusNode(tester).id;

      // Rows arrive and a note too in one answer, then more rows. It keeps
      // its node and its words, so nothing is heard again.
      await answer(
        tester,
        search,
        found.copyWith(unavailableDataGateways: const {'dg_down'}),
      );
      await answer(
        tester,
        search,
        more.copyWith(unavailableDataGateways: const {'dg_down'}),
      );

      // Below the fold, over the footer.
      expect(
        find.byKey(GameSearchScreen.missingSourcesKey, skipOffstage: false),
        findsOneWidget,
      );
      final node = footerStatusNode(tester);
      expect(node, isSemantics(label: stillSearching, isLiveRegion: true));
      expect(node.id, first);
      handle.dispose();
    });

    testWidgets('a cut-short search shows its note', (tester) async {
      final handle = tester.ensureSemantics();
      final search = await startSearch(tester);
      await answer(tester, search, found);
      expect(find.byKey(GameSearchScreen.cutShortKey), findsNothing);

      // The connection dropped with a data source still to answer, after
      // another had failed.
      await answer(
        tester,
        search,
        found.copyWith(unavailableDataGateways: const {'dg_down'}),
        done: true,
        cutShort: true,
      );

      final note = find.byKey(GameSearchScreen.cutShortKey);
      expect(note, findsOneWidget);
      expect(find.text(cutShortNote), findsOneWidget);
      // Beside the note on the sources that didn't answer.
      expect(
        tester.getTopLeft(note).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(GameSearchScreen.missingSourcesKey)).dy,
        ),
      );
      // Quiet: the footer's final count is what is heard as the search
      // ends.
      expect(
        tester.getSemantics(note),
        isSemantics(label: cutShortNote, isLiveRegion: false),
      );
      expect(
        footerCountNode(tester),
        isSemantics(label: '3 results', isLiveRegion: true),
      );
      // What was found stands.
      expect(
        find.byKey(GameSearchScreen.sourceRowKey('dg_igdb', 'c-1')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a search cut short before its end says so only once it '
        'ends', (tester) async {
      final search = await startSearch(tester);

      // The server's search of the data sources failed as a whole: the
      // answer is cut short, and the search's end follows it.
      await answer(tester, search, found, cutShort: true);

      expect(find.byKey(GameSearchScreen.stillSearchingKey), findsOneWidget);
      expect(
        find.byKey(GameSearchScreen.footerStillSearchingKey),
        findsOneWidget,
      );
      expect(find.byKey(GameSearchScreen.cutShortKey), findsNothing);

      await answer(tester, search, found, done: true, cutShort: true);

      expect(find.byKey(GameSearchScreen.cutShortKey), findsOneWidget);
      expect(find.byKey(GameSearchScreen.stillSearchingKey), findsNothing);
      expect(
        find.byKey(GameSearchScreen.footerStillSearchingKey),
        findsNothing,
      );
    });

    testWidgets('a row keeps its key as rows arrive above it', (tester) async {
      final search = await startSearch(tester, onOpen: (_, _) {});
      await answer(tester, search, found);
      final row = find.byKey(GameSearchScreen.sourceRowKey('dg_igdb', 'c-1'));
      FocusNode focusOf() => Focus.of(
        tester.element(
          find.descendant(of: row, matching: find.text('Catan Online')),
        ),
      );
      final focus = focusOf()..requestFocus();
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);
      final top = tester.getTopLeft(row).dy;

      // A second row from the first data source lands above this one.
      await answer(tester, search, more);

      expect(tester.getTopLeft(row).dy, greaterThan(top));
      // The list's wrapper holds the key, and the row doesn't too (#549).
      expect(row, findsOneWidget);
      expect(focusOf(), same(focus));
      expect(focus.hasPrimaryFocus, isTrue);
    });

    testWidgets('semanticChildCount follows the rows held now', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      int? semanticChildCount() => tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount;
      // A row's place in that count: "result 4 of 4".
      int? indexOf(Finder row) {
        SemanticsNode? node = tester.getSemantics(row);
        while (node != null && node.indexInParent == null) {
          node = node.parent;
        }
        return node?.indexInParent;
      }

      final search = await startSearch(tester);

      await answer(tester, search, local);
      expect(semanticChildCount(), 1);

      await answer(tester, search, found);
      expect(semanticChildCount(), 3);

      await answer(tester, search, more, done: true);
      expect(semanticChildCount(), 4);
      expect(indexOf(find.byKey(GameSearchScreen.serverRowKey('g_catan'))), 0);
      expect(
        indexOf(find.byKey(GameSearchScreen.sourceRowKey('dg_igdb', 'c-1'))),
        3,
      );
      handle.dispose();
    });

    testWidgets('a stream source is opened per screen and closed when the '
        'screen goes', (tester) async {
      final source = _StreamSource();
      await show(tester, streamSource: source);
      expect(source.opened, hasLength(1));
      final opened = source.opened.single;

      await tester.enterText(find.byKey(GameSearchScreen.fieldKey), 'catan');
      await tester.pump(GameSearchBloc.defaultDebounce);
      expect(opened.calls, ['search(catan)']);
      expect(remote.calls, isEmpty);

      // Built again, it is the same screen, with the same channel.
      await show(tester, streamSource: source);
      expect(source.opened, hasLength(1));

      // Gone mid-search: the search is cancelled on the server, then the
      // channel is closed. The bloc's close waits on the cancel, which
      // completes in real time, not on the test's clock.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(opened.calls, ['search(catan)', 'cancel(catan)']);
      expect(opened.closes, 1);

      // The next screen opens one of its own.
      await show(tester, streamSource: source);
      expect(source.opened, hasLength(2));
    });

    testWidgets('a stream source whose session has closed searches over '
        'REST', (tester) async {
      // A route built just before sign-out: the session's connection has
      // closed under it.
      remote.onSearch = (_, _, _) async => results;

      await show(tester, streamSource: _StreamSource(closed: true));
      await search(tester, 'catan');

      expect(tester.takeException(), isNull);
      expect(remote.calls, ['search(catan)']);
      expect(find.text('3 results'), findsOneWidget);
    });

    testWidgets('a search refused the data sources shows no still-searching '
        'row', (tester) async {
      // This server's half lands before the search ends. The data sources
      // weren't asked, so nothing is still being searched there.
      final search = await startSearch(
        tester,
        grant: DataGatewaySearchGrant.signedOut(),
      );
      await answer(tester, search, local);

      expect(channel.calls, ['search(catan -external)']);
      expect(find.text('From data sources'), findsOneWidget);
      expect(
        find.byKey(GameSearchScreen.dataGatewaysRefusedKey),
        findsOneWidget,
      );
      expect(find.byKey(GameSearchScreen.stillSearchingKey), findsNothing);
      // Nor does the footer say so: it says why, instead (#795).
      expect(
        find.byKey(GameSearchScreen.footerStillSearchingKey),
        findsNothing,
      );
      expect(
        find.byKey(GameSearchScreen.footerDataGatewaysRefusedKey),
        findsOneWidget,
      );
    });

    testWidgets("a stream that fails after answers gives way to the device's "
        'answer, said above the results', (tester) async {
      final handle = tester.ensureSemantics();
      await show(
        tester,
        streamSource: _StreamSource(channel: channel),
        cache: FakeGamesCache([game('g_catan', title: 'Catan')]),
      );
      await tester.enterText(find.byKey(GameSearchScreen.fieldKey), 'catan');
      await tester.pump(GameSearchBloc.defaultDebounce);
      final search = channel.searches.single;
      await answer(tester, search, local);
      expect(footerStatusNode(tester), isSemantics(isLiveRegion: true));

      search.fail(unreachable());
      await tester.pump();
      await tester.pump();

      // Not streamed, the device's answer comes whole, and is said as one
      // over REST is: by the count above the results. The footer has
      // nothing more to say.
      expect(find.byKey(GameSearchScreen.fromCacheBannerKey), findsOneWidget);
      expect(
        countNode(tester),
        isSemantics(label: '1 result', isLiveRegion: true),
      );
      expect(
        find.byKey(GameSearchScreen.footerStillSearchingKey),
        findsNothing,
      );
      expect(find.byKey(GameSearchScreen.footerCountKey), findsNothing);
      handle.dispose();
    });

    testWidgets('nothing found yet is not no results: that waits for the '
        'end', (tester) async {
      final search = await startSearch(tester, text: 'zzz');

      // This server found nothing, and the data sources are still searching.
      await answer(tester, search, const GameSearchResults());

      expect(find.byKey(GameSearchScreen.noResultsKey), findsNothing);
      expect(find.byKey(GameSearchScreen.stillSearchingKey), findsOneWidget);

      await answer(tester, search, const GameSearchResults(), done: true);

      expect(find.byKey(GameSearchScreen.noResultsKey), findsOneWidget);
      expect(find.byKey(GameSearchScreen.stillSearchingKey), findsNothing);
    });

    testWidgets('while nothing has been found yet, the count waits and the '
        'row says only that the search goes on', (tester) async {
      final handle = tester.ensureSemantics();
      final search = await startSearch(tester, text: 'zzz');

      // This server found nothing, and the data sources are still searching:
      // "No results" would say the opposite of what is happening.
      await answer(tester, search, const GameSearchResults());

      const noneYet = 'Still searching data sources…';
      final tail = find.byKey(GameSearchScreen.stillSearchingKey);
      expect(find.byKey(GameSearchScreen.countKey), findsNothing);
      expect(
        find.descendant(of: tail, matching: find.text(noneYet)),
        findsOneWidget,
      );
      // The footer says the same, quietly: the search was heard as it began.
      // The row in the list is drawn, and not in the semantics tree.
      expect(
        footerStatusNode(tester),
        isSemantics(label: noneYet, isLiveRegion: false),
      );
      expect(saying(noneYet), [footerStatusNode(tester).id]);

      // The first row brings the count back, and the words for the first
      // results, which the footer says.
      await answer(
        tester,
        search,
        GameSearchResults(
          byDataGateway: {
            'dg_bgg': [hit('926', title: 'Catan: Seafarers')],
          },
        ),
      );

      expect(
        countNode(tester),
        isSemantics(label: '1 result', isLiveRegion: false),
      );
      expect(
        find.descendant(of: tail, matching: find.text(stillSearching)),
        findsOneWidget,
      );
      expect(
        footerStatusNode(tester),
        isSemantics(label: stillSearching, isLiveRegion: true),
      );
      expect(saying(stillSearching), [footerStatusNode(tester).id]);
      handle.dispose();
    });

    testWidgets('a source that sends a result twice still shows every row '
        'as rows arrive above it', (tester) async {
      // Each row now has the outline's gap below it (#647): a taller surface
      // keeps all five in the viewport, as the default one did before.
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final search = await startSearch(tester);
      final repeating = local.copyWith(
        byDataGateway: {
          'dg_bgg': [hit('926', title: 'Catan: Seafarers')],
          // The second data source sends one of its results twice.
          'dg_igdb': [
            hit('c-1', title: 'Catan Online'),
            hit('c-1', title: 'Catan Online'),
            hit('c-2', title: 'Catan Duel'),
          ],
        },
      );
      await answer(tester, search, repeating);

      // A row from the first data source lands above the repeat.
      await answer(
        tester,
        search,
        repeating.copyWith(
          byDataGateway: {
            'dg_bgg': [
              hit('926', title: 'Catan: Seafarers'),
              hit('927', title: 'Catan: Cities & Knights'),
            ],
            'dg_igdb': repeating.byDataGateway['dg_igdb']!,
          },
        ),
      );

      for (final title in [
        'Catan',
        'Catan: Seafarers',
        'Catan: Cities & Knights',
        'Catan Online',
        'Catan Duel',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('5 results'), findsOneWidget);
    });

    // Each expectation lists what is heard at each step: the search
    // starting, then each answer.
    group('what a screen reader hears', () {
      const searching =
          'Searching… Data sources can take up to 15 seconds to answer.';
      const refused =
          'Searching beyond this server is not available to you. You can '
          'still search the games this server knows about.';

      late _Heard heard;

      setUp(() => heard = _Heard());

      /// Makes [change], and returns what was heard over the two frames that
      /// show it: one for it to reach the screen, and one to draw it.
      Future<List<String>> after(
        WidgetTester tester,
        void Function() change,
      ) async {
        change();
        await tester.pump();
        final first = heard.listen();
        await tester.pump();
        return [...first, ...heard.listen()];
      }

      /// Answers [search] as [answer] does, and returns what was heard.
      Future<List<String>> hear(
        WidgetTester tester,
        FakeChannelSearch search,
        GameSearchResults results, {
        bool done = false,
      }) => after(
        tester,
        () => search.answer(results, localDone: true, done: done),
      );

      testWidgets('the first rows, then the end', (tester) async {
        final handle = tester.ensureSemantics();
        final search = await startSearch(tester);

        expect(
          [
            heard.listen(),
            await hear(tester, search, local),
            await hear(tester, search, found),
            await hear(tester, search, more, done: true),
          ],
          [
            [searching],
            [stillSearching],
            <String>[],
            ['4 results'],
          ],
        );
        handle.dispose();
      });

      testWidgets('nothing found yet, then the first rows, then the end', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final search = await startSearch(tester);
        final first = GameSearchResults(
          byDataGateway: {
            'dg_bgg': [hit('926', title: 'Catan: Seafarers')],
          },
        );
        final second = first.copyWith(
          byDataGateway: {
            'dg_bgg': [
              hit('926', title: 'Catan: Seafarers'),
              hit('927', title: 'Catan: Cities & Knights'),
            ],
          },
        );

        expect(
          [
            heard.listen(),
            // This server found nothing. The row saying the search goes on
            // comes quietly: the search was said to be running as it began.
            await hear(tester, search, const GameSearchResults()),
            await hear(tester, search, first),
            await hear(tester, search, second),
            await hear(tester, search, second, done: true),
          ],
          [
            [searching],
            <String>[],
            [stillSearching],
            <String>[],
            ['2 results'],
          ],
        );
        handle.dispose();
      });

      testWidgets('the first results again, when the rows found are taken '
          'down and others arrive', (tester) async {
        final handle = tester.ensureSemantics();
        final gone = StreamController<String>.broadcast();
        addTearDown(gone.close);
        final search = await startSearch(tester, gone: gone.stream);
        final first = GameSearchResults(
          byDataGateway: {
            'dg_bgg': [
              hit('926', gameId: 'g_seafarers', title: 'Catan: Seafarers'),
            ],
          },
        );
        final second = first.copyWith(
          byDataGateway: {
            'dg_bgg': [
              ...first.byDataGateway['dg_bgg']!,
              hit('927', title: 'Catan: Cities & Knights'),
            ],
          },
        );

        expect(
          [
            heard.listen(),
            await hear(tester, search, first),
            // The one game found is found gone: nothing found, again.
            await after(tester, () => gone.add('g_seafarers')),
            await hear(tester, search, second),
            await hear(tester, search, second, done: true),
          ],
          [
            [searching],
            [stillSearching],
            <String>[],
            [stillSearching],
            ['1 result'],
          ],
        );
        handle.dispose();
      });

      testWidgets('a refusal once, though the search ends with nothing '
          'found', (tester) async {
        final handle = tester.ensureSemantics();
        final search = await startSearch(
          tester,
          text: 'zzz',
          grant: DataGatewaySearchGrant.signedOut(),
        );

        final heardAtStart = heard.listen();
        final heardHalf = await hear(tester, search, const GameSearchResults());
        final note = footerNoteNode(tester).id;
        final heardAtEnd = await hear(
          tester,
          search,
          const GameSearchResults(),
          done: true,
        );

        expect(
          [heardAtStart, heardHalf, heardAtEnd],
          [
            [searching],
            // From the footer.
            [refused],
            // The empty state among the results, then the footer's count.
            ['No games match “zzz”.', 'No results'],
          ],
        );
        // The footer's note kept its node as the count arrived.
        expect(footerNoteNode(tester).id, note);
        handle.dispose();
      });

      testWidgets("a refused stream: the note once, as this server's half "
          'lands, then the count once, above it, as the search ends', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final search = await startSearch(
          tester,
          grant: DataGatewaySearchGrant.signedOut(),
        );

        final heardAtStart = heard.listen();
        final heardHalf = await hear(tester, search, local);
        final note = footerNoteNode(tester);
        final heardAtEnd = await hear(tester, search, local, done: true);

        expect(
          [heardAtStart, heardHalf, heardAtEnd],
          [
            [searching],
            [refused],
            ['1 result'],
          ],
        );
        // The note kept its node, and the count is a node of its own, above
        // it, where a long note can't push it out of the footer's view.
        expect(footerNoteNode(tester).id, note.id);
        final count = footerCountNode(tester);
        expect(count, isSemantics(label: '1 result', isLiveRegion: true));
        expect(count.id, isNot(note.id));
        expect(
          tester.getBottomLeft(find.byKey(GameSearchScreen.footerCountKey)).dy,
          lessThanOrEqualTo(
            tester
                .getTopLeft(
                  find.byKey(GameSearchScreen.footerDataGatewaysRefusedKey),
                )
                .dy,
          ),
        );
        // In the list, the note is read where it stands, and not heard.
        expect(
          tester.getSemantics(
            find.byKey(GameSearchScreen.dataGatewaysRefusedKey),
          ),
          isSemantics(label: refused, isLiveRegion: false),
        );
        handle.dispose();
      });

      // Measured on review: with the announcements among the results, a
      // page of this server's games put them out of the tree, or hidden, at
      // phone sizes, and a user scrolled down missed the end.
      group("at phone sizes, under a page of this server's games", () {
        final page = GameSearchResults(
          local: [
            for (var n = 0; n < GamesRemoteDataSource.searchPageSize; n++)
              hit('g_$n', gameId: 'g_$n', title: 'Server game $n'),
          ],
        );
        const total = '${GamesRemoteDataSource.searchPageSize} results';

        /// The live region in the tree that says [label]. Fails unless there
        /// is exactly one.
        SemanticsData liveRegion(String label) => find.semantics
            .byPredicate((node) {
              final data = node.getSemanticsData();
              return data.flagsCollection.isLiveRegion && data.label == label;
            })
            .evaluate()
            .single
            .getSemanticsData();

        /// The page's own scroll position, not the footer's.
        ScrollPosition pagePosition(WidgetTester tester) => tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(CustomScrollView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;

        for (final (name, size, textScale) in const [
          ('390dp', Size(390, 844), 1.0),
          ('390dp with the keyboard up', Size(390, 520), 1.0),
          ('320dp at twice the text size', Size(320, 800), 2.0),
        ]) {
          testWidgets('$name: the first results, and the end with the page '
              'scrolled down', (tester) async {
            useViewSize(tester, size);
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final handle = tester.ensureSemantics();
            final search = await startSearch(tester);

            final heardAtStart = heard.listen();
            final heardFirst = await hear(tester, search, page);
            // In the tree, and not hidden, as the first results land.
            expect(
              liveRegion(stillSearching).flagsCollection.isHidden,
              isFalse,
            );

            // The user reads on, to the end of the page.
            final position = pagePosition(tester);
            final heardScrolling = await after(
              tester,
              () => position.jumpTo(position.maxScrollExtent),
            );
            expect(position.pixels, greaterThan(0));

            final heardAtEnd = await hear(tester, search, page, done: true);
            expect(liveRegion(total).flagsCollection.isHidden, isFalse);

            expect(
              [heardAtStart, heardFirst, heardScrolling, heardAtEnd],
              [
                [searching],
                [stillSearching],
                <String>[],
                [total],
              ],
            );
            handle.dispose();
          });

          testWidgets('$name: a refused stream, its note and then its end '
              'with the page scrolled down (#795)', (tester) async {
            useViewSize(tester, size);
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final handle = tester.ensureSemantics();
            final search = await startSearch(
              tester,
              grant: DataGatewaySearchGrant.signedOut(),
            );

            final heardAtStart = heard.listen();
            final heardHalf = await hear(tester, search, page);
            // In the tree, and not hidden, as this server's half lands.
            expect(liveRegion(refused).flagsCollection.isHidden, isFalse);

            final position = pagePosition(tester);
            final heardScrolling = await after(
              tester,
              () => position.jumpTo(position.maxScrollExtent),
            );
            expect(position.pixels, greaterThan(0));

            final heardAtEnd = await hear(tester, search, page, done: true);
            expect(liveRegion(refused).flagsCollection.isHidden, isFalse);
            expect(liveRegion(total).flagsCollection.isHidden, isFalse);

            expect(
              [heardAtStart, heardHalf, heardScrolling, heardAtEnd],
              [
                [searching],
                [refused],
                <String>[],
                [total],
              ],
            );
            handle.dispose();
          });
        }
      });
    });
  });

  group('accessibility audit', () {
    // `show` pumps the screen and wants the tester, so each call pumps it
    // with `pump`, and its arrange searches.
    Future<void> showAudited(
      WidgetTester tester,
      ThemeData theme, {
      FakeGamesCache? cache,
      ValueListenable<bool>? offline,
      Future<Map<String, String>> Function()? sourceNames,
      GameSearchStreamSource? streamSource,
    }) => show(
      tester,
      cache: cache,
      offline: offline,
      sourceNames: sourceNames,
      streamSource: streamSource,
      onOpen: (_, _) {},
      access: mayImport(),
      theme: theme,
    );

    // Six hits on the server and six from a source, with a source that
    // didn't answer: taller than the narrow window at 2.0 text.
    final many = GameSearchResults(
      local: [
        for (var n = 0; n < 6; n++)
          hit('g_$n', gameId: 'g_$n', title: 'Server game number $n'),
      ],
      byDataGateway: {
        'dg_bgg': [
          for (var n = 0; n < 6; n++) hit('x_$n', title: 'Source game $n'),
        ],
      },
      unavailableDataGateways: const {'dg_down'},
    );

    final names = {'dg_bgg': 'BoardGameGeek', 'dg_down': 'Steam'};

    auditScreen(
      'idle',
      pump: (tester, theme) async {
        await showAudited(tester, theme);
        expect(find.byKey(GameSearchScreen.idleKey), findsOneWidget);
      },
    );

    // The search is still being read: the spinner never settles.
    auditScreen(
      'loading',
      pump: (tester, theme) async {
        final pending = Completer<GameSearchResults>();
        addTearDown(() => pending.complete(const GameSearchResults()));
        remote.onSearch = (_, _, _) => pending.future;
        await showAudited(tester, theme);
      },
      arrange: (tester) async {
        await tester.enterText(find.byKey(GameSearchScreen.fieldKey), 'catan');
        await tester.pump(GameSearchBloc.defaultDebounce);
        await tester.pump();
        expect(find.byKey(GameSearchScreen.loadingKey), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'ready',
      pump: (tester, theme) async {
        remote.onSearch = (_, _, _) async => many;
        await showAudited(tester, theme, sourceNames: () async => names);
      },
      arrange: (tester) async {
        await search(tester, 'game');
        expect(find.byKey(GameSearchScreen.countKey), findsOneWidget);
      },
    );

    // Answers still arriving over the socket (#473): the still-searching
    // row's spinner never settles. At 320dp and twice the text size the row
    // is below the fold, so it is brought into view, to be audited too.
    late FakeGameSearchChannel streaming;
    auditScreen(
      'still searching',
      pump: (tester, theme) async {
        streaming = FakeGameSearchChannel();
        await showAudited(
          tester,
          theme,
          sourceNames: () async => names,
          streamSource: _StreamSource(channel: streaming),
        );
      },
      arrange: (tester) async {
        await tester.enterText(find.byKey(GameSearchScreen.fieldKey), 'catan');
        await tester.pump(GameSearchBloc.defaultDebounce);
        streaming.searches.single.answer(results, localDone: true);
        await tester.pump();
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(GameSearchScreen.stillSearchingKey, skipOffstage: false),
        );
        await tester.pump();
        expect(find.byKey(GameSearchScreen.stillSearchingKey), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'ready, scrolled to the end',
      pump: (tester, theme) async {
        remote.onSearch = (_, _, _) async => many;
        await showAudited(tester, theme, sourceNames: () async => names);
      },
      arrange: (tester) async {
        await search(tester, 'game');
        await scrollListToEnd(
          tester,
          find.byKey(GameSearchScreen.missingSourcesKey),
        );
      },
    );

    // Refused the DataGateways (#795): the note under their heading, and in
    // the page's footer, in the client's copy, the longest it gets.
    auditScreen(
      'refused the data sources',
      pump: (tester, theme) async {
        remote.onSearch = (_, _, includeExternal) async => includeExternal
            ? throw const GamesForbiddenException('403')
            : GameSearchResults(local: many.local);
        await showAudited(tester, theme);
      },
      arrange: (tester) async {
        await search(tester, 'game');
        expect(
          find.byKey(GameSearchScreen.footerDataGatewaysRefusedKey),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'empty',
      pump: (tester, theme) async {
        remote.onSearch = (_, _, _) async => const GameSearchResults();
        await showAudited(tester, theme);
      },
      arrange: (tester) async {
        await search(tester, 'zzz');
        expect(find.byKey(GameSearchScreen.noResultsKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure, saved games under a banner',
      pump: (tester, theme) async {
        remote.onSearch = (_, _, _) async => throw unreachable();
        await showAudited(
          tester,
          theme,
          cache: FakeGamesCache([game('g_catan', title: 'Catan')]),
        );
      },
      arrange: (tester) async {
        await search(tester, 'catan');
        expect(find.byKey(GameSearchScreen.fromCacheBannerKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure',
      pump: (tester, theme) async {
        remote.onSearch = (_, _, _) async => throw unreachable();
        // No saved games to fall back on: an empty cache reads as no hits.
        await showAudited(tester, theme);
      },
      arrange: (tester) async {
        await search(tester, 'catan');
        expect(find.byKey(GameSearchScreen.errorKey), findsOneWidget);
      },
    );

    auditScreen(
      'denied',
      pump: (tester, theme) async {
        remote.onSearch = (_, _, _) async =>
            throw const GamesForbiddenException('403');
        await showAudited(tester, theme, cache: FakeGamesCache());
      },
      arrange: (tester) async {
        await search(tester, 'catan');
        expect(find.byKey(GameSearchScreen.deniedKey), findsOneWidget);
      },
    );

    // Offline, every row still opens its quick look, a read (#713): none is
    // dimmed, and none says it waits for the connection.
    auditScreen(
      'offline',
      pump: (tester, theme) async {
        final offline = ValueNotifier(true);
        addTearDown(offline.dispose);
        remote.onSearch = (_, _, _) async => results;
        await showAudited(tester, theme, offline: offline);
      },
      arrange: (tester) async {
        await search(tester, 'catan');
        expect(find.text(onlineOnlyCopy), findsNothing);
      },
    );

    auditScreen(
      'filter sheet',
      pump: (tester, theme) async {
        remote.onSearch = (_, _, _) async => const GameSearchResults();
        await showAudited(tester, theme);
      },
      arrange: (tester) async {
        await openFilters(tester);
        expect(find.byKey(GameSearchScreen.filterSheetKey), findsOneWidget);
      },
    );

    // Scrolled to its end, the sheet leaves a control half under its top
    // edge, which Flutter's tap-target check fails at its clipped size, a
    // limit of the tool (`docs/design/ACCESSIBILITY_AUDIT.md` §3). So the
    // sheet is audited in a view tall enough to hold it whole.
    auditScreen(
      'filter sheet, whole page',
      pump: (tester, theme) async {
        useViewSize(
          tester,
          Size(
            tester.view.physicalSize.width / tester.view.devicePixelRatio,
            6000,
          ),
        );
        remote.onSearch = (_, _, _) async => const GameSearchResults();
        await showAudited(tester, theme);
      },
      arrange: (tester) async {
        await openFilters(tester);
        final position = tester
            .state<ScrollableState>(sheetScrollable())
            .position;
        expect(position.maxScrollExtent, 0, reason: 'the sheet still scrolls');
        expect(
          find.byKey(GameSearchScreen.bandKey(GameLengthBand.values.last)),
          findsOneWidget,
        );
      },
    );
  });

  group('keyboard', () {
    late SemanticsHandle semantics;

    setUp(() => semantics = SemanticsBinding.instance.ensureSemantics());
    tearDown(() => semantics.dispose());

    /// Results in both sections, each row a control that opens its quick
    /// look.
    Future<void> showResults(WidgetTester tester) async {
      remote.onSearch = (_, _, _) async => results;
      await show(
        tester,
        sourceNames: () async => {'dg_bgg': 'BoardGameGeek'},
        onOpen: (_, _) {},
        access: mayImport(),
      );
      await search(tester, 'catan');
    }

    /// The order the screen reads in, top to bottom and start to end: the
    /// field and its clear button, the Filters button beside them, then this
    /// server's results and the data sources'. A data source's row reads the
    /// source's name under the title.
    const readingOrder = [
      'Search by title',
      'Clear search',
      'Filters',
      'Catan',
      'Catan: Seafarers\nBoardGameGeek',
      'Catan Junior\nBoardGameGeek',
    ];

    testWidgets('Tab follows reading order, Shift+Tab reverses it, and '
        'nothing traps focus', (tester) async {
      await showResults(tester);

      await expectTraversable(tester, expectedOrder: readingOrder);
    });

    testWidgets('the filter sheet, closed with Escape, gives focus back to '
        'the Filters button', (tester) async {
      await showResults(tester);

      await expectFocusReturnsAfterDialog(
        tester,
        opener: find.descendant(
          of: find.byKey(GameSearchScreen.filtersButtonKey),
          matching: find.byType(Text),
        ),
        dismiss: () async {
          expect(find.byKey(GameSearchScreen.filterSheetKey), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        },
      );
      expect(find.byKey(GameSearchScreen.filterSheetKey), findsNothing);
    });
  });
}

/// What a screen reader hears from the live regions in the semantics tree
/// (#795, #473), by the rule of each platform:
///
/// - **iOS** says a live region's words when it appears or becomes one, and
///   again when they change while it is one, hidden or not.
/// - **Android** says them by the same rule, but only while the node is not
///   marked hidden: words that came while it was hidden aren't said when it
///   shows, as they haven't changed by then (`BgePage.header`'s doc).
/// - **The web** says them when they differ from the last words that node
///   said, so a node that becomes a live region again with the same words
///   says nothing (`LiveRegion.update` in Flutter's web engine).
///
/// A live region that has left the tree, as one among a page's slivers does
/// past the cache extent, says nothing anywhere.
class _Heard {
  /// The live regions read last, by node id.
  Map<int, String> _live = const {};

  /// The last words each node said on the web, by node id.
  final Map<int, String> _saidOnWeb = {};

  /// Reads the live regions in the tree now, and returns what has been
  /// heard since the last read, in the order they sit on screen.
  ///
  /// Where the platforms hear different things it returns each, labelled,
  /// so that no test expecting one list passes.
  List<String> listen() {
    final nodes = [
      for (final node
          in find.semantics.byFlag(SemanticsFlag.isLiveRegion).evaluate())
        (id: node.id, data: node.getSemanticsData()),
    ];
    final ios = [
      for (final (:id, :data) in nodes)
        if (_live[id] != data.label) data.label,
    ];
    final android = [
      for (final (:id, :data) in nodes)
        if (_live[id] != data.label && !data.flagsCollection.isHidden)
          data.label,
    ];
    final web = [
      for (final (:id, :data) in nodes)
        if (_saidOnWeb[id] != data.label) data.label,
    ];
    _live = {for (final (:id, :data) in nodes) id: data.label};
    _saidOnWeb.addAll(_live);
    return listEquals(ios, android) && listEquals(ios, web)
        ? ios
        : ['Android: $android', 'iOS: $ios', 'web: $web'];
  }
}

/// A [GameSearchStreamSource] that records each channel it opens (#473).
///
/// Each [open] hands out [channel], or a new [FakeGameSearchChannel] where
/// there is none. A source whose session's connection has [closed] throws
/// [StateError] instead, as the real one does.
class _StreamSource implements GameSearchStreamSource {
  _StreamSource({this.channel, this.closed = false});

  final FakeGameSearchChannel? channel;
  final bool closed;

  /// Every channel opened, in order.
  final List<FakeGameSearchChannel> opened = [];

  @override
  GameSearchChannel open() {
    if (closed) throw StateError("The session's connection has closed.");
    final opening = channel ?? FakeGameSearchChannel();
    opened.add(opening);
    return opening;
  }
}
