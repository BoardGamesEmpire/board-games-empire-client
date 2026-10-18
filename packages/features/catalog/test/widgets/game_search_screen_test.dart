import 'package:flutter/material.dart';
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

  testWidgets('a filter chip searches again, narrowed', (tester) async {
    remote.onSearch = (_, _) async => const GameSearchResults();

    await show(tester);
    await search(tester, 'catan');
    await tester.tap(
      find.byKey(GameSearchScreen.filterKey(ContentType.expansion)),
    );
    await tester.pumpAndSettle();

    expect(remote.calls, ['search(catan)', 'search(catan [expansion])']);
    expect(find.byKey(GameSearchScreen.noResultsKey), findsOneWidget);
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
