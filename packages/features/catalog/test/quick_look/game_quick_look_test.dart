import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    Widget? footer,
    QuickLookHost? host,
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
          footer: footer,
          host: host,
          watchOwned: watchOwned,
        ),
      ),
      child: const Text('open'),
    ),
  );

  /// Opens [seed]'s quick look from a page. Its title records the game's id
  /// in `viewed`, unless [viewDetails] is false.
  Future<void> open(
    WidgetTester tester,
    GameQuickLookSeed seed, {
    GameRepository? cache,
    void Function(String gameId)? onGone,
    bool viewDetails = true,
    List<Widget> sections = const [],
    List<Widget> actions = const [],
    Widget? footer,
    QuickLookHost? host,
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
              footer: footer,
              host: host,
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

  /// The title, as the link to the game's page.
  Finder titleLink() => find.byKey(GameQuickLook.titleLinkKey);

  /// The title link's focus node.
  FocusNode titleFocus(WidgetTester tester) =>
      tester.widget<InkWell>(titleLink()).focusNode!;

  /// Tabs until the title has focus, as a keyboard user gets there.
  Future<void> tabToTitle(WidgetTester tester) async {
    final node = titleFocus(tester);
    for (var i = 0; i < 10 && !node.hasPrimaryFocus; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(node.hasPrimaryFocus, isTrue, reason: 'Tab reaches the title');
  }

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
    // The way to the page doesn't wait for the read.
    expect(tester.widget<InkWell>(titleLink()).onTap, isNotNull);

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
    expect(titleLink(), findsOneWidget);
  });

  group('the pinned footer and the host (#1037)', () {
    final footer = find.byKey(GameQuickLook.footerKey);

    /// The quick look's own scroll view, which the footer is pinned under.
    final body = find
        .descendant(
          of: find.byType(GameQuickLook),
          matching: find.byType(Scrollable),
        )
        .first;
    final pinned = find.widgetWithText(FilledButton, 'Pinned');

    Widget pinnedButton() =>
        FilledButton(onPressed: () {}, child: const Text('Pinned'));

    ScrollPosition bodyPosition(WidgetTester tester) =>
        tester.state<ScrollableState>(body).position;

    testWidgets("a caller's footer is pinned below the scroll view, at the "
        "line's end", (tester) async {
      useViewSize(tester, const Size(400, 500));
      await open(
        tester,
        GameQuickLookSeed.fromGame(wingspan),
        footer: pinnedButton(),
      );
      read.complete((game: wingspan, platformGames: [tabletop]));
      await tester.pumpAndSettle();
      final tokens = BgeTokens.of(tester.element(find.byType(GameQuickLook)));

      expect(find.ancestor(of: pinned, matching: footer), findsOneWidget);
      expect(find.descendant(of: body, matching: pinned), findsNothing);
      expect(
        tester.getRect(footer).top,
        moreOrLessEquals(tester.getRect(body).bottom),
      );
      // Inset as the body is at its sides, and by a small step above and
      // below.
      final band = tester.getRect(footer);
      final button = tester.getRect(pinned);
      expect(button.right, moreOrLessEquals(band.right - tokens.spaceMd));
      expect(button.top, moreOrLessEquals(band.top + tokens.spaceSm));
      expect(button.bottom, moreOrLessEquals(band.bottom - tokens.spaceSm));

      // On screen wherever the long description is scrolled to.
      final position = bodyPosition(tester);
      expect(position.maxScrollExtent, greaterThan(0));
      expect(pinned.hitTestable(), findsOneWidget);
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(pinned.hitTestable(), findsOneWidget);
      expect(tester.getRect(pinned), button);
    });

    testWidgets('with no footer the band takes no room', (tester) async {
      await open(tester, GameQuickLookSeed.fromGame(wingspan));

      expect(tester.getSize(footer).height, 0);
    });

    testWidgets('a game the server refuses draws no footer', (tester) async {
      remote.onFetchGame = (_) async =>
          throw const GamesForbiddenException('403');
      await open(
        tester,
        GameQuickLookSeed.fromSummary(summary),
        footer: pinnedButton(),
      );

      expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
      expect(pinned, findsNothing);
      expect(tester.getSize(footer).height, 0);
      // What the quick look itself offers stays.
      expect(titleLink(), findsOneWidget);
    });

    testWidgets('a read that fails, or is answered from the cache, keeps the '
        'footer', (tester) async {
      remote.onFetchGame = (_) async => throw unreachable();
      await open(
        tester,
        GameQuickLookSeed.fromSummary(summary),
        cache: FakeGamesCache([wingspan]),
        footer: pinnedButton(),
      );

      expect(find.byKey(GameQuickLook.partialKey), findsOneWidget);
      expect(pinned.hitTestable(), findsOneWidget);
    });

    testWidgets('the footer going with a refused game keeps the scroll '
        'position', (tester) async {
      useViewSize(tester, const Size(400, 500));
      await open(
        tester,
        GameQuickLookSeed.fromGame(wingspan),
        footer: pinnedButton(),
      );
      // The seed's long description, with the read still out.
      final scrollable = tester.state<ScrollableState>(body);
      final position = scrollable.position;
      expect(pinned, findsOneWidget);
      expect(position.maxScrollExtent, greaterThan(40));
      position.jumpTo(40);
      await tester.pump();

      read.completeError(const GamesForbiddenException('403'));
      await tester.pumpAndSettle();

      expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
      expect(pinned, findsNothing);
      expect(tester.state<ScrollableState>(body), same(scrollable));
      expect(position.pixels, 40);
    });

    testWidgets('the host wraps the layout in every state, and keeps its '
        'state through them', (tester) async {
      await open(
        tester,
        GameQuickLookSeed.fromSummary(summary),
        cache: FakeGamesCache([wingspan]),
        host: (context, layout) => _CountingHost(child: layout),
        sections: const [_HostCount()],
      );
      final host = tester.state<_CountingHostState>(find.byType(_CountingHost));
      // Under the quick look, around all it draws.
      expect(
        find.descendant(
          of: find.byType(GameQuickLook),
          matching: find.byType(_CountingHost),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(_CountingHost),
          matching: find.text('Wingspan'),
        ),
        findsOneWidget,
      );
      host.increment();
      await tester.pump();
      expect(find.text('count 1'), findsOneWidget);

      // The seed, then a read answered from the cache, with the banner.
      read.completeError(unreachable());
      await tester.pumpAndSettle();
      expect(find.byKey(GameQuickLook.partialKey), findsOneWidget);
      expect(find.text('count 1'), findsOneWidget);

      // A retry that lands.
      await tester.tap(retry());
      await tester.pump();
      await tester.pump(GameQuickLook.retryDwell);
      read.complete((game: wingspan, platformGames: [tabletop]));
      await tester.pumpAndSettle();
      expect(find.byKey(GameQuickLook.partialKey), findsNothing);
      expect(find.text('Tabletop'), findsOneWidget);
      expect(find.text('count 1'), findsOneWidget);
      expect(
        tester.state<_CountingHostState>(find.byType(_CountingHost)),
        same(host),
      );
    });

    testWidgets('a game the server refuses keeps the host, with nothing of '
        'what it shares drawn', (tester) async {
      await open(
        tester,
        GameQuickLookSeed.fromSummary(summary),
        host: (context, layout) => _CountingHost(child: layout),
        sections: const [_HostCount()],
        footer: const _HostCount(),
      );
      final host = tester.state<_CountingHostState>(find.byType(_CountingHost))
        ..increment();
      await tester.pump();
      // Before the answer, the section and the footer both read the host.
      expect(find.text('count 1'), findsNWidgets(2));

      read.completeError(const GamesForbiddenException('403'));
      await tester.pumpAndSettle();

      expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
      expect(find.byType(_HostCount), findsNothing);
      expect(
        tester.state<_CountingHostState>(find.byType(_CountingHost)),
        same(host),
      );
      expect(host.count, 1);
      expect(tester.takeException(), isNull);
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

    // The actions row, at the foot and at the end of the line.
    final import = find.widgetWithText(TextButton, 'Import');
    final bar = find.ancestor(of: import, matching: find.byType(OverflowBar));
    expect(bar, findsOneWidget);
    expect(
      tester.getTopLeft(import).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('extra section')).dy),
    );
    expect(
      tester.getTopRight(import).dx,
      moreOrLessEquals(tester.getTopRight(bar).dx, epsilon: 1),
    );
  });

  group("the title opens the game's page (#798)", () {
    /// A page for [gameId], standing in for the game's detail page.
    Route<void> detailsPage(String gameId) => MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(),
        body: Text('Details of $gameId'),
      ),
    );

    /// Whether the title's ring is drawn.
    bool ringDrawn(WidgetTester tester) {
      final ring = find.ancestor(
        of: titleLink(),
        matching: find.byType(BgeFocusRing),
      );
      // The ring's own outer box comes first in its subtree.
      final drawn = tester.widget<DecoratedBox>(
        find.descendant(of: ring, matching: find.byType(DecoratedBox)).first,
      );
      return (drawn.decoration as BoxDecoration).border != null;
    }

    /// The opener's focus node: the nearest above its words.
    FocusNode openerFocus(WidgetTester tester) =>
        Focus.of(tester.element(find.text('open')));

    /// Opens the quick look from the keyboard, Tab to the opener and Enter,
    /// so that focus has somewhere to come back to.
    Future<void> openByKeyboard(WidgetTester tester) async {
      final node = openerFocus(tester);
      for (var i = 0; i < 10 && !node.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(node.hasPrimaryFocus, isTrue, reason: 'Tab reaches the opener');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(GameQuickLook), findsOneWidget);
    }

    testWidgets("tapping the title opens the game's page", (tester) async {
      await open(tester, GameQuickLookSeed.fromSummary(summary));

      // A one-line title is still a whole target.
      expect(
        tester.getSize(titleLink()).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      await tester.tap(titleLink());
      await tester.pumpAndSettle();

      expect(viewed, ['g_wingspan']);
      // Left open: the page pushed over it takes it away once it has arrived.
      expect(find.byType(GameQuickLook), findsOneWidget);
    });

    testWidgets("Enter on the focused title opens the game's page", (
      tester,
    ) async {
      await open(tester, GameQuickLookSeed.fromSummary(summary));

      await tabToTitle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(viewed, ['g_wingspan']);
    });

    testWidgets('Enter then a tap opens the page once', (tester) async {
      // As in the app. The opener's page is on the shell's nested navigator,
      // and the quick look over it on the root one. The game's page arrives
      // on the nested one, beneath the quick look, which goes once the page
      // has arrived (#414): until then the title is on top, where a second
      // press reaches it. And the app's router builds its navigators again
      // on each push, and each route's page with them, so the title the
      // second press reaches carries a callback from a new run of the
      // pop-up's builder. A guard made in the builder would let it through.
      final nested = GlobalKey<NavigatorState>();
      final observer = BgePopupCoverObserver();
      final pushes = ValueNotifier(0);
      addTearDown(pushes.dispose);
      final opened = <String>[];
      await tester.pumpWidget(
        ValueListenableBuilder<int>(
          valueListenable: pushes,
          builder: (_, _, _) => catalogApp(
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
                        pushes.value++;
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await openByKeyboard(tester);
      await tabToTitle(tester);
      final pressed = tester.widget<InkWell>(titleLink()).onTap;

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // The page is arriving beneath the quick look, which is still there,
      // its title built again.
      expect(find.text('Details of g_wingspan'), findsOneWidget);
      expect(find.byType(GameQuickLook), findsOneWidget);
      expect(
        tester.widget<InkWell>(titleLink()).onTap,
        isNot(same(pressed)),
        reason: "the pop-up's builder ran again",
      );

      // A tap on the title, which it reaches.
      final title = tester.getCenter(titleLink());
      expect(
        tester.hitTestOnBinding(title).path.map((entry) => entry.target),
        contains(tester.renderObject(titleLink())),
      );
      await tester.tapAt(title);
      await tester.pump();

      expect(opened, ['g_wingspan']);

      await tester.pumpAndSettle();
      expect(find.byType(GameQuickLook, skipOffstage: false), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // Back lands where the quick look was opened, not on a second copy.
      expect(
        find.text('Details of g_wingspan', skipOffstage: false),
        findsNothing,
      );
      expect(find.byType(GameQuickLook), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(openerFocus(tester)));
    });

    group('a page popped before it arrives leaves the title working', () {
      /// Presses the title, pops the page halfway through its entrance, and
      /// presses the title again: it opens the page again, and that one
      /// takes the quick look away once it has arrived.
      Future<void> popOnItsWayThenAgain(
        WidgetTester tester,
        List<String> opened,
        NavigatorState Function() pagesNavigator,
      ) async {
        await tester.tap(titleLink());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Details of g_wingspan'), findsOneWidget);

        pagesNavigator().pop();
        await tester.pumpAndSettle();
        expect(find.text('Details of g_wingspan'), findsNothing);
        // Never covered, so still there.
        expect(find.byType(GameQuickLook), findsOneWidget);

        await tester.tap(titleLink());
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

      testWidgets('on a nested navigator, beneath the pop-up', (
        tester,
      ) async {
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

    testWidgets("the title still opens after the caller's widget is gone", (
      tester,
    ) async {
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
                          Navigator.of(context).push(detailsPage(gameId));
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

      await tester.tap(titleLink());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(mountedWhenPressed, isTrue);
      expect(find.text('Details of g_wingspan'), findsOneWidget);
    });

    testWidgets('back from the page lands where the quick look was opened, '
        'with focus on the opener', (tester) async {
      await tester.pumpWidget(
        catalogApp(
          Scaffold(
            body: Center(
              child: opener(
                GameQuickLookSeed.fromSummary(summary),
                onViewDetails: (context, gameId) =>
                    Navigator.of(context).push(detailsPage(gameId)),
              ),
            ),
          ),
        ),
      );
      await openByKeyboard(tester);

      await tabToTitle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Details of g_wingspan'), findsOneWidget);
      // Gone once the page has arrived, not just hidden under it.
      expect(find.byType(GameQuickLook, skipOffstage: false), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.text('Details of g_wingspan', skipOffstage: false),
        findsNothing,
      );
      expect(find.byType(GameQuickLook), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(openerFocus(tester)));
    });

    testWidgets('the quick look has no View full details', (tester) async {
      await open(tester, GameQuickLookSeed.fromGame(wingspan));

      expect(find.text('View full details'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(GameQuickLook),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
        findsNothing,
      );
      // With no actions of the caller's, there is no actions row.
      expect(
        find.descendant(
          of: find.byType(GameQuickLook),
          matching: find.byType(OverflowBar),
        ),
        findsNothing,
      );
    });

    testWidgets('without onViewDetails the title is plain text and no link', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(
        tester,
        GameQuickLookSeed.fromSummary(summary),
        viewDetails: false,
        actions: [TextButton(onPressed: () {}, child: const Text('Import'))],
      );

      // Not disabled: there is nowhere to open it, and won't be.
      expect(titleLink(), findsNothing);
      expect(find.text('Import'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Wingspan')),
        isSemantics(
          label: 'Wingspan',
          isHeader: true,
          isLink: false,
          hasTapAction: false,
        ),
      );
      final style = tester.widget<Text>(find.text('Wingspan')).style;
      expect(style?.decoration, isNot(TextDecoration.underline));

      handle.dispose();
    });

    // iOS and Android read a heading that is also a link from one node.
    // Elsewhere a node has one role, and a heading wins over a link, so the
    // link would go: there the heading holds the link, as HTML's
    // <h2><a></a></h2> does (#798).
    const oneNode = {TargetPlatform.iOS, TargetPlatform.android};
    testWidgets(
      'a screen reader hears the title as a heading and a link',
      (tester) async {
        final handle = tester.ensureSemantics();
        await open(tester, GameQuickLookSeed.fromSummary(summary));

        final heard = tester.getSemantics(titleLink());
        // The words, the link and its tap are one node.
        expect(tester.getSemantics(find.text('Wingspan')), same(heard));
        if (oneNode.contains(defaultTargetPlatform)) {
          // The level is what those engines read as a heading; the header
          // flag alone is not. Both survive the tap action.
          expect(heard.getSemanticsData().headingLevel, 2);
          expect(
            heard,
            isSemantics(
              label: 'Wingspan',
              isHeader: true,
              isLink: true,
              hasTapAction: true,
              isFocusable: true,
              isButton: false,
            ),
          );
        } else {
          expect(
            heard,
            isSemantics(
              label: 'Wingspan',
              isHeader: false,
              isLink: true,
              hasTapAction: true,
              isFocusable: true,
              isButton: false,
            ),
          );
          // A heading of level 2, named by the link alone.
          final heading = heard.parent!;
          expect(heading.getSemanticsData().headingLevel, 2);
          expect(
            heading,
            isSemantics(label: '', isHeader: false, isLink: false),
          );
          expect(heading.childrenCount, 1);
        }

        tester.semantics.tap(
          find.semantics.byPredicate((node) => node.id == heard.id),
        );
        await tester.pump();
        expect(viewed, ['g_wingspan']);

        handle.dispose();
      },
      variant: TargetPlatformVariant.all(),
    );

    for (final direction in TextDirection.values) {
      testWidgets('a one-letter title takes a press 48 dp wide, though its '
          'target reaches into the margin, ${direction.name}', (
        tester,
      ) async {
        await tester.pumpWidget(
          catalogApp(
            builder: (context, child) =>
                Directionality(textDirection: direction, child: child!),
            Scaffold(
              body: Center(
                child: opener(
                  const GameQuickLookSeed(id: 'g_7', title: '7'),
                  onViewDetails: (_, id) => viewed.add(id),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Across the target's row, a dp at a time: what reaches the link.
        final target = tester.getRect(titleLink());
        final link = tester.renderObject(titleLink());
        final pressed = [
          for (var x = target.left.floor() - 10; x <= target.right + 10; x++)
            if (tester
                .hitTestOnBinding(Offset(x + 0.5, target.center.dy))
                .path
                .any((entry) => entry.target == link))
              x,
        ];
        expect(
          pressed.length,
          greaterThanOrEqualTo(kMinInteractiveDimension),
          reason: 'the strip before the words takes no press',
        );

        // A tap at the edge before the words, the one moved into the margin.
        final start = switch (direction) {
          TextDirection.ltr => pressed.first,
          TextDirection.rtl => pressed.last,
        };
        await tester.tapAt(Offset(start + 0.5, target.center.dy));
        expect(viewed, ['g_7']);
      });
    }

    for (final (name, theme, highContrast, minimum) in [
      ('light', BgeTheme.light(), false, Wcag.aaNormalText),
      ('dark', BgeTheme.dark(), false, Wcag.aaNormalText),
      (
        'high-contrast light',
        BgeTheme.highContrastLight(),
        true,
        Wcag.aaaNormalText,
      ),
      (
        'high-contrast dark',
        BgeTheme.highContrastDark(),
        true,
        Wcag.aaaNormalText,
      ),
    ]) {
      for (final (form, view, chrome) in [
        ('sheet', const Size(400, 800), BottomSheet),
        ('dialog', const Size(800, 800), Dialog),
      ]) {
        testWidgets("the title's words read on the $form, $name", (
          tester,
        ) async {
          useViewSize(tester, view);
          // As the system's setting picks the high-contrast theme.
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(highContrast: highContrast);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          await open(
            tester,
            GameQuickLookSeed.fromSummary(summary),
            theme: theme,
          );
          expect(find.byType(chrome), findsOneWidget);

          final words = tester
              .widget<Text>(
                find.descendant(of: titleLink(), matching: find.byType(Text)),
              )
              .style!;
          // The pop-up's own surface, as it paints it.
          final surface = tester.widget<Material>(
            find
                .ancestor(
                  of: titleLink(),
                  matching: find.byWidgetPredicate(
                    (w) => w is Material && w.type != MaterialType.transparency,
                  ),
                )
                .first,
          );
          final ground = ElevationOverlay.applySurfaceTint(
            surface.color!,
            surface.surfaceTintColor,
            surface.elevation,
          );
          final ratio = Wcag.contrastRatio(words.color!, ground);
          expect(
            ratio,
            greaterThanOrEqualTo(minimum),
            reason: '${ratio.toStringAsFixed(2)}:1',
          );
          // The underline, in the words' colour, still says it's a link.
          expect(words.decoration, TextDecoration.underline);
          expect(words.decorationColor, words.color);
        });
      }
    }

    testWidgets("the title's target is at least 48 dp tall and spans every "
        'wrapped line at 320 dp × 2.0', (tester) async {
      const view = Size(320, 640);
      useViewSize(tester, view);
      // Short words: the test font draws each letter an em wide, so a long
      // word would run past the line it is on, as no word does in the
      // title's own face. These wrap one or two to a line.
      const title = 'Ark Nova: Marine Worlds of the Deep';
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
                  const GameQuickLookSeed(id: 'g_ti', title: title),
                  onViewDetails: (_, id) => viewed.add(id),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final target = tester.getRect(titleLink());
      expect(target.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      final words = tester.renderObject<RenderParagraph>(
        find.descendant(of: titleLink(), matching: find.byType(RichText)),
      );
      final toScreen = words.getTransformTo(null);
      // Each word's box, leaving out the spaces, whose boxes run on past the
      // end of a line the text wraps at.
      final drawn = [
        for (final word in RegExp(r'\S+').allMatches(title))
          for (final box in words.getBoxesForSelection(
            TextSelection(baseOffset: word.start, extentOffset: word.end),
          ))
            MatrixUtils.transformRect(toScreen, box.toRect()),
      ];
      expect(
        {for (final box in drawn) box.top},
        hasLength(greaterThan(2)),
        reason: 'the title wraps',
      );
      for (final box in drawn) {
        expect(box.left, greaterThanOrEqualTo(target.left), reason: '$box');
        expect(box.right, lessThanOrEqualTo(target.right), reason: '$box');
        expect(box.top, greaterThanOrEqualTo(target.top), reason: '$box');
        expect(box.bottom, lessThanOrEqualTo(target.bottom), reason: '$box');
      }

      // A tap on the last line opens the page, as one on the first does.
      await tester.tapAt(drawn.last.center);
      await tester.pump();
      expect(viewed, ['g_ti']);
    });

    for (final direction in TextDirection.values) {
      testWidgets("the title's words start where the subtitle's do, with room "
          'for the ring around them (${direction.name})', (tester) async {
        await tester.pumpWidget(
          catalogApp(
            builder: (_, child) =>
                Directionality(textDirection: direction, child: child!),
            Scaffold(
              body: Center(
                child: opener(
                  GameQuickLookSeed.fromSummary(
                    const GameSummary(
                      id: 'g_wingspan',
                      title: 'Wingspan',
                      subtitle: 'European Expansion',
                    ),
                  ),
                  onViewDetails: (_, id) => viewed.add(id),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final words = tester.getRect(find.text('Wingspan'));
        final subtitle = tester.getRect(find.text('European Expansion'));
        // In line with the subtitle, as a plain title is.
        if (direction == TextDirection.ltr) {
          expect(words.left, moreOrLessEquals(subtitle.left));
        } else {
          expect(words.right, moreOrLessEquals(subtitle.right));
        }
        // The ring is drawn on the target's edge, clear of the words.
        const tokens = BgeTokens.standard;
        final target = tester.getRect(titleLink());
        expect(words.left - target.left, greaterThanOrEqualTo(tokens.spaceSm));
        expect(
          target.right - words.right,
          greaterThanOrEqualTo(tokens.spaceSm),
        );
        expect(words.top - target.top, greaterThanOrEqualTo(tokens.spaceXs));
        expect(
          target.bottom - words.bottom,
          greaterThanOrEqualTo(tokens.spaceXs),
        );
      });
    }

    testWidgets(
      'a mouse click on the title draws no ring; Tab to it draws one',
      (tester) async {
        await open(tester, GameQuickLookSeed.fromSummary(summary));
        expect(ringDrawn(tester), isFalse, reason: 'at rest');

        await tabToTitle(tester);
        expect(ringDrawn(tester), isTrue, reason: 'Tab');

        final title = tester.getCenter(titleLink());
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: title + const Offset(0, -200));
        addTearDown(mouse.removePointer);
        await mouse.moveTo(title);
        await mouse.down(title);
        await tester.pump(const Duration(milliseconds: 50));
        await mouse.up();
        await tester.pump();

        expect(viewed, ['g_wingspan']);
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        expect(ringDrawn(tester), isFalse, reason: 'clicked');
        // Nor the ink's focus tint.
        expect(tester.widget<InkWell>(titleLink()).focusColor?.a, 0);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
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

  testWidgets('on a 320dp phone at 1.0 text a title that is a link goes '
      'under the cover, where its padded words would break a word (#798)', (
    tester,
  ) async {
    const view = Size(320, 640);
    useViewSize(tester, view);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: view),
        child: catalogApp(
          Scaffold(
            body: Center(
              child: opener(
                GameQuickLookSeed.fromGame(wingspan),
                onViewDetails: (_, id) => viewed.add(id),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The test font draws every glyph 1 em wide, so "Wingspan" at the
    // title's 22sp is 8 ems, 176dp: as wide as the room beside the cover
    // at 320dp, the 8 ems a plain title needs, but wider than the 160dp the
    // link leaves its words once it pads them.
    final title = tester.getRect(find.text('Wingspan'));
    final shown = tester.getRect(cover());
    expect(title.top, greaterThanOrEqualTo(shown.bottom));
    // Unbroken: one line as wide as the word.
    expect(title.width, 8 * BgeTypography.titleLarge);
    expect(tester.takeException(), isNull);
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

/// A host with state of its own, which [_HostCount] shows: stands in for an
/// import's, which the section and the footer share.
class _CountingHost extends StatefulWidget {
  const _CountingHost({required this.child});

  final Widget child;

  @override
  State<_CountingHost> createState() => _CountingHostState();
}

class _CountingHostState extends State<_CountingHost> {
  int count = 0;

  void increment() => setState(() => count++);

  @override
  Widget build(BuildContext context) =>
      _HostScope(count: count, child: widget.child);
}

class _HostScope extends InheritedWidget {
  const _HostScope({required this.count, required super.child});

  final int count;

  @override
  bool updateShouldNotify(_HostScope oldWidget) => count != oldWidget.count;
}

/// The count the [_CountingHost] above it holds.
class _HostCount extends StatelessWidget {
  const _HostCount();

  @override
  Widget build(BuildContext context) => Text(
    'count ${context.dependOnInheritedWidgetOfExactType<_HostScope>()!.count}',
  );
}
