import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_connectivity.dart';
import '../support/fake_game_pool.dart';
import '../support/fake_games_remote.dart';

const _reshuffled = 'New games to play';

void main() {
  late FakeGamesRemote remote;
  late FakeGamePool pool;
  late FakeConnectivity connectivity;

  setUp(() {
    remote = FakeGamesRemote();
    pool = FakeGamePool();
    connectivity = FakeConnectivity();
  });

  tearDown(() => connectivity.close());

  final navigatorKey = GlobalKey<NavigatorState>();
  const before = Key('before');
  const after = Key('after');

  final reshuffle = find.byKey(SomethingToPlaySection.reshuffleKey);

  Finder cover(String id) => find.byKey(SomethingToPlaySection.coverKey(id));

  /// The section in the column the home page puts its sections in, with a
  /// control on either side of it for focus to go to.
  Widget harness({
    GameCollectionRepository? collection,
    Stream<List<Household>>? Function()? households,
    Stream<String>? gone,
    void Function(BuildContext context, GameQuickLookSeed seed)? onOpen,
    ThemeData? theme,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: GameCatalogLocalizations.localizationsDelegates,
    supportedLocales: GameCatalogLocalizations.supportedLocales,
    home: Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton(
            key: before,
            onPressed: () {},
            child: const Text('Before'),
          ),
          SomethingToPlaySection(
            remote: remote,
            pool: pool,
            collection: collection,
            households: households,
            connectivity: connectivity,
            gone: gone,
            onOpen: onOpen,
          ),
          TextButton(key: after, onPressed: () {}, child: const Text('After')),
        ],
      ),
    ),
  );

  /// Shows the section and lets the draw reach the screen, and the row's
  /// buttons, which come a frame after it.
  Future<void> show(
    WidgetTester tester, {
    Stream<String>? gone,
    void Function(BuildContext context, GameQuickLookSeed seed)? onOpen,
  }) async {
    await tester.pumpWidget(harness(gone: gone, onOpen: onOpen));
    await tester.pumpAndSettle();
  }

  /// The pool holds [ids].
  void poolHolds(List<String> ids) => pool.onSample = (_) async => poolOf(ids);

  /// Puts focus on Reshuffle, and returns the node that took it.
  Future<FocusNode> focusReshuffle(WidgetTester tester) async {
    final label = find.descendant(of: reshuffle, matching: find.byType(Text));
    Focus.of(tester.element(label)).requestFocus();
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus!;
    expect(
      focused.context?.findAncestorWidgetOfExactType<TextButton>()?.key,
      SomethingToPlaySection.reshuffleKey,
    );
    return focused;
  }

  /// Every node in the semantics tree labelled [label]. Walked, because
  /// `tester.getSemantics` returns the nearest node at or above a widget, and
  /// the point here is whether the node exists at all.
  List<SemanticsNode> nodesLabelled(WidgetTester tester, String label) {
    final found = <SemanticsNode>[];
    bool walk(SemanticsNode node) {
      if (node.getSemanticsData().label == label) found.add(node);
      node.visitChildren(walk);
      return true;
    }

    tester.binding.rootPipelineOwner.visitChildren((owner) {
      final root = owner.semanticsOwner?.rootSemanticsNode;
      if (root != null) walk(root);
    });
    return found;
  }

  testWidgets('heading, covers, Reshuffle', (tester) async {
    final handle = tester.ensureSemantics();
    poolHolds(['g-1', 'g-2']);

    await show(tester);

    expect(
      tester.widget<Text>(find.byKey(SomethingToPlaySection.headingKey)).data,
      'Something to play',
    );
    expect(cover('g-1'), findsOneWidget);
    expect(cover('g-2'), findsOneWidget);
    // The cover is the tile, and the title is its name, not drawn text.
    expect(find.bySemanticsLabel('Game g-1'), findsOneWidget);
    expect(find.text('Game g-1'), findsNothing);
    expect(
      find.descendant(of: reshuffle, matching: find.text('Reshuffle')),
      findsOneWidget,
    );
    expect(find.byKey(SomethingToPlaySection.loadingKey), findsNothing);
    handle.dispose();
  });

  testWidgets('a spinner under the heading while the first draw runs, and no '
      'Reshuffle yet', (tester) async {
    final answer = Completer<GamePoolSample>();
    pool.onSample = (_) => answer.future;

    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.byKey(SomethingToPlaySection.headingKey), findsOneWidget);
    expect(find.byKey(SomethingToPlaySection.loadingKey), findsOneWidget);
    expect(reshuffle, findsNothing);

    answer.complete(poolOf(['g-1']));
    await tester.pumpAndSettle();

    expect(find.byKey(SomethingToPlaySection.loadingKey), findsNothing);
    expect(reshuffle, findsOneWidget);
  });

  testWidgets('the spinner can be read, and is not announced: this section is '
      'offered together with "Recently added", which announces it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final answer = Completer<GamePoolSample>();
    pool.onSample = (_) => answer.future;

    await tester.pumpWidget(harness());
    await tester.pump();

    final node = nodesLabelled(tester, 'Loading games\u{2026}').single;
    expect(node, isSemantics(isLiveRegion: false));

    answer.complete(poolOf(['g-1']));
    await tester.pumpAndSettle();
    handle.dispose();
  });

  testWidgets('Reshuffle draws again, and shows the new rows', (tester) async {
    poolHolds(['g-1']);
    await show(tester);

    poolHolds(['g-2']);
    await tester.tap(reshuffle);
    await tester.pumpAndSettle();

    expect(cover('g-1'), findsNothing);
    expect(cover('g-2'), findsOneWidget);
  });

  testWidgets('uncovering does not draw again', (tester) async {
    poolHolds(['g-1']);
    await show(tester);
    expect(pool.reads, hasLength(1));

    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(pool.reads, hasLength(1));
    expect(cover('g-1'), findsOneWidget);
  });

  group('uncovering with nothing up', () {
    /// Covers the home page with another screen, and uncovers it.
    Future<void> coverAndUncover(WidgetTester tester) async {
      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
    }

    testWidgets('draws again when the server has filled since, and the row '
        'comes up', (tester) async {
      remote.onFetchRandom = (_) async => const [];
      await show(tester);
      expect(find.byKey(SomethingToPlaySection.headingKey), findsNothing);
      expect(remote.calls, ['fetchRandom(10)']);

      remote.onFetchRandom = (_) async => [summary('g-1')];
      await coverAndUncover(tester);

      expect(find.byKey(SomethingToPlaySection.headingKey), findsOneWidget);
      expect(cover('g-1'), findsOneWidget);
      expect(reshuffle, findsOneWidget);
      expect(remote.calls, ['fetchRandom(10)', 'fetchRandom(10)']);
    });

    testWidgets('draws again after a first draw that failed while online', (
      tester,
    ) async {
      pool.onSample = (_) async => throw StateError('blip');
      remote.onFetchRandom = (_) async => throw unreachable();
      await show(tester);
      expect(find.byKey(SomethingToPlaySection.headingKey), findsNothing);

      poolHolds(['g-1']);
      await coverAndUncover(tester);

      expect(find.byKey(SomethingToPlaySection.headingKey), findsOneWidget);
      expect(cover('g-1'), findsOneWidget);
      expect(pool.reads, hasLength(2));
    });

    testWidgets('still nothing, it stays blank', (tester) async {
      remote.onFetchRandom = (_) async => const [];
      await show(tester);

      await coverAndUncover(tester);

      expect(remote.calls, ['fetchRandom(10)', 'fetchRandom(10)']);
      expect(find.byType(BgeShelf), findsNothing);
    });
  });

  testWidgets('Reshuffle keeps focus while it reads', (tester) async {
    poolHolds([for (var n = 0; n < 10; n++) 'g-$n']);
    await show(tester);
    final focused = await focusReshuffle(tester);
    final element = tester.element(reshuffle);

    final first = Completer<GamePoolSample>();
    final second = Completer<GamePoolSample>();
    final answers = [first, second];
    pool.onSample = (_) => answers.removeAt(0).future;

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(focused));
    expect(
      tester.widget<TextButton>(reshuffle).enabled,
      isTrue,
      reason: 'a disabled button drops the focus it holds (#607)',
    );

    // Pressed again before the answer lands: only the last answer shows.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pool.reads, hasLength(3));
    expect(FocusManager.instance.primaryFocus, same(focused));

    second.complete(poolOf(['last']));
    await tester.pumpAndSettle();
    first.complete(poolOf(['older']));
    await tester.pumpAndSettle();

    expect(cover('last'), findsOneWidget);
    expect(cover('older'), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(focused));
    expect(tester.element(reshuffle), same(element));
  });

  testWidgets('a reshuffle announces catalogReshuffled, and returns the row to '
      'its start', (tester) async {
    final handle = tester.ensureSemantics();
    poolHolds([for (var n = 0; n < 10; n++) 'g-$n']);
    await show(tester);

    final row = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(BgeShelf),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(BgeShelf.nextKey));
    await tester.pumpAndSettle();
    expect(row.position.pixels, greaterThan(0));
    expect(nodesLabelled(tester, _reshuffled), isEmpty);

    await tester.tap(reshuffle);
    await tester.pumpAndSettle();

    expect(row.position.pixels, 0);
    expect(nodesLabelled(tester, _reshuffled), hasLength(1));
    handle.dispose();
  });

  group('the announcement', () {
    testWidgets('the first draw has none', (tester) async {
      final handle = tester.ensureSemantics();
      poolHolds(['g-1']);

      await show(tester);

      expect(nodesLabelled(tester, _reshuffled), isEmpty);
      handle.dispose();
    });

    testWidgets('a reshuffle puts a live node in the tree, of a real size', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      poolHolds(['g-1']);
      await show(tester);

      await tester.tap(reshuffle);
      await tester.pumpAndSettle();

      final node = nodesLabelled(tester, _reshuffled).single;
      final data = node.getSemanticsData();
      expect(data.flagsCollection.isLiveRegion, isTrue);
      expect(node.rect.isEmpty, isFalse, reason: 'empty nodes are dropped');
      expect(node.isInvisible, isFalse);
      expect(node.isMergedIntoParent, isFalse);
      handle.dispose();
    });

    testWidgets('a further reshuffle makes a new node, which is what a screen '
        'reader reads out', (tester) async {
      final handle = tester.ensureSemantics();
      poolHolds(['g-1']);
      await show(tester);

      await tester.tap(reshuffle);
      await tester.pumpAndSettle();
      final first = nodesLabelled(tester, _reshuffled).single;

      await tester.tap(reshuffle);
      await tester.pumpAndSettle();
      final second = nodesLabelled(tester, _reshuffled).single;

      expect(second.id, isNot(first.id));
      expect(second.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    testWidgets('no announcement while the draw is still out', (tester) async {
      final handle = tester.ensureSemantics();
      poolHolds(['g-1']);
      await show(tester);

      final answer = Completer<GamePoolSample>();
      pool.onSample = (_) => answer.future;
      await tester.tap(reshuffle);
      await tester.pump();

      expect(nodesLabelled(tester, _reshuffled), isEmpty);

      answer.complete(poolOf(['g-2']));
      await tester.pumpAndSettle();
      expect(nodesLabelled(tester, _reshuffled), hasLength(1));
      handle.dispose();
    });

    testWidgets('it takes no focus stop', (tester) async {
      final handle = tester.ensureSemantics();
      poolHolds(['g-1']);
      await show(tester, onOpen: (_, _) {});
      await tester.tap(reshuffle);
      await tester.pumpAndSettle();

      expect(
        nodesLabelled(tester, _reshuffled).single,
        isSemantics(isFocusable: false, hasTapAction: false),
      );

      // From Reshuffle, the next stop is the row's first cover.
      await focusReshuffle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<BgeCoverTile>()
            ?.key,
        SomethingToPlaySection.coverKey('g-1'),
      );
      handle.dispose();
    });

    testWidgets('it shifts nothing', (tester) async {
      poolHolds(['g-1']);
      await show(tester);
      final section = tester.getRect(find.byType(SomethingToPlaySection));
      final button = tester.getRect(reshuffle);
      final heading = tester.getRect(
        find.byKey(SomethingToPlaySection.headingKey),
      );

      await tester.tap(reshuffle);
      await tester.pumpAndSettle();

      expect(tester.getRect(find.byType(SomethingToPlaySection)), section);
      expect(tester.getRect(reshuffle), button);
      expect(
        tester.getRect(find.byKey(SomethingToPlaySection.headingKey)),
        heading,
      );
    });

    testWidgets('a press on Reshuffle is still a press on Reshuffle, wherever '
        'it lands', (tester) async {
      poolHolds(['g-1']);
      await show(tester);
      await tester.tap(reshuffle);
      await tester.pumpAndSettle();
      expect(pool.reads, hasLength(2));

      // Inside the node, which is _announcementExtent square at this corner.
      await tester.tapAt(tester.getTopLeft(reshuffle) + const Offset(0.5, 0.5));
      await tester.pumpAndSettle();

      expect(pool.reads, hasLength(3));
    });
  });

  testWidgets('own games and households reach the draw, and the households '
      'stream is asked for once', (tester) async {
    final own = FakeOwnGames();
    addTearDown(own.close);
    final households = StreamController<List<Household>>.broadcast();
    addTearDown(households.close);
    var asked = 0;
    remote.onFetchRandom = (_) async => [summary('r-1')];

    await tester.pumpWidget(
      harness(
        collection: own,
        households: () {
          asked++;
          return households.stream;
        },
      ),
    );
    await tester.pump();
    expect(find.byKey(SomethingToPlaySection.loadingKey), findsOneWidget);

    own.emit(const []);
    households.add(const []);
    await tester.pumpAndSettle();
    expect(cover('r-1'), findsOneWidget);

    poolHolds(['p-1']);
    households.add([household('h-1')]);
    await tester.pumpAndSettle();
    expect(cover('p-1'), findsOneWidget);

    own.emit([ownItem('o-1')]);
    await tester.tap(reshuffle);
    await tester.pumpAndSettle();
    expect(cover('o-1'), findsOneWidget);
    expect(asked, 1);
  });

  testWidgets('tapping a cover calls onOpen with its seed', (tester) async {
    poolHolds(['g-1', 'g-2']);
    final opened = <GameQuickLookSeed>[];
    await show(tester, onOpen: (_, seed) => opened.add(seed));

    await tester.tap(cover('g-2'));

    final seed = opened.single;
    expect(seed.id, 'g-2');
    expect(seed.title, 'Game g-2');
    // The row is a summary, so the facts wait for the quick look's read.
    expect(seed.game, isNull);
  });

  testWidgets('a game found gone comes down with the row where it was', (
    tester,
  ) async {
    final gone = StreamController<String>.broadcast();
    addTearDown(gone.close);
    poolHolds([for (var n = 0; n < 10; n++) 'g-$n']);
    await show(tester, gone: gone.stream);
    final row = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(BgeShelf),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(BgeShelf.nextKey));
    await tester.pumpAndSettle();
    final moved = row.position.pixels;

    gone.add('g-3');
    await tester.pumpAndSettle();

    expect(cover('g-3'), findsNothing);
    expect(row.position.pixels, greaterThan(moved / 2));
    expect(pool.reads, hasLength(1));
  });

  testWidgets('Nothing draws nothing', (tester) async {
    pool.onSample = (_) async => throw StateError('no pool');
    remote.onFetchRandom = (_) async => throw unreachable();

    await show(tester);

    expect(find.byType(BgeShelf), findsNothing);
    expect(find.byKey(SomethingToPlaySection.headingKey), findsNothing);
    expect(reshuffle, findsNothing);
    expect(tester.getSize(find.byType(SomethingToPlaySection)).height, 0);
  });

  group('a reshuffle that finds nothing', () {
    ScrollableState rowOf(WidgetTester tester) => tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(BgeShelf),
        matching: find.byType(Scrollable),
      ),
    );

    testWidgets('offline, the rows and the focus on Reshuffle stay, and the '
        'next reconnect draws again', (tester) async {
      final handle = tester.ensureSemantics();
      poolHolds([for (var n = 0; n < 10; n++) 'g-$n']);
      await show(tester);
      final focused = await focusReshuffle(tester);
      final element = tester.element(reshuffle);

      connectivity.change(ConnectivityState.offline);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(cover('g-0'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(focused));
      expect(tester.element(reshuffle), same(element));
      expect(nodesLabelled(tester, _reshuffled), isEmpty);

      poolHolds(['new']);
      connectivity.change(ConnectivityState.online);
      await tester.pumpAndSettle();

      expect(cover('new'), findsOneWidget);
      expect(cover('g-0'), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(focused));
      expect(nodesLabelled(tester, _reshuffled), hasLength(1));
      handle.dispose();
    });

    testWidgets('with every read failing, the row stays where it is and '
        'nothing new is announced', (tester) async {
      final handle = tester.ensureSemantics();
      poolHolds([for (var n = 0; n < 10; n++) 'g-$n']);
      await show(tester);
      await tester.tap(reshuffle);
      await tester.pumpAndSettle();
      final announced = nodesLabelled(tester, _reshuffled).single.id;
      await tester.tap(find.byKey(BgeShelf.nextKey));
      await tester.pumpAndSettle();
      final moved = rowOf(tester).position.pixels;
      expect(moved, greaterThan(0));

      pool.onSample = (_) async => throw StateError('no pool');
      remote.onFetchRandom = (_) async => throw unreachable();
      await tester.tap(reshuffle);
      await tester.pumpAndSettle();

      expect(rowOf(tester).position.pixels, moved);
      expect(nodesLabelled(tester, _reshuffled).single.id, announced);
      expect(cover('g-0'), findsOneWidget);

      // And a press after it still draws.
      poolHolds(['new']);
      await tester.tap(reshuffle);
      await tester.pumpAndSettle();

      expect(cover('new'), findsOneWidget);
      expect(nodesLabelled(tester, _reshuffled).single.id, isNot(announced));
      handle.dispose();
    });

    testWidgets('a complete empty answer takes the section down, focus with '
        'it, and Tab starts again from the top of the page', (tester) async {
      poolHolds(['g-1']);
      await show(tester);
      final focused = await focusReshuffle(tester);

      poolHolds(const []);
      remote.onFetchRandom = (_) async => const [];
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(BgeShelf), findsNothing);
      final fallen = FocusManager.instance.primaryFocus;
      expect(fallen, isNot(same(focused)));
      expect(fallen, isA<FocusScopeNode>(), reason: "the route's scope");

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<TextButton>()
            ?.key,
        before,
      );
    });
  });

  // Home composes this row in `BgeApp`, so `HomeScreen`'s own audit hosts a
  // placeholder in its place; the row is audited here, in the column home
  // puts its sections in (#50). With nothing to show it draws nothing, a
  // failed draw included, so neither has a call.
  group('accessibility audit', () {
    /// The row, with the pool answering its first draw, which it makes as it
    /// is built, with [answer].
    Widget Function(ThemeData) answering(
      Future<GamePoolSample> Function() answer,
    ) => (theme) {
      pool.onSample = (_) => answer();
      return harness(theme: theme, onOpen: (_, _) {});
    };

    // The first draw never answers: the spinner never settles.
    auditScreen(
      'loading',
      build: answering(() => Completer<GamePoolSample>().future),
      arrange: (tester) async {
        expect(find.byKey(SomethingToPlaySection.loadingKey), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'ready',
      build: answering(() async => poolOf(['g-1', 'g-2'])),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(cover('g-1'), findsOneWidget);
        expect(reshuffle, findsOneWidget);
      },
    );

    // A reshuffle that landed puts its live node beside the button.
    auditScreen(
      'ready, reshuffled',
      build: answering(() async => poolOf(['g-1'])),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        poolHolds(['g-2']);
        await tester.tap(reshuffle);
        await tester.pumpAndSettle();
        expect(cover('g-2'), findsOneWidget);
        expect(nodesLabelled(tester, _reshuffled), hasLength(1));
      },
    );
  });
}
