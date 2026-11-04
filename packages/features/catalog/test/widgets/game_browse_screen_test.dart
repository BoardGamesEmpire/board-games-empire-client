import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
    Stream<String>? gone,
    void Function(BuildContext context, String gameId)? onOpen,
    void Function(BuildContext context)? onSearch,
    GameSort initialSort = GameSort.title,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        GameBrowseScreen(
          remote: remote,
          cache: cache,
          gone: gone,
          onOpen: onOpen,
          onSearch: onSearch,
          initialSort: initialSort,
        ),
      ),
    );
    await tester.pumpAndSettle();
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
}
