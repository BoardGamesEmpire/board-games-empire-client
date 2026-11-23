import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

/// The quick look a cover opens (#707): what the caller holds at once, and
/// the rest when the read lands.
void main() {
  late FakeGamesRemote remote;
  late Completer<GameWithPlatformGames> read;
  late List<String> viewed;

  setUp(() {
    // Made as the read starts, in the test's fake-async zone. Made here, it
    // would complete in the real zone, which pumping never runs.
    remote = FakeGamesRemote()
      ..onFetchGame = (_) => (read = Completer()).future;
    viewed = [];
  });

  /// Many lines of one paragraph at any width these tests use.
  final long = List.filled(80, 'word').join(' ');

  final wingspan = Game(
    id: 'g_wingspan',
    title: 'Wingspan',
    description: 'Attract **birds** to your wildlife preserves.\n\n$long',
    publishYear: 2016,
    minPlayers: 1,
    maxPlayers: 5,
    minPlayTime: 30,
    maxPlayTime: 45,
    minAge: 10,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  PlatformGame platformGame(String id, String name) => PlatformGame(
    id: id,
    gameId: 'g_wingspan',
    platformId: 'plat_$id',
    platformName: name,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  final tabletop = platformGame('pg_1', 'Tabletop');
  final steam = platformGame('pg_2', 'Steam');

  /// What "Something to play" holds: the title and images, and no facts.
  const summary = GameSummary(id: 'g_wingspan', title: 'Wingspan');

  /// Wingspan's players, play time and age, as shown.
  const wingspanFacts = '1–5 players · Play time 30–45 min · Ages 10+';

  /// A button on a page that opens [seed]'s quick look, as a cover does.
  Widget opener(
    GameQuickLookSeed seed, {
    GameRepository? cache,
    void Function(String gameId)? onGone,
    void Function(BuildContext context, String gameId)? onViewDetails,
    List<Widget> sections = const [],
    List<Widget> actions = const [],
    WatchOwnedEntries? watchOwned,
  }) => Builder(
    builder: (context) => TextButton(
      onPressed: () => unawaited(
        showGameQuickLook(
          context,
          seed: seed,
          remote: remote,
          cache: cache,
          onGone: onGone,
          onViewDetails: onViewDetails,
          sections: sections,
          actions: actions,
          watchOwned: watchOwned,
        ),
      ),
      child: const Text('open'),
    ),
  );

  /// Opens [seed]'s quick look from a page. View full details records the
  /// game's id in `viewed`, unless [viewDetails] is false.
  Future<void> open(
    WidgetTester tester,
    GameQuickLookSeed seed, {
    GameRepository? cache,
    void Function(String gameId)? onGone,
    bool viewDetails = true,
    List<Widget> sections = const [],
    List<Widget> actions = const [],
    WatchOwnedEntries? watchOwned,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        theme: theme,
        Scaffold(
          body: Center(
            child: opener(
              seed,
              cache: cache,
              onGone: onGone,
              onViewDetails: viewDetails ? (_, id) => viewed.add(id) : null,
              sections: sections,
              actions: actions,
              watchOwned: watchOwned,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The facts line's text, as shown.
  String? factsShown(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(GameQuickLook.factsKey),
          matching: find.byType(Text),
        ),
      )
      .data;

  Finder cover() => find.descendant(
    of: find.byType(GameQuickLook),
    matching: find.byType(BgeThumbnail),
  );

  Finder retry() => find.descendant(
    of: find.byKey(GameQuickLook.partialKey),
    matching: find.byType(TextButton),
  );

  testWidgets("the cover draws the game's whole image, not a crop", (
    tester,
  ) async {
    await open(tester, GameQuickLookSeed.fromSummary(summary));

    expect(tester.widget<BgeThumbnail>(cover()).whole, isTrue);
  });

  testWidgets('while the read runs it shows the seed', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, GameQuickLookSeed.fromSummary(summary));

    expect(remote.calls, ['fetchGame(g_wingspan)']);
    expect(find.text('Wingspan'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Wingspan')),
      isSemantics(label: 'Wingspan', isHeader: true),
    );
    expect(cover(), findsOneWidget);
    expect(find.byKey(GameQuickLook.factsKey), findsNothing);
    expect(find.byKey(GameQuickLook.platformsKey), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(GameQuickLook.viewDetailsKey))
          .enabled,
      isTrue,
    );

    handle.dispose();
  });

  testWidgets('when the read lands it shows year, players, time, age, '
      'platform chips and the whole description', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, GameQuickLookSeed.fromSummary(summary));

    read.complete((game: wingspan, platformGames: [tabletop, steam]));
    await tester.pumpAndSettle();

    // The year is in the header, beside the cover with the title.
    final year = find.text('Published 2016');
    expect(year, findsOneWidget);
    expect(
      tester.getTopLeft(year).dx,
      greaterThan(tester.getTopRight(cover()).dx),
    );
    expect(factsShown(tester), wingspanFacts);

    final chips = find.descendant(
      of: find.byKey(GameQuickLook.platformsKey),
      matching: find.byType(Chip),
    );
    expect(chips, findsNWidgets(2));
    for (final name in ['Tabletop', 'Steam']) {
      expect(
        find.descendant(of: chips, matching: find.text(name)),
        findsOneWidget,
      );
      expect(
        tester
            .getSemantics(find.text(name))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
        reason: '$name has no tap action',
      );
    }

    expect(find.byType(GameDescription), findsOneWidget);
    expect(find.textContaining('birds', findRichText: true), findsOneWidget);
    expect(find.text('More'), findsNothing);

    handle.dispose();
  });

  testWidgets("the header takes the read's title, and its cover when the "
      'seed has none', (tester) async {
    await open(
      tester,
      GameQuickLookSeed.fromSummary(
        const GameSummary(id: 'g_wingspan', title: 'Wingspn'),
      ),
    );
    expect(find.text('Wingspn'), findsOneWidget);
    expect(tester.widget<BgeThumbnail>(cover()).url, isNull);

    read.complete((
      game: wingspan.copyWith(
        subtitle: 'Asia',
        thumbnail: 'https://example.test/wingspan.jpg',
      ),
      platformGames: const <PlatformGame>[],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Wingspn'), findsNothing);
    expect(find.text('Wingspan'), findsOneWidget);
    expect(find.text('Asia'), findsOneWidget);
    expect(
      tester.widget<BgeThumbnail>(cover()).url,
      'https://example.test/wingspan.jpg',
    );
  });

  testWidgets('a seed with a full Game shows its facts at once', (
    tester,
  ) async {
    await open(tester, GameQuickLookSeed.fromGame(wingspan));

    expect(read.isCompleted, isFalse);
    expect(find.text('Published 2016'), findsOneWidget);
    expect(factsShown(tester), wingspanFacts);
    expect(find.byType(GameDescription), findsOneWidget);
    // Only the read knows the platforms.
    expect(find.byKey(GameQuickLook.platformsKey), findsNothing);
  });

  testWidgets('no control adds to the collection', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, GameQuickLookSeed.fromSummary(summary));
    read.complete((game: wingspan, platformGames: [tabletop, steam]));
    await tester.pumpAndSettle();

    final collection = RegExp('collection', caseSensitive: false);
    expect(find.textContaining(collection), findsNothing);
    expect(find.semantics.byLabel(collection), findsNothing);
    expect(find.byKey(GameQuickLook.platformsKey), findsOneWidget);

    handle.dispose();
  });

  testWidgets('a failed read keeps the seed and says the rest is '
      'unavailable', (tester) async {
    remote.onFetchGame = (_) async => throw unreachable();
    await open(tester, GameQuickLookSeed.fromSummary(summary));

    expect(find.text('Wingspan'), findsOneWidget);
    expect(cover(), findsOneWidget);
    expect(find.byKey(GameQuickLook.partialKey), findsOneWidget);
    expect(find.text("Some details couldn't be loaded."), findsOneWidget);

    await tester.tap(retry());
    await tester.pumpAndSettle();
    await tester.pump(GameQuickLook.retryDwell);

    expect(remote.calls, ['fetchGame(g_wingspan)', 'fetchGame(g_wingspan)']);
  });

  testWidgets('a retry answered at once, as offline, still says it is '
      'trying, and keeps its focus', (tester) async {
    final handle = tester.ensureSemantics();
    remote.onFetchGame = (_) async => throw unreachable();
    await open(
      tester,
      GameQuickLookSeed.fromSummary(summary),
      cache: FakeGamesCache([wingspan]),
    );
    final focus = tester.widget<TextButton>(retry()).focusNode!..requestFocus();
    await tester.pump();

    // The read fails and the cache answers before the next frame.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(GameQuickLook.partialKey),
        matching: find.text('Trying again…'),
      ),
      findsNWidgets(2),
    );
    expect(focus.hasPrimaryFocus, isTrue);

    await tester.pump(GameQuickLook.retryDwell);

    expect(find.text("Some details couldn't be loaded."), findsOneWidget);
    expect(find.text('Trying again…'), findsNothing);
    expect(focus.hasPrimaryFocus, isTrue);
    expect(factsShown(tester), wingspanFacts);
    expect(remote.calls, ['fetchGame(g_wingspan)', 'fetchGame(g_wingspan)']);

    handle.dispose();
  });

  testWidgets('offline with a cached copy shows the cached facts and the '
      'banner, and no platforms', (tester) async {
    remote.onFetchGame = (_) async => throw unreachable();
    await open(
      tester,
      GameQuickLookSeed.fromSummary(summary),
      cache: FakeGamesCache([wingspan]),
    );

    expect(factsShown(tester), wingspanFacts);
    expect(find.text('Published 2016'), findsOneWidget);
    expect(find.byKey(GameQuickLook.partialKey), findsOneWidget);
    expect(find.byKey(GameQuickLook.platformsKey), findsNothing);
  });

  // Newest games reads the server and leaves the cache as it was, so its row
  // can be newer than the cached copy.
  testWidgets('offline with a full seed keeps the seed over an older cached '
      'copy', (tester) async {
    remote.onFetchGame = (_) async => throw unreachable();
    final older = Game(
      id: 'g_wingspan',
      title: 'Wingspan (first printing)',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
    );
    await open(
      tester,
      GameQuickLookSeed.fromGame(wingspan),
      cache: FakeGamesCache([older]),
    );

    expect(find.byKey(GameQuickLook.partialKey), findsOneWidget);
    expect(find.text('Wingspan'), findsOneWidget);
    expect(find.text('Wingspan (first printing)'), findsNothing);
    expect(factsShown(tester), wingspanFacts);
    expect(find.text('Published 2016'), findsOneWidget);
    expect(find.textContaining('wildlife preserves'), findsOneWidget);
  });

  // A quick look's read caches the game, while the list it was opened from
  // keeps the row it read before, so reopened offline the cache is newer.
  testWidgets('offline with a full seed shows a newer cached copy over it', (
    tester,
  ) async {
    remote.onFetchGame = (_) async => throw unreachable();
    final newer = Game(
      id: 'g_wingspan',
      title: 'Wingspan (second edition)',
      publishYear: 2019,
      minPlayers: 1,
      maxPlayers: 5,
      minPlayTime: 40,
      maxPlayTime: 55,
      minAge: 10,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2027),
    );
    await open(
      tester,
      GameQuickLookSeed.fromGame(wingspan),
      cache: FakeGamesCache([newer]),
    );

    expect(find.byKey(GameQuickLook.partialKey), findsOneWidget);
    expect(find.text('Wingspan (second edition)'), findsOneWidget);
    expect(factsShown(tester), '1–5 players · Play time 40–55 min · Ages 10+');
    expect(find.text('Published 2019'), findsOneWidget);
    expect(find.textContaining('wildlife preserves'), findsNothing);
  });

  testWidgets('a retry keeps what is shown, and its button keeps focus, '
      'until the answer comes', (tester) async {
    remote.onFetchGame = (_) async => throw unreachable();
    await open(
      tester,
      GameQuickLookSeed.fromSummary(summary),
      cache: FakeGamesCache([wingspan]),
    );
    final answer = Completer<GameWithPlatformGames>();
    remote.onFetchGame = (_) => answer.future;
    final focus = tester.widget<TextButton>(retry()).focusNode!..requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // The banner's message and the retry's label.
    expect(
      find.descendant(
        of: find.byKey(GameQuickLook.partialKey),
        matching: find.text('Trying again…'),
      ),
      findsNWidgets(2),
    );
    expect(focus.hasPrimaryFocus, isTrue);
    expect(factsShown(tester), wingspanFacts);

    // Past the dwell, so the answer shows as it lands.
    await tester.pump(GameQuickLook.retryDwell);
    answer.completeError(unreachable());
    await tester.pumpAndSettle();

    expect(find.text("Some details couldn't be loaded."), findsOneWidget);
    expect(focus.hasPrimaryFocus, isTrue);
    expect(factsShown(tester), wingspanFacts);
    expect(remote.calls, ['fetchGame(g_wingspan)', 'fetchGame(g_wingspan)']);
  });

  testWidgets("a game the server refuses says it's unavailable, and onGone "
      'hears its id', (tester) async {
    remote.onFetchGame = (_) async =>
        throw const GamesForbiddenException('403');
    final gone = <String>[];
    await open(
      tester,
      GameQuickLookSeed.fromSummary(summary),
      onGone: gone.add,
    );

    expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
    expect(
      find.text('It may have been removed, or it may not be shared with you.'),
      findsOneWidget,
    );
    expect(find.text('Wingspan'), findsOneWidget);
    expect(find.byKey(GameQuickLook.partialKey), findsNothing);
    expect(gone, ['g_wingspan']);
  });

  testWidgets('a game the server refuses shows the unavailable banner and '
      "none of the caller's sections or actions (#1040)", (tester) async {
    remote.onFetchGame = (_) async =>
        throw const GamesForbiddenException('403');
    await open(
      tester,
      GameQuickLookSeed.fromSummary(summary),
      sections: [const Text('extra section')],
      actions: [TextButton(onPressed: () {}, child: const Text('Import'))],
    );

    expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
    expect(find.text('extra section'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Import'), findsNothing);
    // What the quick look itself offers stays.
    expect(find.byKey(GameQuickLook.viewDetailsKey), findsOneWidget);
  });

  testWidgets("View full details calls onViewDetails with the game's id", (
    tester,
  ) async {
    await open(tester, GameQuickLookSeed.fromSummary(summary));

    await tester.tap(find.byKey(GameQuickLook.viewDetailsKey));
    await tester.pumpAndSettle();

    expect(viewed, ['g_wingspan']);
    // Left open: the page pushed over it takes it away once it has arrived.
    expect(find.byType(GameQuickLook), findsOneWidget);
  });

  testWidgets('without onViewDetails there is no View full details', (
    tester,
  ) async {
    await open(
      tester,
      GameQuickLookSeed.fromSummary(summary),
      viewDetails: false,
      actions: [TextButton(onPressed: () {}, child: const Text('Import'))],
    );

    // Not disabled: there is nowhere to open it, and won't be.
    expect(find.text('Import'), findsOneWidget);
    expect(find.byKey(GameQuickLook.viewDetailsKey), findsNothing);
  });

  testWidgets("View full details still opens after the caller's widget is "
      'gone', (tester) async {
    final showCaller = ValueNotifier(true);
    addTearDown(showCaller.dispose);
    bool? mountedWhenPressed;
    await tester.pumpWidget(
      catalogApp(
        Scaffold(
          body: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: showCaller,
              builder: (_, show, _) => show
                  ? opener(
                      GameQuickLookSeed.fromSummary(summary),
                      onViewDetails: (context, gameId) {
                        mountedWhenPressed = context.mounted;
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                Scaffold(body: Text('Details of $gameId')),
                          ),
                        );
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final caller = tester.element(find.text('open'));

    // As a refused read takes its cover down from the home shelves.
    showCaller.value = false;
    await tester.pumpAndSettle();
    expect(caller.mounted, isFalse);

    await tester.tap(find.byKey(GameQuickLook.viewDetailsKey));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(mountedWhenPressed, isTrue);
    expect(find.text('Details of g_wingspan'), findsOneWidget);
  });

  testWidgets('View full details pressed twice while the page arrives pushes '
      'one page', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      catalogApp(
        Scaffold(
          body: Center(
            child: opener(
              GameQuickLookSeed.fromSummary(summary),
              onViewDetails: (context, gameId) {
                opened.add(gameId);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(body: Text('Details of $gameId')),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The second press lands while the page is still arriving. A tap would
    // miss: the page's route already takes the pointer. A screen reader or a
    // key press reaches the button's callback all the same, so call it.
    final onPressed = tester
        .widget<FilledButton>(find.byKey(GameQuickLook.viewDetailsKey))
        .onPressed!;
    onPressed();
    await tester.pump();
    onPressed();
    await tester.pump();

    expect(opened, ['g_wingspan']);

    // Back lands where the quick look was opened, not on a second copy.
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.text('Details of g_wingspan', skipOffstage: false),
      findsNothing,
    );
    expect(find.byType(GameQuickLook), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  group('a page popped on its way leaves View full details working', () {
    /// A page for [gameId], standing in for the game's detail page.
    Route<void> detailsPage(String gameId) => MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: Text('Details of $gameId')),
    );

    /// Presses View full details, pops the page halfway through its
    /// entrance, and presses it again: it opens the page again, and that one
    /// takes the quick look away once it has arrived.
    Future<void> popOnItsWayThenAgain(
      WidgetTester tester,
      List<String> opened,
      NavigatorState Function() pagesNavigator,
    ) async {
      final viewDetails = find.byKey(GameQuickLook.viewDetailsKey);
      await tester.ensureVisible(viewDetails);
      await tester.tap(viewDetails);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Details of g_wingspan'), findsOneWidget);

      pagesNavigator().pop();
      await tester.pumpAndSettle();
      expect(find.text('Details of g_wingspan'), findsNothing);
      // Never covered, so still there.
      expect(find.byType(GameQuickLook), findsOneWidget);

      await tester.ensureVisible(viewDetails);
      await tester.tap(viewDetails);
      await tester.pumpAndSettle();

      expect(opened, ['g_wingspan', 'g_wingspan']);
      expect(find.text('Details of g_wingspan'), findsOneWidget);
      expect(find.byType(GameQuickLook, skipOffstage: false), findsNothing);
    }

    testWidgets("on the pop-up's own navigator", (tester) async {
      final opened = <String>[];
      late NavigatorState pages;
      await tester.pumpWidget(
        catalogApp(
          Scaffold(
            body: Center(
              child: opener(
                GameQuickLookSeed.fromSummary(summary),
                onViewDetails: (context, gameId) {
                  opened.add(gameId);
                  pages = Navigator.of(context)..push(detailsPage(gameId));
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await popOnItsWayThenAgain(tester, opened, () => pages);
    });

    testWidgets('on a nested navigator, beneath the pop-up', (tester) async {
      final nested = GlobalKey<NavigatorState>();
      final observer = BgePopupCoverObserver();
      final opened = <String>[];
      await tester.pumpWidget(
        catalogApp(
          Navigator(
            key: nested,
            observers: [observer],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: Center(
                  child: opener(
                    GameQuickLookSeed.fromSummary(summary),
                    onViewDetails: (_, gameId) {
                      opened.add(gameId);
                      nested.currentState!.push(detailsPage(gameId));
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await popOnItsWayThenAgain(tester, opened, () => nested.currentState!);
    });
  });

  testWidgets("a caller's sections and actions are shown", (tester) async {
    await open(
      tester,
      GameQuickLookSeed.fromGame(wingspan),
      sections: [const Text('extra section')],
      actions: [TextButton(onPressed: () {}, child: const Text('Import'))],
    );

    expect(
      tester.getTopLeft(find.text('extra section')).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(GameDescription)).dy,
      ),
    );

    final import = find.widgetWithText(TextButton, 'Import');
    final details = find.byKey(GameQuickLook.viewDetailsKey);
    final bar = find.ancestor(of: details, matching: find.byType(OverflowBar));
    expect(find.descendant(of: bar, matching: import), findsOneWidget);
    expect(
      tester.getCenter(import).dy,
      moreOrLessEquals(tester.getCenter(details).dy, epsilon: 1),
    );
    expect(tester.getCenter(import).dx, lessThan(tester.getCenter(details).dx));
  });

  testWidgets('a long description is shown whole, with no More or Less', (
    tester,
  ) async {
    const view = Size(320, 640);
    useViewSize(tester, view);
    final handle = tester.ensureSemantics();
    final paragraphs = [
      for (var i = 1; i <= 6; i++) 'Paragraph $i. $long',
      'The last paragraph.',
    ];
    final described = wingspan.copyWith(description: paragraphs.join('\n\n'));
    remote.onFetchGame = (_) async =>
        (game: described, platformGames: [tabletop, steam]);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: view,
          textScaler: TextScaler.linear(2),
        ),
        child: catalogApp(
          Scaffold(
            body: Center(
              child: opener(
                GameQuickLookSeed.fromGame(described),
                onViewDetails: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);

    // Nothing to press to see the rest: only scrolling.
    expect(find.text('More'), findsNothing);
    expect(find.text('Less'), findsNothing);

    final last = find.textContaining('The last paragraph.', findRichText: true);
    await tester.scrollUntilVisible(
      last,
      100,
      scrollable: find
          .descendant(
            of: find.byType(GameQuickLook),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();

    final shown = tester.getRect(last);
    expect(shown.top, greaterThanOrEqualTo(0), reason: '$shown');
    expect(shown.bottom, lessThanOrEqualTo(view.height), reason: '$shown');
    expect(last.hitTestable(), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('The last paragraph')), findsOne);
    expect(find.text('More'), findsNothing);
    expect(find.text('Less'), findsNothing);
    expect(tester.takeException(), isNull);

    handle.dispose();
  });

  testWidgets('a screen reader reaches every paragraph of the description', (
    tester,
  ) async {
    // Tall enough that every paragraph is on stage, as a screen reader
    // scrolling the page would bring each one.
    useViewSize(tester, const Size(800, 4000));
    final handle = tester.ensureSemantics();
    final paragraphs = [
      for (var i = 1; i <= 4; i++)
        'Paragraph $i. ${List.filled(20, 'w').join(' ')}',
    ];
    final described = wingspan.copyWith(description: paragraphs.join('\n\n'));
    await open(tester, GameQuickLookSeed.fromGame(described));

    final ids = <int>{};
    for (var i = 1; i <= paragraphs.length; i++) {
      final node = find.semantics.byLabel(RegExp('^Paragraph $i\\.'));
      expect(node, findsOne, reason: 'paragraph $i has a node of its own');
      final heard = node.evaluate().single;
      final label = heard.label;
      for (var other = 1; other <= paragraphs.length; other++) {
        if (other == i) continue;
        expect(label, isNot(contains('Paragraph $other.')));
      }
      ids.add(heard.id);
    }
    expect(ids, hasLength(paragraphs.length));

    handle.dispose();
  });

  testWidgets('a link in the description opens outside the app', (
    tester,
  ) async {
    useViewSize(tester, const Size(800, 1200));
    final opened = <Uri>[];
    final linked = wingspan.copyWith(
      description: 'Rules at [the rulebook](https://example.test/rules).',
    );
    remote.onFetchGame = (_) async =>
        (game: linked, platformGames: const <PlatformGame>[]);
    await tester.pumpWidget(
      catalogApp(
        Scaffold(
          body: SizedBox(
            height: 900,
            child: GameQuickLook(
              seed: GameQuickLookSeed.fromGame(linked),
              remote: remote,
              openLink: (uri) async => opened.add(uri),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('the rulebook'));
    await tester.pump();

    expect(opened, [Uri.parse('https://example.test/rules')]);
  });

  testWidgets('on a 320dp phone the title sits beside the cover at 1.0 text, '
      'and under it at 2.0', (tester) async {
    const view = Size(320, 640);
    useViewSize(tester, view);
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: view,
            textScaler: TextScaler.linear(scale),
          ),
          child: catalogApp(
            Scaffold(
              body: Center(child: opener(GameQuickLookSeed.fromGame(wingspan))),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final title = tester.getRect(find.text('Wingspan'));
      final shown = tester.getRect(cover());
      if (scale == 1) {
        expect(title.left, greaterThan(shown.right), reason: 'at $scale');
      } else {
        // Beside it, the title had too little room, and broke words.
        expect(title.top, greaterThanOrEqualTo(shown.bottom));
      }
      expect(tester.takeException(), isNull);
      // A fresh app for the next scale, with no quick look left open.
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  group('the platforms you own (#799)', () {
    const tabletopOwned = 'Tabletop, in your collection';
    const steamNotOwned = 'Steam, not in your collection';
    const steamOwned = 'Steam, in your collection';

    GameCollection entry(String platformGameId, {DateTime? deletedAt}) =>
        GameCollection(
          id: 'e_$platformGameId',
          userId: 'u_1',
          platformGameId: platformGameId,
          medium: GameMedium.physical,
          deletedAt: deletedAt,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );

    Finder chipOn(String platformGameId) => find.descendant(
      of: find.byKey(GameQuickLook.platformsKey),
      matching: find.byKey(ValueKey(platformGameId)),
    );
    Finder checkOn(String platformGameId) => find.descendant(
      of: chipOn(platformGameId),
      matching: find.byIcon(Icons.check),
    );

    /// The [Chip] drawn for [platformGameId]: the keyed chip itself, or the
    /// one inside an owned chip.
    Chip chipOf(WidgetTester tester, String platformGameId) =>
        tester.widget<Chip>(
          find.descendant(
            of: chipOn(platformGameId),
            matching: find.byType(Chip),
            matchRoot: true,
          ),
        );

    /// Whether the node a screen reader hears as [label] can be pressed.
    bool tappable(WidgetTester tester, String label) => tester
        .getSemantics(find.bySemanticsLabel(label))
        .getSemanticsData()
        .hasAction(SemanticsAction.tap);

    /// Expects the chips plain: no check, and nothing said of ownership.
    void expectPlain(WidgetTester tester) {
      expect(find.byIcon(Icons.check), findsNothing);
      expect(find.bySemanticsLabel(RegExp('collection')), findsNothing);
      expect(find.bySemanticsLabel('Tabletop'), findsOneWidget);
      expect(find.bySemanticsLabel('Steam'), findsOneWidget);
    }

    /// Opens Wingspan's quick look on Tabletop and Steam, watching what the
    /// user owns through the returned controller, and lands the read. Each
    /// set of ids the quick look watches goes in [watched].
    Future<StreamController<List<GameCollection>>> openWatched(
      WidgetTester tester, {
      List<Set<String>>? watched,
      ThemeData? theme,
    }) async {
      // Made in the test's fake-async zone, so its events run as it pumps.
      final owned = StreamController<List<GameCollection>>.broadcast();
      addTearDown(owned.close);
      await open(
        tester,
        GameQuickLookSeed.fromSummary(summary),
        theme: theme,
        watchOwned: (ids) {
          watched?.add(ids);
          return owned.stream;
        },
      );
      read.complete((game: wingspan, platformGames: [tabletop, steam]));
      await tester.pumpAndSettle();
      return owned;
    }

    testWidgets('a chip for a platform you own shows the check and the owned '
        'colour, and is named "Tabletop, in your collection"', (tester) async {
      final handle = tester.ensureSemantics();
      final watched = <Set<String>>[];
      final owned = await openWatched(tester, watched: watched);

      owned.add([entry('pg_1')]);
      await tester.pumpAndSettle();

      expect(watched, [
        {'pg_1', 'pg_2'},
      ]);
      expect(checkOn('pg_1'), findsOneWidget);
      final scheme = Theme.of(tester.element(chipOn('pg_1'))).colorScheme;
      final chip = chipOf(tester, 'pg_1');
      expect(chip.backgroundColor, scheme.primary);
      expect(chip.labelStyle?.color, scheme.onPrimary);
      expect(chip.side, BorderSide.none);
      expect(tester.widget<Icon>(checkOn('pg_1')).color, scheme.onPrimary);
      // Named in full, once: the shown name isn't read again on its own.
      expect(find.bySemanticsLabel(tabletopOwned), findsOneWidget);
      expect(find.bySemanticsLabel('Tabletop'), findsNothing);

      handle.dispose();
    });

    testWidgets("a chip for a platform you don't own is plain and named "
        '"Steam, not in your collection"', (tester) async {
      final handle = tester.ensureSemantics();
      final owned = await openWatched(tester);

      owned.add([entry('pg_1')]);
      await tester.pumpAndSettle();

      expect(checkOn('pg_2'), findsNothing);
      final chip = chipOf(tester, 'pg_2');
      // The theme's, as before ownership was known.
      expect(chip.backgroundColor, isNull);
      expect(chip.labelStyle, isNull);
      expect(chip.avatar, isNull);
      expect(find.bySemanticsLabel(steamNotOwned), findsOneWidget);
      expect(find.bySemanticsLabel('Steam'), findsNothing);

      handle.dispose();
    });

    testWidgets('ownership follows the collection while the quick look is '
        'open', (tester) async {
      final handle = tester.ensureSemantics();
      final watched = <Set<String>>[];
      final owned = await openWatched(tester, watched: watched);

      owned.add([entry('pg_1')]);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(steamNotOwned), findsOneWidget);

      owned.add([entry('pg_1'), entry('pg_2')]);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(steamOwned), findsOneWidget);
      expect(checkOn('pg_2'), findsOneWidget);

      // A copy awaiting removal is no longer owned.
      owned.add([
        entry('pg_1', deletedAt: DateTime.utc(2026, 2)),
        entry('pg_2'),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Tabletop, not in your collection'),
        findsOneWidget,
      );
      expect(checkOn('pg_1'), findsNothing);

      // One watch the whole time, however often the quick look rebuilt.
      expect(watched, hasLength(1));

      handle.dispose();
    });

    testWidgets('until the watch answers, and after it fails, the chips name '
        'no ownership', (tester) async {
      final handle = tester.ensureSemantics();
      final owned = await openWatched(tester);

      expectPlain(tester);

      owned.add([entry('pg_1')]);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(tabletopOwned), findsOneWidget);

      owned.addError(StateError('the collection failed'));
      await tester.pumpAndSettle();
      expectPlain(tester);
      expect(tester.takeException(), isNull);

      handle.dispose();
    });

    testWidgets('without watchOwned the chips name no ownership', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, GameQuickLookSeed.fromSummary(summary));
      read.complete((game: wingspan, platformGames: [tabletop, steam]));
      await tester.pumpAndSettle();

      expect(find.byKey(GameQuickLook.platformsKey), findsOneWidget);
      expectPlain(tester);

      handle.dispose();
    });

    testWidgets('a watch answering after close changes nothing and throws '
        'nothing', (tester) async {
      final owned = await openWatched(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      // The route is still mounted, on its way out.
      await tester.pump();
      expect(find.byType(GameQuickLook), findsOneWidget);
      owned.add([entry('pg_1')]);
      await tester.pumpAndSettle();

      expect(find.byType(GameQuickLook), findsNothing);
      expect(owned.hasListener, isFalse, reason: 'the watch is cancelled');
      owned.add([entry('pg_2')]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the chips do nothing when tapped', (tester) async {
      final handle = tester.ensureSemantics();
      final owned = await openWatched(tester);

      owned.add([entry('pg_1')]);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(GameQuickLook.platformsKey),
          matching: find.byType(ActionChip),
        ),
        findsNothing,
      );
      for (final label in [tabletopOwned, steamNotOwned]) {
        expect(tappable(tester, label), isFalse, reason: label);
      }

      handle.dispose();
    });

    for (final (name, theme) in [
      ('light', BgeTheme.light()),
      ('dark', BgeTheme.dark()),
    ]) {
      testWidgets("the owned chip's label is onPrimary on primary ($name)", (
        tester,
      ) async {
        final owned = await openWatched(tester, theme: theme);

        owned.add([entry('pg_1')]);
        await tester.pumpAndSettle();

        // The pair game_detail_platforms_contrast_test holds to contrast.
        final chip = chipOf(tester, 'pg_1');
        expect(chip.backgroundColor, theme.colorScheme.primary);
        expect(chip.labelStyle?.color, theme.colorScheme.onPrimary);
        expect(
          tester.widget<Icon>(checkOn('pg_1')).color,
          theme.colorScheme.onPrimary,
        );
      });
    }
  });

  group('GameQuickLookSeed', () {
    test('from a game, carries the game', () {
      final seed = GameQuickLookSeed.fromGame(wingspan);

      expect(
        (seed.id, seed.title, seed.game),
        ('g_wingspan', 'Wingspan', wingspan),
      );
    });

    test("from a summary, carries the row's fields and no game", () {
      final seed = GameQuickLookSeed.fromSummary(
        const GameSummary(
          id: 'g_azul',
          title: 'Azul',
          subtitle: 'Summer Pavilion',
          image: 'https://example.com/azul.png',
          thumbnail: 'https://example.com/azul_t.png',
        ),
      );

      expect(
        (
          seed.id,
          seed.title,
          seed.subtitle,
          seed.image,
          seed.thumbnail,
          seed.game,
        ),
        (
          'g_azul',
          'Azul',
          'Summer Pavilion',
          'https://example.com/azul.png',
          'https://example.com/azul_t.png',
          null,
        ),
      );
    });
  });
}
