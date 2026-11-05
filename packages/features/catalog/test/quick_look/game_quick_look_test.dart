import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_catalog/src/widgets/folded_description.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

/// The quick look a cover opens (#707): what the caller holds at once, and
/// the rest when the read lands.
void main() {
  late FakeGamesRemote remote;
  late Completer<GameWithPlatformGames> read;
  late List<String> viewed;

  setUp(() {
    remote = FakeGamesRemote();
    // Made as the read starts, in the test's fake-async zone. Made here, it
    // would complete in the real zone, which pumping never runs.
    remote.onFetchGame = (_) => (read = Completer()).future;
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
  const wingspanFacts = '1–5 players · 30–45 min · Ages 10+';

  /// A button on a page that opens [seed]'s quick look, as a cover does.
  Widget opener(
    GameQuickLookSeed seed, {
    GameRepository? cache,
    void Function(String gameId)? onGone,
    void Function(BuildContext context, String gameId)? onViewDetails,
    List<Widget> sections = const [],
    List<Widget> actions = const [],
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
  }) async {
    await tester.pumpWidget(
      catalogApp(
        Scaffold(
          body: Center(
            child: opener(
              seed,
              cache: cache,
              onGone: onGone,
              onViewDetails: viewDetails ? (_, id) => viewed.add(id) : null,
              sections: sections,
              actions: actions,
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
      'platform chips and the folded description', (tester) async {
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

    expect(find.byType(FoldedDescription), findsOneWidget);
    expect(find.textContaining('birds', findRichText: true), findsOneWidget);
    expect(find.byKey(FoldedDescription.toggleKey), findsOneWidget);

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
    expect(find.byType(FoldedDescription), findsOneWidget);
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
    final focus = tester.widget<TextButton>(retry()).focusNode!;
    focus.requestFocus();
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
    expect(factsShown(tester), '1–5 players · 40–55 min · Ages 10+');
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
    final focus = tester.widget<TextButton>(retry()).focusNode!;
    focus.requestFocus();
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
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  Scaffold(body: Text('Details of $gameId')),
                            ),
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
        tester.getBottomLeft(find.byType(FoldedDescription)).dy,
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

  testWidgets('a long description expands and reads to its end at 2.0 text '
      'on a 320dp phone', (tester) async {
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

    // Folded, a screen reader hears only what is drawn.
    final heard = find.semantics.byLabel(RegExp('The last paragraph'));
    expect(heard, findsNothing);

    final more = find.byKey(FoldedDescription.toggleKey);
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();

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
    expect(heard, findsOne);
    expect(tester.takeException(), isNull);

    handle.dispose();
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
