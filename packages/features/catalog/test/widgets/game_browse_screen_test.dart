import 'dart:async';

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

  final azul = Game(
    id: 'g_azul',
    title: 'Azul',
    publishYear: 2017,
    minPlayers: 2,
    maxPlayers: 4,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  final seafarers = game(
    'g_seafarers',
    title: 'Catan',
    contentType: ContentType.expansion,
  ).copyWith(subtitle: 'Seafarers');

  Future<void> show(
    WidgetTester tester, {
    FakeGamesCache? cache,
    Future<bool> Function(BuildContext context, String gameId)? onOpen,
    void Function(BuildContext context)? onSearch,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        GameBrowseScreen(
          remote: remote,
          cache: cache,
          onOpen: onOpen,
          onSearch: onSearch,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the first page, each row with its facts', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([azul, seafarers]);

    await show(tester);

    expect(find.text('Azul'), findsOneWidget);
    expect(find.text('2017 · 2–4 players'), findsOneWidget);
    expect(find.text('Catan: Seafarers'), findsOneWidget);
    // A base game says nothing about its type; anything else does.
    expect(find.text('Expansion'), findsOneWidget);
  });

  testWidgets('reads a row the way it is meant to be heard', (tester) async {
    final handle = tester.ensureSemantics();
    remote.onFetchPage = (_, _) async => pageOf([azul]);

    await show(tester);

    expect(
      tester.getSemantics(find.byKey(GameBrowseScreen.rowKey('g_azul'))),
      isSemantics(label: 'Azul\n2017, 2 to 4 players'),
    );
    handle.dispose();
  });

  testWidgets('a row opens its game', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([azul]);
    final opened = <String>[];

    await show(
      tester,
      onOpen: (_, id) async {
        opened.add(id);
        return false;
      },
    );
    await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_azul')));
    await tester.pumpAndSettle();

    expect(opened, ['g_azul']);
    expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsOneWidget);
  });

  testWidgets('a game found gone is taken down when the user comes back', (
    tester,
  ) async {
    remote.onFetchPage = (_, _) async => pageOf([azul, seafarers]);

    await show(tester, onOpen: (_, _) async => true);
    await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_azul')));
    await tester.pumpAndSettle();

    expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsNothing);
    expect(find.byKey(GameBrowseScreen.rowKey('g_seafarers')), findsOneWidget);
  });

  testWidgets('a list emptied by games found gone still offers the next page', (
    tester,
  ) async {
    remote.onFetchPage = (page, _) async => page == 1
        ? pageOf([azul], hasMore: true)
        : pageOf([seafarers], page: 2);

    await show(tester, onOpen: (_, _) async => true);
    await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_azul')));
    await tester.pumpAndSettle();

    expect(find.byKey(GameBrowseScreen.emptyKey), findsNothing);
    await tester.tap(find.byKey(GameBrowseScreen.moreKey));
    await tester.pumpAndSettle();

    expect(find.text('Catan: Seafarers'), findsOneWidget);
  });

  testWidgets('loads the next page from the button at the end', (tester) async {
    remote.onFetchPage = (page, _) async => page == 1
        ? pageOf([azul], hasMore: true)
        : pageOf([seafarers], page: 2);

    await show(tester);
    await tester.tap(find.byKey(GameBrowseScreen.moreKey));
    await tester.pumpAndSettle();

    expect(find.text('Catan: Seafarers'), findsOneWidget);
    // The end of the catalog offers nothing more.
    expect(find.byKey(GameBrowseScreen.moreKey), findsNothing);
  });

  testWidgets('counts the loaded rows for a screen reader', (tester) async {
    remote.onFetchPage = (_, _) async =>
        pageOf([azul, seafarers], hasMore: true);

    await show(tester);

    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollView.semanticChildCount, 2);
  });

  testWidgets(
    'when the server fails, shows the saved games under a banner with a retry',
    (tester) async {
      remote.onFetchPage = (_, _) async => throw unreachable();

      await show(tester, cache: FakeGamesCache([azul]));

      expect(find.byKey(GameBrowseScreen.fromCacheBannerKey), findsOneWidget);
      expect(find.text('Azul'), findsOneWidget);

      remote.onFetchPage = (_, _) async => pageOf([seafarers]);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.byKey(GameBrowseScreen.fromCacheBannerKey), findsNothing);
      expect(find.text('Catan: Seafarers'), findsOneWidget);
    },
  );

  testWidgets('while a retry asks the server, the banner says so, and the '
      'saved games stay up whatever it answers', (tester) async {
    remote.onFetchPage = (_, _) async => throw unreachable();
    await show(tester, cache: FakeGamesCache([azul]));

    final answer = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => answer.future;
    await tester.tap(find.text('Try again'));
    await tester.pump();

    final retrying = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Trying again…'),
    );
    expect(retrying.onPressed, isNull);
    expect(find.text('Azul'), findsOneWidget);

    answer.completeError(unreachable());
    await tester.pumpAndSettle();

    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Azul'), findsOneWidget);
  });

  testWidgets('with nothing saved, a failure is an error with a retry', (
    tester,
  ) async {
    remote.onFetchPage = (_, _) async => throw unreachable();

    await show(tester, cache: FakeGamesCache());

    expect(find.byKey(GameBrowseScreen.errorKey), findsOneWidget);
  });

  testWidgets('a refusal says the user has no access, and shows nothing '
      'saved', (tester) async {
    remote.onFetchPage = (_, _) async =>
        throw const GamesForbiddenException('403');

    await show(tester, cache: FakeGamesCache([azul]));

    expect(find.byKey(GameBrowseScreen.deniedKey), findsOneWidget);
    expect(find.text('Azul'), findsNothing);
  });

  testWidgets('an empty catalog says so', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([]);

    await show(tester);

    expect(find.byKey(GameBrowseScreen.emptyKey), findsOneWidget);
  });

  testWidgets('offers search only where there is one to open', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([]);
    var searched = 0;

    await show(tester);
    expect(find.byKey(GameBrowseScreen.searchKey), findsNothing);

    await show(tester, onSearch: (_) => searched++);
    await tester.tap(find.byKey(GameBrowseScreen.searchKey));

    expect(searched, 1);
  });
}
