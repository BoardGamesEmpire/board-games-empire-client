import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
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
import 'package:ui_tokens/ui_tokens.dart';

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
    Stream<String>? gone,
    void Function(BuildContext context, String gameId)? onOpen,
    void Function(BuildContext context)? onSearch,
    GameSort initialSort = GameSort.title,
    ListLayoutRepository? layouts,
    void Function(BuildContext context, GameQuickLookSeed seed)? onQuickLook,
    bool settle = true,
    ThemeData? theme,
    TransitionBuilder? builder,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        theme: theme,
        builder: builder,
        GameBrowseScreen(
          remote: remote,
          cache: cache,
          gone: gone,
          onOpen: onOpen,
          onSearch: onSearch,
          layouts: layouts,
          onQuickLook: onQuickLook,
          initialSort: initialSort,
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  /// Opens the sort menu and picks [label] from it.
  ///
  /// The menu hands over its choice after the first frame, and the bloc's
  /// state draws in the next.
  Future<void> chooseSort(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(GameBrowseScreen.sortKey));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, label).hitTestable());
    await tester.pump();
    await tester.pump();
  }

  /// The order the server was last asked for.
  String lastRead() => remote.calls.last;

  testWidgets('lists the first page, each row with its facts', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([azul, seafarers]);

    await show(tester);

    expect(find.text('Azul'), findsOneWidget);
    expect(find.text('2017 · 2–4 players'), findsOneWidget);
    expect(find.text('Catan: Seafarers'), findsOneWidget);
    // A base game says nothing about its type; anything else does.
    expect(find.text('Expansion'), findsOneWidget);
  });

  testWidgets('every game row is outlined (#647)', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([azul, seafarers]);

    await show(tester);

    expect(find.byType(BgeOutlinedRow), findsNWidgets(2));
    for (final id in ['g_azul', 'g_seafarers']) {
      expect(
        find.descendant(
          of: find.byKey(GameBrowseScreen.rowKey(id)),
          matching: find.byType(BgeOutlinedRow),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('a row sets its thumbnail by text scale (#647)', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([azul]);

    Future<ListTileTitleAlignment?> alignmentAt(double scale) async {
      await show(
        tester,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      );
      return tester
          .widget<ListTile>(
            find.descendant(
              of: find.byKey(GameBrowseScreen.rowKey('g_azul')),
              matching: find.byType(ListTile),
            ),
          )
          .titleAlignment;
    }

    expect(await alignmentAt(1), ListTileTitleAlignment.top);
    expect(await alignmentAt(2), ListTileTitleAlignment.titleHeight);
  });

  testWidgets('reads a row the way it is meant to be heard', (tester) async {
    final handle = tester.ensureSemantics();
    remote.onFetchPage = (_, _) async => pageOf([azul]);

    await show(tester);

    expect(
      tester.getSemantics(
        find.descendant(
          of: find.byKey(GameBrowseScreen.rowKey('g_azul')),
          matching: find.byType(MergeSemantics),
        ),
      ),
      isSemantics(label: 'Azul\n2017, 2 to 4 players'),
    );
    handle.dispose();
  });

  testWidgets('a row opens its game', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([azul]);
    final opened = <String>[];

    await show(tester, onOpen: (_, id) => opened.add(id));
    await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_azul')));

    expect(opened, ['g_azul']);
  });

  testWidgets('a game found gone is taken down', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf([azul, seafarers]);
    final gone = StreamController<String>.broadcast();
    addTearDown(gone.close);

    await show(tester, gone: gone.stream);
    gone.add('g_azul');
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
    final gone = StreamController<String>.broadcast();
    addTearDown(gone.close);

    await show(tester, gone: gone.stream);
    gone.add('g_azul');
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

  testWidgets('while a retry asks the server, the banner says so, the retry '
      'keeps focus and asks once, and the saved games stay up whatever it '
      'answers (#607)', (tester) async {
    remote.onFetchPage = (_, _) async => throw unreachable();
    await show(tester, cache: FakeGamesCache([azul]));

    var asks = 0;
    final answer = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) {
      asks++;
      return answer.future;
    };
    final retry = find.descendant(
      of: find.byKey(GameBrowseScreen.fromCacheBannerKey),
      matching: find.byType(TextButton),
    );
    final focus = tester.widget<TextButton>(retry).focusNode!..requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // The banner's message and the retry's label.
    expect(find.text('Trying again…'), findsNWidgets(2));
    expect(focus.hasPrimaryFocus, isTrue);
    expect(find.text('Azul'), findsOneWidget);

    await tester.tap(retry);
    await tester.pump();
    expect(asks, 1);

    answer.completeError(unreachable());
    await tester.pumpAndSettle();

    expect(find.text('Try again'), findsOneWidget);
    expect(focus.hasPrimaryFocus, isTrue);
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

  testWidgets('browse empty is announced', (tester) async {
    final handle = tester.ensureSemantics();
    remote.onFetchPage = (_, _) async => pageOf([]);

    await show(tester);

    final message = tester.getSemantics(
      find.text('There are no games on this server yet.'),
    );
    expect(message, isSemantics(isLiveRegion: true));
    expect(message.label, contains('There are no games on this server yet.'));
    handle.dispose();
  });

  group('expansions (#711)', () {
    ExpansionLink under(String id, {bool standalone = false}) =>
        ExpansionLink(gameId: id, isStandalone: standalone);

    final base = game('B');
    Game expansion(String id, List<ExpansionLink> links) =>
        game(id, contentType: ContentType.expansion, baseGames: links);

    Finder row(String key) => find.byKey(GameBrowseScreen.rowKey(key));
    Finder nested(String parent, String id) =>
        find.byKey(GameBrowseScreen.nestedRowKey(parent, id));

    /// The control at the end of base game [id]'s row, which folds and
    /// unfolds its expansions (#1048).
    Finder controlOf(String id) => find.descendant(
      of: row(id),
      matching: find.byType(BgeRowExpansionsControl),
    );

    /// Shows base game [id]'s expansions, from its row's control: every base
    /// game starts folded (#1048).
    Future<void> unfold(WidgetTester tester, String id) async {
      await tester.ensureVisible(controlOf(id));
      await tester.pumpAndSettle();
      await tester.tap(controlOf(id));
      await tester.pumpAndSettle();
    }

    testWidgets("an expansion's row sits under its base game's, indented", (
      tester,
    ) async {
      remote.onFetchPage = (_, _) async => pageOf([
        base,
        expansion('E', [under('B')]),
      ]);

      await show(tester);
      await unfold(tester, 'B');

      expect(row('B'), findsOneWidget);
      expect(nested('B', 'E'), findsOneWidget);
      expect(row('E'), findsNothing);
      expect(
        tester.getTopLeft(row('B')).dy,
        lessThan(tester.getTopLeft(nested('B', 'E')).dy),
      );
      double start(Finder row) => tester
          .getTopLeft(find.descendant(of: row, matching: find.byType(ListTile)))
          .dx;
      expect(start(nested('B', 'E')), greaterThan(start(row('B'))));
    });

    testWidgets("a nested expansion row's outline starts at the indent "
        '(#647)', (tester) async {
      remote.onFetchPage = (_, _) async => pageOf([
        base,
        expansion('E', [under('B')]),
      ]);

      await show(tester);
      await unfold(tester, 'B');

      double outlineStart(Finder row) => tester
          .getTopLeft(
            find.descendant(of: row, matching: find.byType(BgeOutlinedRow)),
          )
          .dx;
      expect(
        outlineStart(nested('B', 'E')),
        outlineStart(row('B')) + BgeTokens.standard.spaceLg,
      );
    });

    testWidgets('a nested row is spoken as an expansion of its base game', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      remote.onFetchPage = (_, _) async => pageOf([
        base,
        expansion('E', [under('B')]),
      ]);

      await show(tester);
      await unfold(tester, 'B');

      expect(
        tester
            .getSemantics(
              find.descendant(
                of: nested('B', 'E'),
                matching: find.byType(ListTile),
              ),
            )
            .label,
        contains('Game E, expansion for Game B'),
      );
      handle.dispose();
    });

    testWidgets('an expansion under two base games is under each', (
      tester,
    ) async {
      remote.onFetchPage = (_, _) async => pageOf([
        base,
        game('C'),
        expansion('E', [under('B'), under('C')]),
      ]);

      await show(tester);
      await unfold(tester, 'B');
      await unfold(tester, 'C');

      expect(nested('B', 'E'), findsOneWidget);
      expect(nested('C', 'E'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets("a focused nested row scrolled out of the list doesn't move "
        "focus to its game's other copy (#819)", (tester) async {
      // B at the top and C at the end, with E under each: more than a
      // screen and the list's cache apart.
      remote.onFetchPage = (_, _) async => pageOf([
        base,
        for (var i = 0; i < 30; i++) game('F$i'),
        game('C'),
        expansion('E', [under('B'), under('C')]),
      ]);
      await show(tester, onOpen: (_, _) {});
      // Both unfolded: C first, at the end, then B, at the top.
      await scrollListToEnd(tester, row('C'));
      await unfold(tester, 'C');
      _pagePosition(tester).jumpTo(0);
      await tester.pumpAndSettle();
      await unfold(tester, 'B');
      final near = find.byKey(
        GameBrowseScreen.nestedRowKey('B', 'E'),
        skipOffstage: false,
      );
      final far = find.byKey(
        GameBrowseScreen.nestedRowKey('C', 'E'),
        skipOffstage: false,
      );
      expect(far, findsNothing);
      // The row's ink's own node.
      Focus.of(
        tester.element(
          find
              .descendant(
                of: find.descendant(of: near, matching: find.byType(InkWell)),
                matching: find.byType(MouseRegion),
              )
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      expect(_focusIsWithin(tester, near), isTrue);

      await scrollListToEnd(tester, far);

      expect(near, findsNothing);
      expect(_focusIsWithin(tester, far), isFalse);
    });

    testWidgets('a standalone expansion also has its own row', (tester) async {
      remote.onFetchPage = (_, _) async => pageOf([
        base,
        expansion('E', [under('B', standalone: true)]),
      ]);

      await show(tester);
      await unfold(tester, 'B');

      expect(nested('B', 'E'), findsOneWidget);
      expect(row('E'), findsOneWidget);
      expect(find.text('Base game not on this server'), findsNothing);
    });

    testWidgets(
      "an expansion whose base game isn't loaded waits, and shows marked "
      'when the list ends',
      (tester) async {
        final handle = tester.ensureSemantics();
        remote.onFetchPage = (page, _) async => page == 1
            ? pageOf([
                game('A'),
                expansion('E', [under('B')]),
              ], hasMore: true)
            : pageOf(const [], page: 2);

        await show(tester);

        expect(row('E'), findsNothing);
        expect(find.text('Game E'), findsNothing);

        await tester.tap(find.byKey(GameBrowseScreen.moreKey));
        await tester.pumpAndSettle();

        expect(row('E'), findsOneWidget);
        expect(
          find.descendant(
            of: row('E'),
            matching: find.text('Base game not on this server'),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .getSemantics(
                find.descendant(
                  of: row('E'),
                  matching: find.byType(MergeSemantics),
                ),
              )
              .label,
          contains('Base game not on this server'),
        );
        handle.dispose();
      },
    );

    testWidgets(
      "the base game's page arriving puts the waiting expansion under it",
      (tester) async {
        remote.onFetchPage = (page, _) async => page == 1
            ? pageOf([
                game('A'),
                expansion('E', [under('B')]),
              ], hasMore: true)
            : pageOf([base], page: 2);

        await show(tester);
        await tester.tap(find.byKey(GameBrowseScreen.moreKey));
        await tester.pumpAndSettle();
        await unfold(tester, 'B');

        expect(nested('B', 'E'), findsOneWidget);
        expect(row('E'), findsNothing);
      },
    );

    testWidgets(
      'a first page with every game waiting reads the next one itself',
      (tester) async {
        remote.onFetchPage = (page, _) async => page == 1
            ? pageOf([
                expansion('E', [under('B')]),
              ], hasMore: true)
            : pageOf([base], page: 2);

        await show(tester);
        expect(remote.calls, hasLength(2));
        await unfold(tester, 'B');

        expect(nested('B', 'E'), findsOneWidget);
      },
    );

    testWidgets('a next page with every game waiting reads on until one shows '
        'something', (tester) async {
      remote.onFetchPage = (page, _) async => switch (page) {
        1 => pageOf([game('A')], hasMore: true),
        2 => pageOf(
          [
            expansion('E', [under('B')]),
          ],
          page: 2,
          hasMore: true,
        ),
        3 => pageOf([base, game('C')], page: 3, hasMore: true),
        _ => throw unreachable(),
      };

      await show(tester);
      await tester.tap(find.byKey(GameBrowseScreen.moreKey));
      await tester.pumpAndSettle();

      expect(row('C'), findsOneWidget);
      // Page 3 showed something, so the list waits for the next press.
      expect(remote.calls, hasLength(3));
      expect(find.byKey(GameBrowseScreen.moreKey), findsOneWidget);
      await unfold(tester, 'B');
      expect(nested('B', 'E'), findsOneWidget);
    });

    // A folded base game shows a page's expansions only as a higher count
    // on its control, as a folded cover does on its badge (#1048).
    testWidgets('a next page that only adds expansions under a folded base '
        'game reads on until a row shows', (tester) async {
      remote.onFetchPage = (page, _) async => switch (page) {
        1 => pageOf([base], hasMore: true),
        2 => pageOf(
          [
            expansion('E', [under('B')]),
          ],
          page: 2,
          hasMore: true,
        ),
        3 => pageOf([game('C')], page: 3, hasMore: true),
        _ => throw unreachable(),
      };

      await show(tester);
      await tester.tap(find.byKey(GameBrowseScreen.moreKey));
      await tester.pumpAndSettle();

      expect(row('C'), findsOneWidget);
      expect(
        find.descendant(of: controlOf('B'), matching: find.text('1')),
        findsOneWidget,
      );
      expect(nested('B', 'E'), findsNothing);
      // Page 3 showed a row, so the list waits for the next press.
      expect(remote.calls, hasLength(3));
      expect(find.byKey(GameBrowseScreen.moreKey), findsOneWidget);
    });

    testWidgets('a failed read of the next page stops reading on', (
      tester,
    ) async {
      remote.onFetchPage = (page, _) async => page == 1
          ? pageOf([
              expansion('E', [under('B')]),
            ], hasMore: true)
          : throw unreachable();

      await show(tester);

      expect(find.byKey(GameBrowseScreen.moreFailedKey), findsOneWidget);
      expect(remote.calls, hasLength(2));
    });

    testWidgets(
      "offline, an expansion whose base game wasn't saved says so, not that "
      "it isn't on the server",
      (tester) async {
        final handle = tester.ensureSemantics();
        remote.onFetchPage = (_, _) async => throw unreachable();

        await show(
          tester,
          cache: FakeGamesCache([
            expansion('E', [under('B')]),
            expansion('U', const []),
          ]),
        );

        expect(
          tester
              .getSemantics(
                find.descendant(
                  of: row('E'),
                  matching: find.byType(MergeSemantics),
                ),
              )
              .label,
          contains('Base game not saved on this device'),
        );
        expect(
          find.descendant(
            of: row('E'),
            matching: find.text('Base game not on this server'),
          ),
          findsNothing,
        );
        // With no link at all, the server has no base game for it.
        expect(
          find.descendant(
            of: row('U'),
            matching: find.text('Base game not on this server'),
          ),
          findsOneWidget,
        );
        handle.dispose();
      },
    );

    testWidgets('an unlinked expansion is top level and marked at once', (
      tester,
    ) async {
      remote.onFetchPage = (_, _) async =>
          pageOf([expansion('E', const [])], hasMore: true);

      await show(tester);

      expect(
        find.descendant(
          of: row('E'),
          matching: find.text('Base game not on this server'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the semantic child count counts the rows shown: nested ones '
        'while their base game is open, and a box once (#1048)', (
      tester,
    ) async {
      remote.onFetchPage = (_, _) async => pageOf([
        base,
        game('C'),
        expansion('E', [under('B'), under('C')]),
        game('D'),
        for (var i = 0; i < 6; i++) expansion('D$i', [under('D')]),
      ]);
      int? count() => tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount;

      await show(tester);
      expect(count(), 3, reason: 'all folded');

      await unfold(tester, 'B');
      await unfold(tester, 'C');
      expect(count(), 5, reason: 'B and C open, a row under each');

      await unfold(tester, 'D');
      expect(find.byType(BgeNestedRowsBox), findsOneWidget);
      expect(count(), 6, reason: "D's six in one box");
    });

    group('folded in the list (#1048)', () {
      /// [count] expansions of base game [id]: `<id>0`, `<id>1`, and on.
      List<Game> expansionsOf(String id, int count) => [
        for (var i = 0; i < count; i++) expansion('$id$i', [under(id)]),
      ];

      /// Rows and controls found whether or not they are in view.
      Finder anyRow(String id) =>
          find.byKey(GameBrowseScreen.rowKey(id), skipOffstage: false);
      Finder anyNested(String parent, String id) => find.byKey(
        GameBrowseScreen.nestedRowKey(parent, id),
        skipOffstage: false,
      );
      Finder anyControlOf(String id) => find.descendant(
        of: anyRow(id),
        matching: find.byType(BgeRowExpansionsControl),
        skipOffstage: false,
      );
      final box = find.byType(BgeNestedRowsBox, skipOffstage: false);

      /// The control's own node: the ink inside it walks up to it.
      SemanticsNode controlNode(WidgetTester tester, String id) =>
          tester.getSemantics(
            find.descendant(
              of: anyControlOf(id),
              matching: find.byType(InkWell),
              skipOffstage: false,
            ),
          );

      /// The row's merged node, which its tile walks up to.
      SemanticsNode rowNode(WidgetTester tester, String id) =>
          tester.getSemantics(
            find.descendant(
              of: anyRow(id),
              matching: find.byType(ListTile),
              skipOffstage: false,
            ),
          );

      /// The focus of [row]'s tile.
      FocusNode tileFocusOf(WidgetTester tester, Finder row) => tester
          .widget<ListTile>(
            find.descendant(
              of: row,
              matching: find.byType(ListTile),
              skipOffstage: false,
            ),
          )
          .focusNode!;

      void performCustomAction(SemanticsNode node, String label) =>
          node.owner!.performAction(
            node.id,
            SemanticsAction.customAction,
            CustomSemanticsAction.getIdentifier(
              CustomSemanticsAction(label: label),
            ),
          );

      Matcher isControl(String label, {required bool expanded}) => isSemantics(
        label: label,
        isButton: true,
        hasExpandedState: true,
        isExpanded: expanded,
        hasTapAction: true,
        isFocusable: true,
      );

      testWidgets('list starts folded: a base game shows its control and no '
          'nested rows', (tester) async {
        final handle = tester.ensureSemantics();
        remote.onFetchPage = (_, _) async =>
            pageOf([base, ...expansionsOf('B', 2), game('C')]);

        await show(tester, onOpen: (_, _) {});

        expect(row('B'), findsOneWidget);
        expect(row('C'), findsOneWidget);
        expect(anyNested('B', 'B0'), findsNothing);
        expect(anyNested('B', 'B1'), findsNothing);
        expect(row('B0'), findsNothing);
        expect(
          find.descendant(of: controlOf('B'), matching: find.text('2')),
          findsOneWidget,
        );
        expect(
          controlNode(tester, 'B'),
          isControl('Game B expansions, 2', expanded: false),
        );
        expect(controlOf('C'), findsNothing);
        // The control is a node of its own, after the row's, and the row
        // offers the cover's custom action.
        expect(rowNode(tester, 'B').id, isNot(controlNode(tester, 'B').id));
        expect(
          rowNode(tester, 'B'),
          isSemantics(
            hasTapAction: true,
            customActions: [
              const CustomSemanticsAction(label: 'Show expansions'),
            ],
          ),
        );
        expect(
          tester
              .widget<CustomScrollView>(find.byType(CustomScrollView))
              .semanticChildCount,
          2,
        );
        handle.dispose();
      });

      testWidgets('unfolding 2 shows them inline; unfolding 6 shows a box of '
          '6', (tester) async {
        final handle = tester.ensureSemantics();
        useViewSize(tester, const Size(400, 1600));
        remote.onFetchPage = (_, _) async => pageOf([
          base,
          ...expansionsOf('B', 2),
          game('C'),
          ...expansionsOf('C', 6),
        ]);
        await show(tester, onOpen: (_, _) {});

        await unfold(tester, 'B');

        for (final id in ['B0', 'B1']) {
          expect(nested('B', id), findsOneWidget, reason: id);
        }
        expect(box, findsNothing);
        expect(
          controlNode(tester, 'B'),
          isControl('Game B expansions, 2', expanded: true),
        );
        expect(
          rowNode(tester, 'B'),
          isSemantics(
            hasTapAction: true,
            customActions: [
              const CustomSemanticsAction(label: 'Hide expansions'),
            ],
          ),
        );
        // Under B's row, and above C's.
        expect(
          tester.getRect(nested('B', 'B1')).bottom,
          lessThanOrEqualTo(tester.getRect(row('C')).top),
        );

        await unfold(tester, 'C');

        expect(box, findsOneWidget);
        expect(
          tester.widget<BgeNestedRowsBox>(box).semanticLabel,
          'Game C expansions',
        );
        for (var i = 0; i < 6; i++) {
          expect(
            find.descendant(of: box, matching: anyNested('C', 'C$i')),
            findsOneWidget,
            reason: 'C$i',
          );
        }
        // B stays open.
        expect(nested('B', 'B0'), findsOneWidget);
        expect(
          controlNode(tester, 'C'),
          isControl('Game C expansions, 6', expanded: true),
        );
        handle.dispose();
      });

      testWidgets('two base games open at once', (tester) async {
        remote.onFetchPage = (_, _) async => pageOf([
          base,
          ...expansionsOf('B', 1),
          game('C'),
          ...expansionsOf('C', 1),
        ]);
        await show(tester, onOpen: (_, _) {});

        await unfold(tester, 'B');
        await unfold(tester, 'C');

        expect(nested('B', 'B0'), findsOneWidget);
        expect(nested('C', 'C0'), findsOneWidget);

        // Folding one leaves the other open.
        await unfold(tester, 'B');
        expect(nested('B', 'B0'), findsNothing);
        expect(nested('C', 'C0'), findsOneWidget);
      });

      testWidgets('open stays open as the next page arrives', (tester) async {
        final handle = tester.ensureSemantics();
        remote.onFetchPage = (page, _) async => page == 1
            ? pageOf([base, ...expansionsOf('B', 1)], hasMore: true)
            : pageOf([
                expansion('B1', [under('B')]),
                game('C'),
              ], page: 2);
        await show(tester, onOpen: (_, _) {});
        await unfold(tester, 'B');

        await tester.ensureVisible(find.byKey(GameBrowseScreen.moreKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(GameBrowseScreen.moreKey));
        await tester.pumpAndSettle();

        expect(row('C'), findsOneWidget);
        expect(anyNested('B', 'B0'), findsOneWidget);
        expect(anyNested('B', 'B1'), findsOneWidget);
        expect(
          controlNode(tester, 'B'),
          isControl('Game B expansions, 2', expanded: true),
        );
        handle.dispose();
      });

      testWidgets("a held expansion isn't counted until its base game's page "
          'places it (#711)', (tester) async {
        // H waits for C, on page 2. B's count grows there too, folded.
        remote.onFetchPage = (page, _) async => page == 1
            ? pageOf([
                base,
                ...expansionsOf('B', 1),
                expansion('H', [under('C')]),
              ], hasMore: true)
            : pageOf([
                game('C'),
                expansion('B1', [under('B')]),
              ], page: 2);
        Finder countOn(String id, String count) =>
            find.descendant(of: controlOf(id), matching: find.text(count));
        await show(tester, onOpen: (_, _) {});

        expect(countOn('B', '1'), findsOneWidget);
        expect(find.text('Game H'), findsNothing);
        expect(row('C'), findsNothing);

        await tester.tap(find.byKey(GameBrowseScreen.moreKey));
        await tester.pumpAndSettle();

        expect(countOn('B', '2'), findsOneWidget);
        expect(countOn('C', '1'), findsOneWidget);
        // Both still folded.
        expect(find.text('Game H'), findsNothing);
        expect(anyNested('B', 'B0'), findsNothing);
        expect(row('H'), findsNothing);
      });

      testWidgets('folding with focus on a nested row focuses the base '
          "game's control", (tester) async {
        final handle = tester.ensureSemantics();
        remote.onFetchPage = (_, _) async =>
            pageOf([base, ...expansionsOf('B', 2), game('C')]);
        await show(tester, onOpen: (_, _) {});
        await unfold(tester, 'B');
        // By way of C's row, so the control the page focused before the
        // nested row is that row, not B's control, which the unfold's tap
        // focused, and where the framework would put focus anyway.
        tileFocusOf(tester, row('C')).requestFocus();
        await tester.pump();
        final tile = tileFocusOf(tester, nested('B', 'B1'))..requestFocus();
        await tester.pump();
        expect(tile.hasPrimaryFocus, isTrue);

        // A screen reader on the base game's row folds it, as its custom
        // action.
        performCustomAction(rowNode(tester, 'B'), 'Hide expansions');
        await tester.pumpAndSettle();

        expect(anyNested('B', 'B1'), findsNothing);
        expect(_focusIsWithin(tester, controlOf('B')), isTrue);
        expect(
          controlNode(tester, 'B'),
          isSemantics(
            label: 'Game B expansions, 2',
            isButton: true,
            hasExpandedState: true,
            isExpanded: false,
            hasTapAction: true,
            isFocusable: true,
            isFocused: true,
          ),
        );
        handle.dispose();
      });

      // Where the box is held to half the page: at 2.0 in landscape, a row
      // is taller than that (#1048).
      testWidgets('folding with focus inside the box focuses the base '
          "game's control, at 320 dp × 2.0 in landscape, and the page still "
          'drags', (tester) async {
        final handle = tester.ensureSemantics();
        useViewSize(tester, const Size(568, 320));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        remote.onFetchPage = (_, _) async => pageOf([
          base,
          ...expansionsOf('B', 6),
          for (var i = 0; i < 4; i++) game('F$i'),
        ]);
        await show(tester, onOpen: (_, _) {});
        await unfold(tester, 'B');

        final page = _pagePosition(tester);
        ScrollPosition rows() => tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: box,
                    matching: find.byType(Scrollable),
                    skipOffstage: false,
                  )
                  .first,
            )
            .position;
        expect(
          rows().viewportDimension,
          lessThanOrEqualTo(page.viewportDimension / 2),
        );
        expect(rows().maxScrollExtent, greaterThan(0));

        // Focus on a row deep in the box, from the keyboard, by way of the
        // next game's row, so the control the page focused before it isn't
        // B's control, where the framework would put focus anyway.
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        tileFocusOf(tester, anyRow('F0')).requestFocus();
        await tester.pump();
        tileFocusOf(tester, anyNested('B', 'B4')).requestFocus();
        await tester.pump();
        await tester.pump();
        expect(_focusIsWithin(tester, anyNested('B', 'B4')), isTrue);

        performCustomAction(rowNode(tester, 'B'), 'Hide expansions');
        await tester.pumpAndSettle();

        expect(box, findsNothing);
        expect(_focusIsWithin(tester, anyControlOf('B')), isTrue);
        expect(
          controlNode(tester, 'B'),
          isSemantics(
            label: 'Game B expansions, 6',
            isButton: true,
            hasExpandedState: true,
            isExpanded: false,
            hasTapAction: true,
            isFocusable: true,
            isFocused: true,
          ),
        );

        final before = page.pixels;
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -80));
        await tester.pumpAndSettle();
        expect(page.pixels, greaterThan(before));
        handle.dispose();
      });

      // A page that brings a fifth expansion moves the rows into the box
      // (#1048).
      testWidgets('a nested row with focus stays focused as the count '
          'crosses 4 → 5, shown in the box', (tester) async {
        remote.onFetchPage = (page, _) async => page == 1
            ? pageOf([base, ...expansionsOf('B', 4), game('C')], hasMore: true)
            : pageOf([
                expansion('B4', [under('B')]),
                game('D'),
              ], page: 2);
        await show(tester, onOpen: (_, _) {});
        await unfold(tester, 'B');
        expect(box, findsNothing);
        // From the keyboard, so the focus is drawn, and a hidden row is
        // brought into view.
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        tileFocusOf(tester, nested('B', 'B3')).requestFocus();
        await tester.pump();

        tester
            .element(row('B'))
            .read<GameBrowseBloc>()
            .add(const GameBrowseMoreRequested());
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();

        expect(box, findsOneWidget);
        final inBox = find.descendant(
          of: box,
          matching: anyNested('B', 'B3'),
        );
        expect(inBox, findsOneWidget);
        expect(_focusIsWithin(tester, inBox), isTrue);
        // The fourth of five, half hidden in a box 3½ rows tall until the
        // focus brings it into view.
        final shown = FocusManager.instance.primaryFocus!.rect;
        final rows = tester.getRect(
          find
              .descendant(
                of: box,
                matching: find.byType(Scrollable),
                skipOffstage: false,
              )
              .first,
        );
        expect(shown.top, greaterThanOrEqualTo(rows.top - 0.5));
        expect(shown.bottom, lessThanOrEqualTo(rows.bottom + 0.5));
      });

      testWidgets("a focused row in a box scrolled out of the list doesn't "
          "move focus to its game's other copy (#819)", (tester) async {
        // B at the top with six, in a box, and C at the end with one, E
        // under both: more than a screen and the list's cache apart.
        remote.onFetchPage = (_, _) async => pageOf([
          base,
          expansion('E', [under('B'), under('C')]),
          ...expansionsOf('B', 5),
          for (var i = 0; i < 30; i++) game('F$i'),
          game('C'),
        ]);
        await show(tester, onOpen: (_, _) {});
        await scrollListToEnd(tester, row('C'));
        await unfold(tester, 'C');
        _pagePosition(tester).jumpTo(0);
        await tester.pumpAndSettle();
        await unfold(tester, 'B');
        final near = anyNested('B', 'E');
        final far = anyNested('C', 'E');
        expect(find.descendant(of: box, matching: near), findsOneWidget);
        expect(far, findsNothing);
        tileFocusOf(tester, near).requestFocus();
        await tester.pump();
        expect(_focusIsWithin(tester, near), isTrue);

        await scrollListToEnd(tester, far);

        expect(near, findsNothing);
        expect(_focusIsWithin(tester, far), isFalse);
      });

      testWidgets("a base game's row keeps its focus as its first expansion "
          'arrives with a page', (tester) async {
        remote.onFetchPage = (page, _) async => page == 1
            ? pageOf([base, game('C')], hasMore: true)
            : pageOf([...expansionsOf('B', 1), game('D')], page: 2);
        await show(tester, onOpen: (_, _) {});
        expect(controlOf('B'), findsNothing);
        final tile = tileFocusOf(tester, row('B'))..requestFocus();
        await tester.pump();

        tester
            .element(row('B'))
            .read<GameBrowseBloc>()
            .add(const GameBrowseMoreRequested());
        await tester.pumpAndSettle();

        expect(controlOf('B'), findsOneWidget);
        expect(tileFocusOf(tester, row('B')), same(tile));
        expect(tile.hasPrimaryFocus, isTrue);
      });

      testWidgets("a stack-free standalone expansion's own top-level row is "
          'unaffected', (tester) async {
        remote.onFetchPage = (_, _) async => pageOf([
          base,
          expansion('E', [under('B', standalone: true)]),
          ...expansionsOf('B', 1),
        ]);
        await show(tester, onOpen: (_, _) {});

        // Its own row, with no control: only its copy under B folds.
        expect(row('E'), findsOneWidget);
        expect(controlOf('E'), findsNothing);
        expect(nested('B', 'E'), findsNothing);
        expect(
          find.descendant(of: controlOf('B'), matching: find.text('2')),
          findsOneWidget,
        );

        await unfold(tester, 'B');
        expect(nested('B', 'E'), findsOneWidget);
        expect(row('E'), findsOneWidget);

        await unfold(tester, 'B');
        expect(nested('B', 'E'), findsNothing);
        expect(row('E'), findsOneWidget);
      });

      testWidgets("folding while an inert box's own stop has focus focuses "
          "the base game's control", (tester) async {
        useViewSize(tester, const Size(400, 1600));
        remote.onFetchPage = (_, _) async => pageOf([
          base,
          ...expansionsOf('B', 6),
          game('C'),
          ...expansionsOf('C', 1),
        ]);
        // Nothing opens, so the rows take no focus and the box is a stop.
        await show(tester);
        await unfold(tester, 'B');
        expect(tester.widget<BgeNestedRowsBox>(box).focusable, isTrue);
        final boxFocus = tester
            .widget<Focus>(
              find.descendant(
                of: box,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Focus &&
                      widget.focusNode?.debugLabel == 'BgeNestedRowsBox',
                ),
              ),
            )
            .focusNode!;
        // By way of C's control, so the control the page focused before the
        // box isn't B's, where the framework would put focus anyway.
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        Focus.of(
          tester.element(
            find.descendant(of: controlOf('C'), matching: find.byType(Icon)),
          ),
        ).requestFocus();
        await tester.pump();
        boxFocus.requestFocus();
        await tester.pump();
        expect(boxFocus.hasPrimaryFocus, isTrue);

        final handle = tester.ensureSemantics();
        performCustomAction(rowNode(tester, 'B'), 'Hide expansions');
        await tester.pumpAndSettle();

        expect(box, findsNothing);
        expect(_focusIsWithin(tester, controlOf('B')), isTrue);
        handle.dispose();
      });

      testWidgets('a sort change with an open base game still on the new '
          'first page keeps it open', (tester) async {
        final expansions = expansionsOf('B', 1);
        // The new order's read is held, so the list draws the reload's
        // loading state between the two: a placement with nothing in it.
        final reload = Completer<PaginatedResult<Game>>();
        remote.onFetchPage = (_, _) => remote.calls.last.endsWith('newest)')
            ? reload.future
            : Future.value(pageOf([base, ...expansions, game('C')]));
        await show(tester, onOpen: (_, _) {});
        await unfold(tester, 'B');
        expect(nested('B', 'B0'), findsOneWidget);

        await chooseSort(tester, 'Newest first');
        expect(find.byKey(GameBrowseScreen.loadingKey), findsOneWidget);
        reload.complete(pageOf([game('C'), base, ...expansions]));
        await tester.pumpAndSettle();

        expect(lastRead(), 'fetchPage(1, 50, newest)');
        expect(
          tester.getTopLeft(row('C')).dy,
          lessThan(tester.getTopLeft(row('B')).dy),
          reason: 'the new order',
        );
        expect(nested('B', 'B0'), findsOneWidget);
        final handle = tester.ensureSemantics();
        expect(
          controlNode(tester, 'B'),
          isControl('Game B expansions, 1', expanded: true),
        );
        handle.dispose();
      });

      testWidgets('switching to thumbnails and back starts folded', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        remote.onFetchPage = (_, _) async =>
            pageOf([base, ...expansionsOf('B', 1), game('C')]);
        await show(tester, onOpen: (_, _) {}, layouts: _FakeLayouts());
        await unfold(tester, 'B');
        expect(nested('B', 'B0'), findsOneWidget);

        await tester.tap(find.byTooltip('Thumbnails'));
        await tester.pumpAndSettle();
        expect(find.byKey(GameBrowseScreen.tileKey('B')), findsOneWidget);
        await tester.tap(find.byTooltip('List'));
        await tester.pumpAndSettle();

        expect(row('B'), findsOneWidget);
        expect(nested('B', 'B0'), findsNothing);
        expect(
          controlNode(tester, 'B'),
          isControl('Game B expansions, 1', expanded: false),
        );
        handle.dispose();
      });
    });
  });

  group('sort', () {
    // The order each read comes back in is the test's: the title read lists
    // Azul, the newest one Catan first.
    void scriptBothOrders() => remote.onFetchPage = (_, _) async =>
        remote.calls.last.endsWith('newest)')
        ? pageOf([seafarers, azul])
        : pageOf([azul, seafarers]);

    /// The rows' order down the screen.
    List<String> titles(WidgetTester tester) {
      final shown = [
        'Azul',
        'Catan: Seafarers',
      ].where((title) => find.text(title).evaluate().isNotEmpty).toList();
      return shown..sort(
        (a, b) => tester
            .getTopLeft(find.text(a))
            .dy
            .compareTo(tester.getTopLeft(find.text(b)).dy),
      );
    }

    testWidgets('starts in the sort it is opened in', (tester) async {
      scriptBothOrders();

      await show(tester, initialSort: GameSort.newest);

      expect(lastRead(), 'fetchPage(1, 50, newest)');
      expect(titles(tester), ['Catan: Seafarers', 'Azul']);
    });

    testWidgets('the menu marks the current sort and changes it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      scriptBothOrders();
      await show(tester);
      expect(titles(tester), ['Azul', 'Catan: Seafarers']);

      await tester.tap(find.byKey(GameBrowseScreen.sortKey));
      await tester.pumpAndSettle();
      SemanticsNode entry(String label) => tester.getSemantics(
        find.widgetWithText(MenuItemButton, label).hitTestable(),
      );
      expect(
        entry('Title'),
        isSemantics(label: 'Title', hasSelectedState: true, isSelected: true),
      );
      expect(
        entry('Newest first'),
        isSemantics(
          label: 'Newest first',
          hasSelectedState: true,
          isSelected: false,
        ),
      );
      await tester.tap(
        find.widgetWithText(MenuItemButton, 'Newest first').hitTestable(),
      );
      // The menu hands over its choice after the first frame.
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(lastRead(), 'fetchPage(1, 50, newest)');
      expect(titles(tester), ['Catan: Seafarers', 'Azul']);

      await tester.tap(find.byKey(GameBrowseScreen.sortKey));
      await tester.pumpAndSettle();
      expect(
        entry('Newest first'),
        isSemantics(
          label: 'Newest first',
          hasSelectedState: true,
          isSelected: true,
        ),
      );
      expect(
        entry('Title'),
        isSemantics(label: 'Title', hasSelectedState: true, isSelected: false),
      );

      // Dispose inline: flutter_test checks for an open SemanticsHandle when
      // the body ends, before tearDown callbacks run.
      handle.dispose();
    });

    testWidgets('choosing the sort already shown reads nothing', (
      tester,
    ) async {
      scriptBothOrders();
      await show(tester);

      await chooseSort(tester, 'Title');
      await tester.pumpAndSettle();

      expect(remote.calls, ['fetchPage(1, 50)']);
    });

    testWidgets('the control tells assistive tech what it does, and whether '
        'its menu is open', (tester) async {
      final handle = tester.ensureSemantics();
      scriptBothOrders();
      await show(tester);
      final control = find.byKey(GameBrowseScreen.sortKey);

      expect(
        tester.getSemantics(control),
        isSemantics(
          tooltip: 'Sort games',
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
        ),
      );

      await tester.tap(control);
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(control),
        isSemantics(hasExpandedState: true, isExpanded: true),
      );

      handle.dispose();
    });

    group('the sort control is there in every state', () {
      final states = <String, Future<void> Function(WidgetTester)>{
        'loading': (tester) async {
          remote.onFetchPage = (_, _) =>
              Completer<PaginatedResult<Game>>().future;
          await tester.pumpWidget(catalogApp(GameBrowseScreen(remote: remote)));
          await tester.pump();
          expect(find.byKey(GameBrowseScreen.loadingKey), findsOneWidget);
        },
        'listing': (tester) async {
          remote.onFetchPage = (_, _) async => pageOf([azul], hasMore: true);
          await show(tester);
        },
        'empty': (tester) async {
          remote.onFetchPage = (_, _) async => pageOf([]);
          await show(tester);
          expect(find.byKey(GameBrowseScreen.emptyKey), findsOneWidget);
        },
        'failed': (tester) async {
          remote.onFetchPage = (_, _) async => throw unreachable();
          await show(tester, cache: FakeGamesCache());
          expect(find.byKey(GameBrowseScreen.errorKey), findsOneWidget);
        },
        'denied': (tester) async {
          remote.onFetchPage = (_, _) async =>
              throw const GamesForbiddenException('403');
          await show(tester);
          expect(find.byKey(GameBrowseScreen.deniedKey), findsOneWidget);
        },
        'from the saved games': (tester) async {
          remote.onFetchPage = (_, _) async => throw unreachable();
          await show(tester, cache: FakeGamesCache([azul]));
          expect(
            find.byKey(GameBrowseScreen.fromCacheBannerKey),
            findsOneWidget,
          );
        },
      };

      for (final MapEntry(:key, :value) in states.entries) {
        testWidgets(key, (tester) async {
          await value(tester);

          final control = tester.widget<IconButton>(
            find.byKey(GameBrowseScreen.sortKey),
          );
          // Enabled throughout: a button that goes disabled drops the focus
          // it holds (#607).
          expect(control.onPressed, isNotNull);
        });
      }
    });

    testWidgets('the control keeps focus across the reload', (tester) async {
      final reload = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => remote.calls.length > 1
          ? reload.future
          : Future.value(pageOf([azul]));
      await show(tester);
      FocusNode focus() => Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(GameBrowseScreen.sortKey),
            matching: find.byIcon(Icons.sort),
          ),
        ),
      );
      focus().requestFocus();
      await tester.pump();
      expect(focus().hasPrimaryFocus, isTrue);

      // From the keyboard: open the menu, step to the other entry (the
      // first press enters the menu, at the chosen one), and pick it.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      // The reload is out: the list gave way to the spinner.
      expect(find.byKey(GameBrowseScreen.loadingKey), findsOneWidget);
      expect(lastRead(), 'fetchPage(1, 50, newest)');
      expect(focus().hasPrimaryFocus, isTrue);

      reload.complete(pageOf([seafarers]));
      await tester.pumpAndSettle();

      expect(find.text('Catan: Seafarers'), findsOneWidget);
      expect(focus().hasPrimaryFocus, isTrue);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('a 320dp screen at text scale $scale: the menu labels are '
          'not clipped', (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        scriptBothOrders();
        await show(tester, onSearch: (_) {});

        await tester.tap(find.byKey(GameBrowseScreen.sortKey));
        await tester.pumpAndSettle();

        final screen = Offset.zero & tester.view.physicalSize;
        for (final label in ['Title', 'Newest first']) {
          final item = find.widgetWithText(MenuItemButton, label);
          expect(item.hitTestable(), findsOneWidget);
          final text = find.descendant(of: item, matching: find.text(label));
          final paragraph = tester.renderObject<RenderParagraph>(text);
          expect(paragraph.didExceedMaxLines, isFalse);
          // Whole, within the screen, and not cut by the item's own edge.
          final rect = tester.getRect(text);
          expect(screen.contains(rect.topLeft), isTrue, reason: label);
          expect(screen.contains(rect.bottomRight), isTrue, reason: label);
          expect(
            tester.getRect(item).inflate(0.5).contains(rect.bottomRight),
            isTrue,
            reason: label,
          );
          expect(
            paragraph.size.height,
            greaterThanOrEqualTo(
              paragraph.getMaxIntrinsicHeight(paragraph.size.width) - 0.5,
            ),
            reason: '"$label" is cut at its foot',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
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

  group('thumbnails', () {
    setUp(() {
      remote.onFetchPage = (_, _) async => pageOf([azul, seafarers]);
    });

    testWidgets('the toggle switches to thumbnails and writes the choice', (
      tester,
    ) async {
      final layouts = _FakeLayouts();
      await show(tester, layouts: layouts);
      expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsOneWidget);
      expect(find.byKey(GameBrowseScreen.tileKey('g_azul')), findsNothing);

      await tester.tap(find.byTooltip('Thumbnails'));
      await tester.pumpAndSettle();

      expect(find.byKey(GameBrowseScreen.tileKey('g_azul')), findsOneWidget);
      expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsNothing);
      expect(layouts.writes, [(ListLayoutScreen.games, ListLayout.thumbnails)]);
    });

    // Logged, not reported as a framework error, which the app takes for a
    // crash and offers to send.
    testWidgets('a store that fails shows the list and keeps a change for '
        'the visit, with no framework error', (tester) async {
      await show(tester, layouts: _FakeLayouts()..failing = true);

      expect(tester.takeException(), isNull);
      expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsOneWidget);

      await tester.tap(find.byTooltip('Thumbnails'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(GameBrowseScreen.tileKey('g_azul')), findsOneWidget);
    });

    testWidgets('a stored thumbnails choice opens in thumbnails', (
      tester,
    ) async {
      await show(
        tester,
        layouts: _FakeLayouts()..stored = ListLayout.thumbnails,
      );

      expect(find.byKey(GameBrowseScreen.tileKey('g_azul')), findsOneWidget);
      expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsNothing);
    });

    testWidgets('until the choice is read, the loading state shows', (
      tester,
    ) async {
      final layouts = _FakeLayouts()..hold = Completer<ListLayout?>();
      await show(tester, layouts: layouts, settle: false);
      await tester.pump();

      expect(find.byKey(GameBrowseScreen.loadingKey), findsOneWidget);
      expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsNothing);
      expect(find.byKey(GameBrowseScreen.tileKey('g_azul')), findsNothing);
      // No count of rows that aren't built.
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .semanticChildCount,
        isNull,
      );

      layouts.hold!.complete(ListLayout.thumbnails);
      await tester.pumpAndSettle();

      expect(find.byKey(GameBrowseScreen.loadingKey), findsNothing);
      expect(find.byKey(GameBrowseScreen.tileKey('g_azul')), findsOneWidget);
    });

    final unread = {
      'a failure': (() async => throw unreachable(), GameBrowseScreen.errorKey),
      'an empty list': (() async => pageOf([]), GameBrowseScreen.emptyKey),
    };
    for (final MapEntry(key: name, value: (fetch, key)) in unread.entries) {
      testWidgets('$name shows before the choice is read', (tester) async {
        remote.onFetchPage = (_, _) => fetch();
        await show(
          tester,
          cache: FakeGamesCache(),
          layouts: _FakeLayouts()..hold = Completer<ListLayout?>(),
          settle: false,
        );
        await tester.pump();

        expect(find.byKey(key), findsOneWidget);
        expect(find.byKey(GameBrowseScreen.loadingKey), findsNothing);
      });
    }

    testWidgets("a tile's name is the title and the row's facts", (
      tester,
    ) async {
      await show(
        tester,
        layouts: _FakeLayouts()..stored = ListLayout.thumbnails,
      );

      expect(
        find.bySemanticsLabel('Azul, 2017, 2 to 4 players'),
        findsOneWidget,
      );
    });

    testWidgets("tapping a tile calls onQuickLook with the game's seed", (
      tester,
    ) async {
      final calls = <GameQuickLookSeed>[];
      await show(
        tester,
        layouts: _FakeLayouts()..stored = ListLayout.thumbnails,
        onQuickLook: (_, seed) => calls.add(seed),
      );

      await tester.tap(find.byKey(GameBrowseScreen.tileKey('g_azul')));
      await tester.pumpAndSettle();

      expect(calls.map((seed) => seed.id), ['g_azul']);
      expect(calls.single.title, 'Azul');
    });

    testWidgets('thumbnails keep the More footer and its page loads', (
      tester,
    ) async {
      remote.onFetchPage = (page, _) async => page == 1
          ? pageOf([azul], hasMore: true)
          : pageOf([seafarers], page: 2);
      await show(
        tester,
        layouts: _FakeLayouts()..stored = ListLayout.thumbnails,
      );

      await tester.tap(find.byKey(GameBrowseScreen.moreKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(GameBrowseScreen.tileKey('g_seafarers')),
        findsOneWidget,
      );
      expect(find.byKey(GameBrowseScreen.moreKey), findsNothing);
    });

    testWidgets('2 columns at 400, 3 at 700', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      remote.onFetchPage = (_, _) async =>
          pageOf([azul, seafarers, game('g_c'), game('g_d')]);

      Future<int> columns(double width) async {
        tester.view.physicalSize = Size(width, 900);
        await show(
          tester,
          layouts: _FakeLayouts()..stored = ListLayout.thumbnails,
        );
        final xs = {
          for (final id in ['g_azul', 'g_seafarers', 'g_c', 'g_d'])
            tester
                .getTopLeft(find.byKey(GameBrowseScreen.tileKey(id)))
                .dx
                .round(),
        };
        return xs.length;
      }

      expect(await columns(400), 2);
      expect(await columns(599), 2);
      expect(await columns(600), 3);
      expect(await columns(700), 3);
      expect(await columns(840), 4);
      expect(await columns(1200), 4);
    });

    testWidgets('a tap before the choice is read is not undone by it', (
      tester,
    ) async {
      final layouts = _FakeLayouts()..hold = Completer<ListLayout?>();
      await show(tester, layouts: layouts, settle: false);
      await tester.pump();

      await tester.tap(find.byTooltip('Thumbnails'));
      await tester.pump();
      layouts.hold!.complete(ListLayout.list);
      await tester.pumpAndSettle();

      expect(find.byKey(GameBrowseScreen.tileKey('g_azul')), findsOneWidget);
      expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsNothing);
      expect(layouts.writes, [(ListLayoutScreen.games, ListLayout.thumbnails)]);
    });
  });

  group('expansions in thumbnails (#711)', () {
    ExpansionLink under(String id) =>
        ExpansionLink(gameId: id, isStandalone: false);
    Game expansion(String id, List<ExpansionLink> links) =>
        game(id, contentType: ContentType.expansion, baseGames: links);

    Finder tile(String id) => find.byKey(GameBrowseScreen.tileKey(id));
    Finder stripTile(String parent, String id) =>
        find.byKey(GameBrowseScreen.nestedTileKey(parent, id));
    Finder badgeOf(String id) => find.descendant(
      of: tile(id),
      matching: find.byKey(BgeCoverTile.expansionsBadgeKey),
    );

    /// The cover's own node: with a badge, the tile holds two nodes and has
    /// none of its own, so it is found from the picture inside it.
    SemanticsNode coverNode(WidgetTester tester, String id) =>
        tester.getSemantics(
          find.descendant(of: tile(id), matching: find.byType(BgeThumbnail)),
        );

    void performCustomAction(SemanticsNode node, String label) =>
        node.owner!.performAction(
          node.id,
          SemanticsAction.customAction,
          CustomSemanticsAction.getIdentifier(
            CustomSemanticsAction(label: label),
          ),
        );

    final grids = find.byWidgetPredicate(
      (widget) => widget is BgeKeyedSliverGrid,
    );

    /// Shows the page in thumbnails, two columns wide and, unless [size]
    /// says otherwise, tall enough for every cover and the strip.
    Future<void> showThumbnails(
      WidgetTester tester, {
      void Function(BuildContext context, GameQuickLookSeed seed)? onQuickLook,
      Stream<String>? gone,
      FakeGamesCache? cache,
      Size size = const Size(400, 1600),
    }) async {
      useViewSize(tester, size);
      await show(
        tester,
        gone: gone,
        cache: cache,
        layouts: _FakeLayouts()..stored = ListLayout.thumbnails,
        onQuickLook: onQuickLook ?? (_, _) {},
      );
    }

    testWidgets("only top-level covers show, and a base game's carries the "
        'count', (tester) async {
      final handle = tester.ensureSemantics();
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        expansion('E', [under('B')]),
        game('C'),
      ]);

      await showThumbnails(tester);

      expect(tile('B'), findsOneWidget);
      expect(tile('C'), findsOneWidget);
      expect(tile('E'), findsNothing);
      expect(find.byType(BgeShelf), findsNothing);
      expect(
        find.descendant(of: badgeOf('B'), matching: find.text('1')),
        findsOneWidget,
      );
      expect(badgeOf('C'), findsNothing);
      expect(
        tester.getSemantics(badgeOf('B')),
        isSemantics(
          label: 'Game B expansions, 1',
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
          isFocusable: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a next page that only adds expansions under a folded cover '
        'reads on until a cover shows', (tester) async {
      remote.onFetchPage = (page, _) async => switch (page) {
        1 => pageOf([game('B')], hasMore: true),
        2 => pageOf(
          [
            expansion('E', [under('B')]),
          ],
          page: 2,
          hasMore: true,
        ),
        3 => pageOf([game('C')], page: 3, hasMore: true),
        _ => throw unreachable(),
      };

      await showThumbnails(tester);
      await tester.tap(find.byKey(GameBrowseScreen.moreKey));
      await tester.pumpAndSettle();

      expect(tile('C'), findsOneWidget);
      expect(
        find.descendant(of: badgeOf('B'), matching: find.text('1')),
        findsOneWidget,
      );
      // Page 3 showed a cover, so the grid waits for the next press.
      expect(remote.calls, hasLength(3));
      expect(find.byKey(GameBrowseScreen.moreKey), findsOneWidget);
    });

    testWidgets("the badge unfolds a strip of its expansions' covers and "
        'folds it again', (tester) async {
      final handle = tester.ensureSemantics();
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        expansion('E1', [under('B')]),
        expansion('E2', [under('B')]),
        game('C'),
        game('D'),
      ]);
      await showThumbnails(tester);

      await tester.tap(badgeOf('B'));
      await tester.pumpAndSettle();

      expect(find.byType(BgeShelf), findsOneWidget);
      expect(find.text('Game B expansions'), findsOneWidget);
      expect(stripTile('B', 'E1'), findsOneWidget);
      expect(stripTile('B', 'E2'), findsOneWidget);
      expect(tile('E1'), findsNothing);
      expect(
        tester.getSemantics(badgeOf('B')),
        isSemantics(
          label: 'Game B expansions, 2',
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
          isFocusable: true,
        ),
      );
      // Under B's row, which C shares at two columns, and above D's.
      final strip = tester.getRect(find.byType(BgeShelf));
      expect(tester.getRect(tile('C')).bottom, lessThan(strip.top));
      expect(tester.getRect(tile('D')).top, greaterThan(strip.bottom));
      // A strip cover is named as the expansion of its base game.
      expect(
        tester.getSemantics(stripTile('B', 'E1')).label,
        startsWith('Game E1, expansion for Game B'),
      );

      await tester.tap(badgeOf('B'));
      await tester.pumpAndSettle();

      expect(find.byType(BgeShelf), findsNothing);
      expect(stripTile('B', 'E1'), findsNothing);
      expect(grids, findsOneWidget);
      handle.dispose();
    });

    testWidgets('unfolding another base game folds the first', (tester) async {
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        game('C'),
        expansion('E1', [under('B')]),
        expansion('E2', [under('C')]),
      ]);
      await showThumbnails(tester);

      await tester.tap(badgeOf('B'));
      await tester.pumpAndSettle();
      await tester.tap(badgeOf('C'));
      await tester.pumpAndSettle();

      expect(find.byType(BgeShelf), findsOneWidget);
      expect(stripTile('C', 'E2'), findsOneWidget);
      expect(stripTile('B', 'E1'), findsNothing);
    });

    testWidgets('the badge keeps its focus as strips open and close, a later '
        "game's included", (tester) async {
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        expansion('E1', [under('B')]),
        game('C'),
        game('D'),
        expansion('E2', [under('D')]),
        game('F'),
      ]);
      await showThumbnails(tester);

      for (final step in ['opened', 'closed', 'opened again']) {
        await tester.tap(badgeOf('B'));
        await tester.pumpAndSettle();
        expect(_focusIsWithin(tester, badgeOf('B')), isTrue, reason: step);
      }

      // At two columns D is in the row after B's strip, and moves to the
      // rows before its own strip.
      await tester.tap(badgeOf('D'));
      await tester.pumpAndSettle();

      expect(stripTile('D', 'E2'), findsOneWidget);
      expect(_focusIsWithin(tester, badgeOf('D')), isTrue);
    });

    testWidgets("opening a second strip keeps the tapped badge's semantics "
        'node (#820)', (tester) async {
      final handle = tester.ensureSemantics();
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        expansion('E1', [under('B')]),
        game('C'),
        game('D'),
        expansion('E2', [under('D')]),
        game('F'),
      ]);
      await showThumbnails(tester);
      await tester.tap(badgeOf('B'));
      await tester.pumpAndSettle();
      // At two columns D is in the row after B's strip, and moves to the
      // rows before its own strip.
      final badge = tester.getSemantics(badgeOf('D')).id;
      final cover = coverNode(tester, 'D').id;

      await tester.tap(badgeOf('D'));
      await tester.pumpAndSettle();

      expect(stripTile('D', 'E2'), findsOneWidget);
      expect(tester.getSemantics(badgeOf('D')).id, badge);
      expect(coverNode(tester, 'D').id, cover);
      handle.dispose();
    });

    testWidgets('a strip cover opens the quick look', (tester) async {
      final calls = <GameQuickLookSeed>[];
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        expansion('E', [under('B')]),
      ]);
      await showThumbnails(tester, onQuickLook: (_, seed) => calls.add(seed));

      await tester.tap(badgeOf('B'));
      await tester.pumpAndSettle();
      await tester.tap(stripTile('B', 'E'));
      await tester.pumpAndSettle();

      expect(calls.map((seed) => seed.id), ['E']);
    });

    testWidgets("Show expansions works from the cover's custom action", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        expansion('E', [under('B')]),
      ]);
      await showThumbnails(tester);

      expect(
        coverNode(tester, 'B'),
        isSemantics(
          label: 'Game B',
          customActions: [
            const CustomSemanticsAction(label: 'Show expansions'),
          ],
        ),
      );
      performCustomAction(coverNode(tester, 'B'), 'Show expansions');
      await tester.pumpAndSettle();

      expect(stripTile('B', 'E'), findsOneWidget);
      expect(
        coverNode(tester, 'B'),
        isSemantics(
          label: 'Game B',
          customActions: [
            const CustomSemanticsAction(label: 'Hide expansions'),
          ],
        ),
      );

      performCustomAction(coverNode(tester, 'B'), 'Hide expansions');
      await tester.pumpAndSettle();

      expect(stripTile('B', 'E'), findsNothing);
      handle.dispose();
    });

    // The page's app bar is the Scaffold's, above the scroll view and not
    // over it, so a reveal measured in the scroll view's own space leaves
    // both the strip's bottom and the tapped row's top clear of it (#818).
    for (final (why, height, before, fits) in [
      ('the strip fits under its row', 700.0, 4, true),
      ("the row and its strip don't fit", 400.0, 0, false),
    ]) {
      testWidgets('opening a strip on the last row scrolls it into view below '
          'the app bar: $why', (tester) async {
        remote.onFetchPage = (_, _) async => pageOf([
          for (var i = 0; i < before; i++) game('A$i'),
          game('X'),
          expansion('E', [under('X')]),
          for (var i = 0; i < 6; i++) game('Z$i'),
        ]);
        await showThumbnails(tester, size: Size(400, height));
        final appBar = tester.getRect(find.byType(AppBar));
        final view = tester.getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        );
        expect(view.top, appBar.bottom);
        // X's row is the last one wholly in view.
        expect(
          tester.getRect(tile('X')).bottom,
          lessThanOrEqualTo(view.bottom),
        );

        await tester.tap(badgeOf('X'));
        await tester.pumpAndSettle();

        final row = tester.getRect(tile('X'));
        final strip = tester.getRect(find.byType(BgeShelf));
        if (fits) {
          expect(strip.bottom, moreOrLessEquals(view.bottom));
          expect(row.top, greaterThan(appBar.bottom));
        } else {
          expect(row.top, moreOrLessEquals(appBar.bottom));
          expect(strip.top, lessThan(view.bottom));
        }
      });
    }

    testWidgets("a marked cover's label says the base game isn't on this "
        'server', (tester) async {
      remote.onFetchPage = (_, _) async => pageOf([
        game('A'),
        expansion('E', [under('X')]),
      ]);
      await showThumbnails(tester);

      final cover = find.descendant(
        of: tile('E'),
        matching: find.byType(BgeCoverTile),
      );
      expect(tester.widget<BgeCoverTile>(cover).marked, isTrue);
      expect(
        tester.widget<BgeCoverTile>(cover).label,
        'Game E, Base game not on this server, Expansion',
      );
      expect(
        tester
            .widget<BgeCoverTile>(
              find.descendant(
                of: tile('A'),
                matching: find.byType(BgeCoverTile),
              ),
            )
            .marked,
        isFalse,
      );
    });

    testWidgets("offline, a marked cover's label says its base game wasn't "
        'saved', (tester) async {
      remote.onFetchPage = (_, _) async => throw unreachable();
      await showThumbnails(
        tester,
        cache: FakeGamesCache([
          expansion('E', [under('X')]),
        ]),
      );

      expect(
        tester
            .widget<BgeCoverTile>(
              find.descendant(
                of: tile('E'),
                matching: find.byType(BgeCoverTile),
              ),
            )
            .label,
        'Game E, Base game not saved on this device, Expansion',
      );
    });

    testWidgets('the semantic child count is the top-level covers', (
      tester,
    ) async {
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        game('C'),
        expansion('E', [under('B'), under('C')]),
      ]);
      await showThumbnails(tester);

      // Three games, an expansion under two of them: two covers.
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .semanticChildCount,
        2,
      );
    });

    testWidgets('a focused marked expansion whose base game a retry brings '
        "hands focus to the base game's badge (#813)", (tester) async {
      // The server fails, and the saved games hold the expansion but never
      // its base game, so the expansion is at top level, marked. Covers
      // after the first row, so the page scrolls, and it is scrolled a
      // little, with the expansion's row still built.
      final after = [for (var i = 0; i < 8; i++) game('Z$i')];
      remote.onFetchPage = (_, _) async => throw unreachable();
      await showThumbnails(
        tester,
        size: const Size(400, 700),
        cache: FakeGamesCache([
          expansion('E', [under('B')]),
          game('C'),
          ...after,
        ]),
      );
      final page =
          tester
              .state<ScrollableState>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                ),
              )
              .position
            ..jumpTo(120);
      await tester.pump();
      expect(
        tester
            .widget<BgeCoverTile>(
              find.descendant(
                of: tile('E'),
                matching: find.byType(BgeCoverTile),
              ),
            )
            .marked,
        isTrue,
      );
      // C's cover, then the expansion's: each ink's own node.
      for (final id in ['C', 'E']) {
        Focus.of(
          tester.element(
            find
                .descendant(
                  of: find.descendant(
                    of: tile(id),
                    matching: find.byType(InkWell),
                  ),
                  matching: find.byType(MouseRegion),
                )
                .first,
          ),
        ).requestFocus();
        await tester.pump();
      }
      expect(_focusIsWithin(tester, tile('E')), isTrue);

      // A tap on the retry leaves focus where it is. The server's page has
      // the base game, and the expansion moves into its strip, which stays
      // folded.
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        expansion('E', [under('B')]),
        game('C'),
        ...after,
      ]);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.byKey(GameBrowseScreen.fromCacheBannerKey), findsNothing);
      expect(tile('E'), findsNothing);
      expect(find.byType(BgeShelf), findsNothing);
      expect(_focusIsWithin(tester, badgeOf('B')), isTrue);
      // The page doesn't move.
      expect(page.pixels, 120);
    });

    testWidgets('the strip folds when its game is found gone', (tester) async {
      final gone = StreamController<String>();
      addTearDown(gone.close);
      remote.onFetchPage = (_, _) async => pageOf([
        game('B'),
        expansion('E', [under('B')]),
        game('C'),
      ]);
      await showThumbnails(tester, gone: gone.stream);
      await tester.tap(badgeOf('B'));
      await tester.pumpAndSettle();
      expect(find.byType(BgeShelf), findsOneWidget);

      gone.add('B');
      await tester.pumpAndSettle();

      expect(find.byType(BgeShelf), findsNothing);
      expect(grids, findsOneWidget);
      // Its expansion has no base game left on the page.
      expect(tile('E'), findsOneWidget);
      expect(
        tester
            .widget<BgeCoverTile>(
              find.descendant(
                of: tile('E'),
                matching: find.byType(BgeCoverTile),
              ),
            )
            .marked,
        isTrue,
      );
    });

    group('under the selection region (#338)', () {
      const expansionCount = 12;

      Future<void> showUnderRegion(
        WidgetTester tester, {
        void Function(BuildContext context, GameQuickLookSeed seed)?
        onQuickLook,
      }) async {
        remote.onFetchPage = (_, _) async => pageOf([
          game('B'),
          for (var i = 1; i <= expansionCount; i++)
            expansion('E$i', [under('B')]),
        ]);
        useViewSize(tester, const Size(1280, 1600));
        await show(
          tester,
          layouts: _FakeLayouts()..stored = ListLayout.thumbnails,
          onQuickLook: onQuickLook ?? (_, _) {},
          theme: pointerPlatformTheme(),
          builder: underSelectionRegion,
        );
        await tester.tap(badgeOf('B'));
        await tester.pumpAndSettle();
      }

      Finder row() => find.descendant(
        of: find.byType(BgeShelf),
        matching: find.byType(SingleChildScrollView),
      );

      ScrollPosition strip(WidgetTester tester) => tester
          .state<ScrollableState>(
            find.descendant(
              of: row(),
              matching: find.byType(Scrollable),
            ),
          )
          .position;

      testWidgets('the region is installed', (tester) async {
        await showUnderRegion(tester);

        expect(find.byType(SelectableRegion), findsOneWidget);
        expect(find.byType(BgeShelf), findsOneWidget);
      });

      testWidgets('a mouse drag across the expansions strip scrolls it', (
        tester,
      ) async {
        final copies = captureClipboardCopies();
        await showUnderRegion(tester);

        // The strip must overflow, or a drag has nothing to scroll and the
        // test would pass whatever the region did.
        expect(strip(tester).maxScrollExtent, greaterThan(0));
        expect(strip(tester).pixels, 0);

        final centre = tester.getCenter(row());
        await mouseDrag(tester, centre, centre - const Offset(300, 0));
        await tester.pumpAndSettle();

        expect(strip(tester).pixels, greaterThan(0));

        await sendCopyShortcut(tester);
        expect(copies, isEmpty);
      });

      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        testWidgets('a ${kind.name} tap on a strip cover still opens the '
            'quick look', (tester) async {
          final calls = <GameQuickLookSeed>[];
          await showUnderRegion(
            tester,
            onQuickLook: (_, seed) => calls.add(seed),
          );

          await tester.tap(stripTile('B', 'E1'), kind: kind);
          await tester.pumpAndSettle();

          expect(calls.map((seed) => seed.id), ['E1']);
        });
      }
    });
  });

  group('the layout toggle (#710)', () {
    final toggle = find.byKey(GameBrowseScreen.layoutToggleKey);

    /// The toggle heads the content, end-aligned, above [content], and is not
    /// in the app bar, where it left the title a few letters at 320dp.
    void expectAtTheHead(WidgetTester tester, Finder content) {
      expect(toggle, findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: toggle),
        findsNothing,
      );
      expect(content, findsOneWidget);
      expect(
        tester.getBottomLeft(toggle).dy,
        lessThanOrEqualTo(tester.getTopLeft(content).dy),
      );
    }

    final states = <String, Future<Finder> Function(WidgetTester)>{
      'while the choice is read': (tester) async {
        remote.onFetchPage = (_, _) async => pageOf([azul]);
        await show(
          tester,
          layouts: _FakeLayouts()..hold = Completer<ListLayout?>(),
          settle: false,
        );
        await tester.pump();
        return find.byKey(GameBrowseScreen.loadingKey);
      },
      'while the first page loads': (tester) async {
        remote.onFetchPage = (_, _) =>
            Completer<PaginatedResult<Game>>().future;
        await show(tester, settle: false);
        await tester.pump();
        return find.byKey(GameBrowseScreen.loadingKey);
      },
      'over a failure': (tester) async {
        remote.onFetchPage = (_, _) async => throw unreachable();
        await show(tester, cache: FakeGamesCache());
        return find.byKey(GameBrowseScreen.errorKey);
      },
      'over an empty list': (tester) async {
        remote.onFetchPage = (_, _) async => pageOf([]);
        await show(tester);
        return find.byKey(GameBrowseScreen.emptyKey);
      },
      'over the from-cache banner': (tester) async {
        remote.onFetchPage = (_, _) async => throw unreachable();
        await show(tester, cache: FakeGamesCache([azul]));
        return find.byKey(GameBrowseScreen.fromCacheBannerKey);
      },
    };
    for (final MapEntry(key: state, value: build) in states.entries) {
      testWidgets('heads the content $state', (tester) async {
        expectAtTheHead(tester, await build(tester));
      });
    }

    testWidgets('heads the rows, at their end edge', (tester) async {
      remote.onFetchPage = (_, _) async => pageOf([azul, seafarers]);
      await show(tester, layouts: _FakeLayouts());

      final row = find.byKey(GameBrowseScreen.rowKey('g_azul'));
      expectAtTheHead(tester, row);
      expect(
        tester.getTopRight(toggle).dx,
        moreOrLessEquals(tester.getTopRight(row).dx, epsilon: 0.5),
      );
    });

    testWidgets('a screen reader meets it after the title and before the '
        'rows', (tester) async {
      final handle = tester.ensureSemantics();
      remote.onFetchPage = (_, _) async => pageOf([azul]);
      await show(tester, layouts: _FakeLayouts());

      expect(
        tester.semantics.simulatedAccessibilityTraversal(),
        containsAllInOrder(<Matcher>[
          isSemantics(label: 'Games'),
          isSemantics(label: 'List'),
          isSemantics(label: 'Thumbnails'),
          isSemantics(label: 'Azul\n2017, 2 to 4 players'),
        ]),
      );
      handle.dispose();
    });

    testWidgets('keeps its focus while the list reloads', (tester) async {
      final reload = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => remote.calls.length > 1
          ? reload.future
          : Future.value(pageOf([azul]));
      await show(tester, layouts: _FakeLayouts());
      final segment = Focus.of(
        tester.element(
          find.descendant(
            of: toggle,
            matching: find.byIcon(Icons.view_list_outlined),
          ),
        ),
      )..requestFocus();
      await tester.pump();

      tester
          .element(find.byKey(GameBrowseScreen.rowKey('g_azul')))
          .read<GameBrowseBloc>()
          .add(const GameBrowseSortChanged(GameSort.newest));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(GameBrowseScreen.loadingKey), findsOneWidget);
      expect(segment.hasPrimaryFocus, isTrue);

      reload.complete(pageOf([seafarers]));
      await tester.pumpAndSettle();

      expect(find.text('Catan: Seafarers'), findsOneWidget);
      expect(segment.hasPrimaryFocus, isTrue);
    });
  });

  group('accessibility audit', () {
    // `show` pumps the screen and wants the tester, so each call pumps it
    // with `pump`.
    Future<void> showAudited(
      WidgetTester tester,
      ThemeData theme, {
      FakeGamesCache? cache,
      ListLayout? layout,
      bool settle = true,
    }) => show(
      tester,
      cache: cache,
      layouts: layout == null ? null : (_FakeLayouts()..stored = layout),
      onOpen: (_, _) {},
      onSearch: (_) {},
      onQuickLook: (_, _) {},
      settle: settle,
      theme: theme,
    );

    // Enough games for a page taller than the narrow window at 2.0 text.
    List<Game> many() => [
      azul,
      seafarers,
      for (var n = 0; n < 10; n++) game('g_$n', title: 'Game number $n'),
    ];

    // The same with [count] expansions nested under Azul (#711), and
    // Seafarers, unlinked, marked. Five overflow Azul's strip, so the shelf
    // shows its buttons; one keeps the marked row in the narrow window.
    List<Game> withExpansions(int count) => [
      azul,
      for (var n = 0; n < count; n++)
        game(
          'x_$n',
          title: 'Azul expansion $n',
          contentType: ContentType.expansion,
          baseGames: const [
            ExpansionLink(gameId: 'g_azul', isStandalone: false),
          ],
        ),
      seafarers,
      for (var n = 0; n < 10; n++) game('g_$n', title: 'Game number $n'),
    ];

    Finder badgeOf(String id) => find.descendant(
      of: find.byKey(GameBrowseScreen.tileKey(id)),
      matching: find.byKey(BgeCoverTile.expansionsBadgeKey),
    );

    /// The control at the end of Azul's row, which folds and unfolds its
    /// expansions (#1048).
    final azulControl = find.descendant(
      of: find.byKey(GameBrowseScreen.rowKey('g_azul')),
      matching: find.byType(BgeRowExpansionsControl),
    );

    /// Shows Azul's expansions, from its row's control (#1048).
    Future<void> unfoldAzul(WidgetTester tester) async {
      await tester.ensureVisible(azulControl);
      await tester.pumpAndSettle();
      await tester.tap(azulControl);
      await tester.pumpAndSettle();
    }

    // The first page is still being read: the spinner never settles.
    auditScreen(
      'loading',
      pump: (tester, theme) async {
        final pending = Completer<PaginatedResult<Game>>();
        addTearDown(() => pending.complete(pageOf([])));
        remote.onFetchPage = (_, _) => pending.future;
        await showAudited(tester, theme, settle: false);
        await tester.pump();
        expect(find.byKey(GameBrowseScreen.loadingKey), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'ready',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async => pageOf(many(), hasMore: true);
        await showAudited(tester, theme);
        expect(find.byKey(GameBrowseScreen.rowKey('g_azul')), findsOneWidget);
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async => pageOf(many(), hasMore: true);
        await showAudited(tester, theme);
      },
      arrange: (tester) =>
          scrollListToEnd(tester, find.byKey(GameBrowseScreen.moreKey)),
    );

    auditScreen(
      'ready, with a nested expansion and a marked one',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async =>
            pageOf(withExpansions(1), hasMore: true);
        await showAudited(tester, theme);
        await unfoldAzul(tester);
        expect(
          find.byKey(GameBrowseScreen.nestedRowKey('g_azul', 'x_0')),
          findsOneWidget,
        );
        // Built, if below the window at 320dp and 2.0, where the control
        // stands by Azul's title and its tap scrolls the page less: the
        // audit after this one shows it.
        expect(
          find.byKey(
            GameBrowseScreen.rowKey('g_seafarers'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(find.byKey(GameBrowseScreen.rowKey('x_0')), findsNothing);
      },
    );

    // At 320dp and 2.0 the marked row is taller than what is left below the
    // nested one, so it is audited whole here.
    auditScreen(
      'ready, with a nested expansion and a marked one, scrolled to the '
      'marked one',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async =>
            pageOf(withExpansions(1), hasMore: true);
        await showAudited(tester, theme);
        await unfoldAzul(tester);
      },
      arrange: (tester) => tester.ensureVisible(
        find.byKey(
          GameBrowseScreen.rowKey('g_seafarers'),
          skipOffstage: false,
        ),
      ),
    );

    // Azul's five behind its control, with the marked row after it.
    auditScreen(
      'ready, with a folded base game (#1048)',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async =>
            pageOf(withExpansions(5), hasMore: true);
        await showAudited(tester, theme);
        expect(azulControl, findsOneWidget);
        expect(
          find.byKey(
            GameBrowseScreen.nestedRowKey('g_azul', 'x_0'),
            skipOffstage: false,
          ),
          findsNothing,
        );
      },
    );

    auditScreen(
      'ready, with a base game unfolded, 4 nested rows (#1048)',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async =>
            pageOf(withExpansions(4), hasMore: true);
        await showAudited(tester, theme);
        await unfoldAzul(tester);
        expect(
          find.byKey(GameBrowseScreen.nestedRowKey('g_azul', 'x_0')),
          findsOneWidget,
        );
        expect(find.byType(BgeNestedRowsBox), findsNothing);
      },
    );

    // At 320dp and 2.0 the box is held to half the page, less than a row.
    auditScreen(
      'ready, with a base game unfolded, 6 nested rows in a box (#1048)',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async =>
            pageOf(withExpansions(6), hasMore: true);
        await showAudited(tester, theme);
        await unfoldAzul(tester);
        expect(find.byType(BgeNestedRowsBox), findsOneWidget);
        expect(
          find.byKey(GameBrowseScreen.nestedRowKey('g_azul', 'x_0')),
          findsOneWidget,
        );
      },
      arrange: (tester) => tester.ensureVisible(find.byType(BgeNestedRowsBox)),
    );

    auditScreen(
      'thumbnails',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async => pageOf(many(), hasMore: true);
        await showAudited(tester, theme, layout: ListLayout.thumbnails);
        expect(find.byKey(GameBrowseScreen.tileKey('g_azul')), findsOneWidget);
      },
    );

    auditScreen(
      'thumbnails, with a badged cover and a marked one',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async =>
            pageOf(withExpansions(5), hasMore: true);
        await showAudited(tester, theme, layout: ListLayout.thumbnails);
        expect(badgeOf('g_azul'), findsOneWidget);
        expect(
          find.byKey(GameBrowseScreen.tileKey('g_seafarers')),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'thumbnails, with a strip unfolded',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async =>
            pageOf(withExpansions(5), hasMore: true);
        await showAudited(tester, theme, layout: ListLayout.thumbnails);
        await tester.tap(badgeOf('g_azul'));
        await tester.pumpAndSettle();
        expect(find.text('Azul expansions'), findsOneWidget);
        expect(find.byKey(BgeShelf.previousKey), findsOneWidget);
        expect(find.byKey(BgeShelf.nextKey), findsOneWidget);
        expect(
          find.byKey(GameBrowseScreen.nestedTileKey('g_azul', 'x_0')),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'thumbnails, scrolled to the end',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async => pageOf(many(), hasMore: true);
        await showAudited(tester, theme, layout: ListLayout.thumbnails);
      },
      arrange: (tester) =>
          scrollListToEnd(tester, find.byKey(GameBrowseScreen.moreKey)),
    );

    auditScreen(
      'empty',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async => pageOf([]);
        await showAudited(tester, theme);
        expect(find.byKey(GameBrowseScreen.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async => throw unreachable();
        await showAudited(tester, theme, cache: FakeGamesCache());
        expect(find.byKey(GameBrowseScreen.errorKey), findsOneWidget);
      },
    );

    auditScreen(
      'denied',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async =>
            throw const GamesForbiddenException('403');
        await showAudited(tester, theme, cache: FakeGamesCache([azul]));
        expect(find.byKey(GameBrowseScreen.deniedKey), findsOneWidget);
      },
    );

    auditScreen(
      'saved games under a banner',
      pump: (tester, theme) async {
        remote.onFetchPage = (_, _) async => throw unreachable();
        await showAudited(tester, theme, cache: FakeGamesCache(many()));
        expect(find.byKey(GameBrowseScreen.fromCacheBannerKey), findsOneWidget);
        expect(find.text('Azul'), findsOneWidget);
      },
    );
  });
}

/// The page's own scroll position: the first vertical scroll view, which
/// holds any other, such as a box of nested rows' (#1048).
ScrollPosition _pagePosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    )
    .position;

/// Whether the primary focus is on the widget [finder] finds, or inside it.
bool _focusIsWithin(WidgetTester tester, Finder finder) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final target = tester.element(finder);
  var within = identical(context, target);
  context.visitAncestorElements((ancestor) {
    within = within || identical(ancestor, target);
    return !within;
  });
  return within;
}

/// A layout store that answers with [stored], or after [hold].
class _FakeLayouts implements ListLayoutRepository {
  ListLayout? stored;
  Completer<ListLayout?>? hold;
  final writes = <(ListLayoutScreen, ListLayout)>[];

  /// Every read and write throws, as a store that has gone does.
  bool failing = false;

  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async {
    if (failing) throw StateError('ListLayoutRepository has been disposed');
    return hold?.future ?? stored;
  }

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async {
    if (failing) throw StateError('ListLayoutRepository has been disposed');
    stored = layout;
    writes.add((screen, layout));
  }
}
