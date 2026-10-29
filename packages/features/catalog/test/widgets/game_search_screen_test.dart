import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/catalog_app.dart';
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
    void Function(BuildContext context, String sourceId, GameSearchHit hit)?
    onImport,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        GameSearchScreen(
          remote: remote,
          cache: cache,
          sourceNames: sourceNames,
          gone: gone,
          onOpen: onOpen,
          onImport: onImport,
        ),
      ),
    );
    await tester.pump();
  }

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

  testWidgets('shows this server first, then what data sources found', (
    tester,
  ) async {
    remote.onSearch = (_, _) async => results;

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

  testWidgets('announces the result count when results arrive', (tester) async {
    final handle = tester.ensureSemantics();
    remote.onSearch = (_, _) async => results;

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
    remote.onSearch = (_, _) async => results;

    await show(tester);
    await search(tester, 'catan');

    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollView.semanticChildCount, 3);
  });

  testWidgets('a game the server holds opens, from either section', (
    tester,
  ) async {
    remote.onSearch = (_, _) async => results;
    final opened = <String>[];

    await show(tester, onOpen: (_, id) => opened.add(id));
    await search(tester, 'catan');
    await tester.tap(find.byKey(GameSearchScreen.serverRowKey('g_catan')));
    await tester.tap(find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '1')));

    expect(opened, ['g_catan', 'g_imported']);
  });

  testWidgets('a game found gone is taken down', (tester) async {
    remote.onSearch = (_, _) async => results;
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

  testWidgets('a game the server does not hold goes to the import', (
    tester,
  ) async {
    remote.onSearch = (_, _) async => results;
    final imported = <String>[];

    await show(
      tester,
      onImport: (_, sourceId, hit) =>
          imported.add('$sourceId/${hit.externalId}'),
    );
    await search(tester, 'catan');
    await tester.tap(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
    );

    expect(imported, ['dg_bgg/926']);
  });

  // An import runs while its dialog is open, and the results can change
  // beneath it: the context it is given must outlive the row.
  testWidgets("the import's context is the screen's, not the row's", (
    tester,
  ) async {
    remote.onSearch = (_, _) async => results;
    BuildContext? importedFrom;

    await show(tester, onImport: (context, _, _) => importedFrom = context);
    await search(tester, 'catan');
    await tester.tap(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
    );
    remote.onSearch = (_, _) async => const GameSearchResults();
    await search(tester, 'zzz');

    expect(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
      findsNothing,
    );
    expect(importedFrom?.mounted, isTrue);
  });

  testWidgets('without an import, that row is content, not a control', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    remote.onSearch = (_, _) async => results;

    await show(tester, onOpen: (_, _) {});
    await search(tester, 'catan');

    expect(
      tester.getSemantics(
        find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
      ),
      isSemantics(hasTapAction: false, isFocusable: false),
    );
    handle.dispose();
  });

  group('the data sources that did not answer', () {
    testWidgets('are counted where they cannot be named', (tester) async {
      remote.onSearch = (_, _) async => results;

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
      remote.onSearch = (_, _) async => results;

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
      remote.onSearch = (_, filter) async => GameSearchResults(
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
      remote.onSearch = (_, _) async => const GameSearchResults(
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
    setUp(() => remote.onSearch = (_, _) async => const GameSearchResults());

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
    remote.onSearch = (_, _) async =>
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
    remote.onSearch = (_, _) async => throw unreachable();

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
    setUp(() => remote.onSearch = (_, _) async => const GameSearchResults());

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
    setUp(() => remote.onSearch = (_, _) async => const GameSearchResults());

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
      remote.onSearch = (_, _) async => throw unreachable();

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

  testWidgets('a refusal says the user has no access, and searches nothing '
      'saved', (tester) async {
    remote.onSearch = (_, _) async =>
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
    remote.onSearch = (_, _) async => results;

    await show(tester);
    await search(tester, 'catan');
    await tester.tap(find.byKey(GameSearchScreen.clearKey));
    await tester.pump(GameSearchBloc.defaultDebounce);
    await tester.pumpAndSettle();

    expect(find.byKey(GameSearchScreen.idleKey), findsOneWidget);
  });
}
