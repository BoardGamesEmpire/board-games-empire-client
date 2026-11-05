import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:interfaces/repositories.dart';
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
    Stream<String>? gone,
    void Function(BuildContext context, String gameId)? onOpen,
    void Function(BuildContext context)? onSearch,
    GameSort initialSort = GameSort.title,
    ListLayoutRepository? layouts,
    void Function(BuildContext context, GameQuickLookSeed seed)? onQuickLook,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      catalogApp(
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
    final focus = tester.widget<TextButton>(retry).focusNode!;
    focus.requestFocus();
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
      );
      segment.requestFocus();
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
}

/// A layout store that answers with [stored], or after [hold].
class _FakeLayouts implements ListLayoutRepository {
  ListLayout? stored;
  Completer<ListLayout?>? hold;
  final writes = <(ListLayoutScreen, ListLayout)>[];

  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async =>
      hold?.future ?? stored;

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async {
    stored = layout;
    writes.add((screen, layout));
  }
}
