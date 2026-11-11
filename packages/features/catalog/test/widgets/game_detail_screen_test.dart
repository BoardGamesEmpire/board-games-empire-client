import 'dart:async';

import 'package:bge_test_support/images.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_catalog/src/widgets/game_detail_platforms.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

void main() {
  // The header tests measure the title in its own face; see #735.
  setUpAll(loadDisplayFont);

  late FakeGamesRemote remote;
  late List<Uri> opened;

  setUp(() {
    remote = FakeGamesRemote();
    opened = [];
  });

  final catan = Game(
    id: 'g_catan',
    title: 'Catan',
    subtitle: 'Trade, build, settle',
    description:
        'Settle **the island**. See [the rules](https://example.com/rules).',
    publishYear: 1995,
    minPlayers: 3,
    maxPlayers: 4,
    // One playing time is a range whose two ends are equal.
    minPlayTime: 90,
    maxPlayTime: 90,
    minAge: 10,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  final tabletop = PlatformGame(
    id: 'pg_1',
    gameId: 'g_catan',
    platformId: 'plat_tabletop',
    platformName: 'Tabletop',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  Future<void> show(
    WidgetTester tester, {
    String gameId = 'g_catan',
    FakeGamesCache? cache,
    GameDetailCollection? collection,
    ThemeData? theme,
    TransitionBuilder? builder,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        GameDetailScreen(
          gameId: gameId,
          remote: remote,
          cache: cache,
          collection: collection,
          openLink: (uri) async => opened.add(uri),
        ),
        theme: theme,
        builder: builder,
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  /// Taps the link whose text is [text] in the rendered description.
  void tapLink(WidgetTester tester, String text) {
    for (final element in find.byType(RichText).evaluate()) {
      (element.widget as RichText).text.visitChildren((span) {
        if (span is TextSpan && span.text == text) {
          (span.recognizer! as TapGestureRecognizer).onTap!();
          return false;
        }
        return true;
      });
    }
  }

  testWidgets("shows the game's facts", (tester) async {
    remote.onFetchGame = (_) async =>
        (game: catan, platformGames: const <PlatformGame>[]);

    await show(tester);

    expect(find.text('Trade, build, settle'), findsOneWidget);
    expect(find.byKey(GameDetailScreen.factsKey), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(GameDetailScreen.factsKey),
              matching: find.byType(Text),
            ),
          )
          .data,
      'Base game · Published 1995 · 3–4 players · 1 hr 30 min · Ages 10+',
    );
  });

  testWidgets("reads an imported game's play time from its range", (
    tester,
  ) async {
    // What the server's import writes: a minimum and a maximum, in minutes.
    final imported = Game(
      id: 'g_brass',
      title: 'Brass',
      minPlayTime: 60,
      maxPlayTime: 120,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    remote.onFetchGame = (_) async =>
        (game: imported, platformGames: const <PlatformGame>[]);

    await show(tester, gameId: 'g_brass');

    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(GameDetailScreen.factsKey),
              matching: find.byType(Text),
            ),
          )
          .data,
      'Base game · 1–2 hr',
    );
  });

  for (final (bound, game, facts) in [
    (
      'a lone minimum',
      (minPlayTime: 30, maxPlayTime: null),
      'Base game · 30 min+',
    ),
    (
      'a lone maximum',
      (minPlayTime: null, maxPlayTime: 120),
      'Base game · Up to 2 hr',
    ),
  ]) {
    testWidgets('reads $bound as a bound, not as the playing time', (
      tester,
    ) async {
      final bounded = Game(
        id: 'g_bounded',
        title: 'Bounded',
        minPlayTime: game.minPlayTime,
        maxPlayTime: game.maxPlayTime,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      remote.onFetchGame = (_) async =>
          (game: bounded, platformGames: const <PlatformGame>[]);

      await show(tester, gameId: 'g_bounded');

      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(GameDetailScreen.factsKey),
                matching: find.byType(Text),
              ),
            )
            .data,
        facts,
      );
    });
  }

  testWidgets('renders the description as Markdown, not as its source', (
    tester,
  ) async {
    remote.onFetchGame = (_) async =>
        (game: catan, platformGames: const <PlatformGame>[]);

    await show(tester);

    expect(find.textContaining('**'), findsNothing);
    expect(
      find.textContaining('the island', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('opens a web link outside the app', (tester) async {
    remote.onFetchGame = (_) async =>
        (game: catan, platformGames: const <PlatformGame>[]);

    await show(tester);
    tapLink(tester, 'the rules');

    expect(opened, [Uri.parse('https://example.com/rules')]);
  });

  testWidgets('rebuilt in place for another game, reads that game', (
    tester,
  ) async {
    remote.onFetchGame = (id) async => (
      game: game(id, title: 'Title of $id'),
      platformGames: const <PlatformGame>[],
    );

    await show(tester, gameId: 'g_a');
    // The same widget position with a new id, as go_router does for a `go`
    // from one game's location to another's.
    await show(tester, gameId: 'g_b');

    expect(find.text('Title of g_b'), findsWidgets);
    expect(find.text('Title of g_a'), findsNothing);
  });

  testWidgets('when the server fails, shows the saved copy under a banner', (
    tester,
  ) async {
    remote.onFetchGame = (_) async => throw unreachable();

    await show(tester, cache: FakeGamesCache([catan]));

    expect(find.byKey(GameDetailScreen.fromCacheBannerKey), findsOneWidget);
    expect(find.text('Trade, build, settle'), findsOneWidget);
  });

  testWidgets('a game that is not there is unavailable', (tester) async {
    remote.onFetchGame = (_) async => throw const GameNotFoundException('404');

    await show(tester);

    expect(find.byKey(GameDetailScreen.unavailableKey), findsOneWidget);
  });

  group('a game found gone', () {
    /// Opens the detail over a page beneath it, as the list opens it, and
    /// collects the games it says are gone.
    Future<List<String>> open(WidgetTester tester) async {
      final gone = <String>[];
      await tester.pumpWidget(
        catalogApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => GameDetailScreen(
                    gameId: 'g_catan',
                    remote: remote,
                    onGone: gone.add,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return gone;
    }

    testWidgets('is said to be gone as soon as the server says so', (
      tester,
    ) async {
      remote.onFetchGame = (_) async =>
          throw const GameNotFoundException('404');

      final gone = await open(tester);

      expect(find.byKey(GameDetailScreen.unavailableKey), findsOneWidget);
      expect(gone, ['g_catan']);
    });

    testWidgets('is left as any page is, the back swipe included', (
      tester,
    ) async {
      remote.onFetchGame = (_) async =>
          throw const GamesForbiddenException('403');

      await open(tester);
      final route = ModalRoute.of(
        tester.element(find.byKey(GameDetailScreen.unavailableKey)),
      )!;
      expect(route.popGestureEnabled, isTrue);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(GameDetailScreen), findsNothing);
    });

    testWidgets('is not said of a game that is there', (tester) async {
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: const <PlatformGame>[]);

      expect(await open(tester), isEmpty);
    });
  });

  testWidgets('with nothing saved, a failure is an error with a retry', (
    tester,
  ) async {
    remote.onFetchGame = (_) async => throw unreachable();

    await show(tester, cache: FakeGamesCache());
    expect(find.byKey(GameDetailScreen.errorKey), findsOneWidget);

    remote.onFetchGame = (_) async =>
        (game: catan, platformGames: const <PlatformGame>[]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Trade, build, settle'), findsOneWidget);
  });

  group('under the selection region (#338)', () {
    final prose = catan.copyWith(
      description: 'Settle the island. [Rules](https://example.com/rules)',
    );

    Future<void> showUnderRegion(WidgetTester tester) async {
      remote.onFetchGame = (_) async =>
          (game: prose, platformGames: const <PlatformGame>[]);
      useViewSize(tester, const Size(1280, 800));
      await show(
        tester,
        theme: pointerPlatformTheme(),
        builder: underSelectionRegion,
      );
    }

    /// The description paragraph's rich text.
    Finder paragraph() =>
        find.textContaining('Settle the island.', findRichText: true);

    testWidgets('the region is installed', (tester) async {
      await showUnderRegion(tester);

      expect(find.byType(SelectableRegion), findsOneWidget);
    });

    testWidgets('a drag over the description selects it, and copy lifts the '
        'text', (tester) async {
      final copies = captureClipboardCopies();
      await showUnderRegion(tester);

      final rect = tester.getRect(paragraph());
      final plain = tester
          .renderObject<RenderParagraph>(paragraph())
          .text
          .toPlainText();
      await mouseDrag(
        tester,
        rect.centerLeft + const Offset(1, 0),
        rect.centerRight - const Offset(1, 0),
      );
      await sendCopyShortcut(tester);

      expect(copies, hasLength(1));
      expect(copies.single, isNotEmpty);
      expect(plain, contains(copies.single));
      expect(
        copies.single,
        contains('the island'),
        reason: 'the drag reached across the prose',
      );
    });

    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      testWidgets('a real ${kind.name} tap on a description link still opens '
          'it', (tester) async {
        await showUnderRegion(tester);

        final range = find.textRange.ofSubstring('Rules').evaluate().single;
        final box = range.renderObject
            .getBoxesForSelection(
              TextSelection(
                baseOffset: range.textRange.start,
                extentOffset: range.textRange.end,
              ),
            )
            .first;
        await tester.tapAt(
          range.renderObject.localToGlobal(box.toRect().center),
          kind: kind,
        );
        await tester.pump();

        expect(opened, [Uri.parse('https://example.com/rules')]);
      });
    }
  });

  group('GameDescription', () {
    Future<void> describe(WidgetTester tester, String markdown) =>
        tester.pumpWidget(
          catalogApp(
            Scaffold(
              body: GameDescription(markdown: markdown, onOpenLink: opened.add),
            ),
          ),
        );

    String rendered(WidgetTester tester) => find
        .byType(RichText)
        .evaluate()
        .map((e) => (e.widget as RichText).text.toPlainText())
        .join('\n');

    testWidgets('never renders raw HTML', (tester) async {
      await describe(
        tester,
        'Before <b>bold</b> <script>alert(1)</script> after.\n\n'
        '<div onclick="x">a block</div>\n\n'
        'Tail.',
      );

      // Inline tags are text; a block of HTML is not drawn at all.
      expect(
        rendered(tester),
        'Before <b>bold</b> <script>alert(1)</script> after.\nTail.',
      );
    });

    testWidgets('passes on http, https and mailto links, and no others', (
      tester,
    ) async {
      await describe(
        tester,
        '[a](http://example.com) [b](https://example.com) '
        '[c](mailto:a@example.com) [d](javascript:alert(1)) '
        '[e](file:///etc/passwd)',
      );

      for (final text in ['a', 'b', 'c', 'd', 'e']) {
        tapLink(tester, text);
      }

      expect(opened, [
        Uri.parse('http://example.com'),
        Uri.parse('https://example.com'),
        Uri.parse('mailto:a@example.com'),
      ]);
    });

    testWidgets('shows an image it may not fetch as its description', (
      tester,
    ) async {
      await describe(tester, '![The box](ftp://example.com/box.png)');

      expect(find.text('Image: The box'), findsOneWidget);
    });

    group('an image', () {
      /// Waits for the image to decode, and returns the size it decoded at.
      Future<Size> decoded(WidgetTester tester) async {
        final raw = find.byType(RawImage);
        for (var i = 0; i < 40; i++) {
          final image = raw.evaluate().isEmpty
              ? null
              : tester.widget<RawImage>(raw).image;
          if (image != null) {
            return Size(image.width.toDouble(), image.height.toDouble());
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        fail('no image decoded');
      }

      /// Serves a [width] x [height] PNG to a description of it, and
      /// returns the size it decoded at.
      Future<Size> decodedSize(
        WidgetTester tester, {
        required int width,
        required int height,
      }) async {
        final png = (await tester.runAsync(() => solidPng(width, height)))!;
        return servingImages(png, () async {
          await describe(tester, '![](https://example.com/box.png)');
          return decoded(tester);
        });
      }

      testWidgets("is held to the display's width, keeping its shape", (
        tester,
      ) async {
        final display = tester.view.display.size.width;

        expect(
          await decodedSize(tester, width: (display * 2).toInt(), height: 100),
          Size(display, 50),
        );
      });

      testWidgets('smaller than that, is decoded as sent', (tester) async {
        expect(
          await decodedSize(tester, width: 40, height: 20),
          const Size(40, 20),
        );
      });

      testWidgets('is fetched once, however the window is resized', (
        tester,
      ) async {
        addTearDown(tester.view.reset);
        final png = (await tester.runAsync(() => solidPng(3000, 1500)))!;
        await servingImages(png, () async {
          final host = debugNetworkImageHttpClientProvider!;
          var fetches = 0;
          debugNetworkImageHttpClientProvider = () {
            fetches++;
            return host();
          };
          await describe(tester, '![](https://example.com/box.png)');
          await decoded(tester);

          for (final width in [810.0, 820.0, 830.0]) {
            tester.view.physicalSize = Size(width, 600);
            await tester.pump();
            await decoded(tester);
          }

          expect(fetches, 1);
        });
      });
    });
  });

  group('the platforms and the collection (#708)', () {
    final steam = PlatformGame(
      id: 'pg_2',
      gameId: 'g_catan',
      platformId: 'plat_steam',
      platformName: 'Steam',
      thumbnail: 'https://example.com/steam.png',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    final nintendoSwitch = PlatformGame(
      id: 'pg_3',
      gameId: 'g_catan',
      platformId: 'plat_switch',
      platformName: 'Nintendo Switch 2',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

    GameCollection entry(String platformGameId, GameMedium medium) =>
        GameCollection(
          id: 'e_${platformGameId}_${medium.name}',
          userId: 'u_1',
          platformGameId: platformGameId,
          medium: medium,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );

    const ownedSpoken = 'Tabletop, in your collection, opens your copy';
    const notOwnedSpoken = 'Steam, not in your collection, add';

    late List<({List<CollectionAddOption> options, String? platformGameId})>
    adds;
    late List<List<GameCollectionListItem>> openedOwned;
    late List<Set<String>> watched;

    setUp(() {
      adds = [];
      openedOwned = [];
      watched = [];
    });

    /// A collection whose ownership is [owned]'s stream, recording what the
    /// page asks of it.
    GameDetailCollection collectionOf(
      Stream<List<GameCollection>> Function() owned,
    ) => GameDetailCollection(
      watchOwned: (ids) {
        watched.add(ids);
        return owned();
      },
      onAdd: (context, game, options, {platformGameId}) {
        expect(game.id, 'g_catan');
        adds.add((options: options, platformGameId: platformGameId));
      },
      onOpenOwned: (context, items) => openedOwned.add(items),
    );

    /// The page for Catan on [platforms], owning [entries].
    Future<void> showOwning(
      WidgetTester tester,
      List<GameCollection> entries, {
      List<PlatformGame>? platforms,
      Game? game,
    }) async {
      remote.onFetchGame = (_) async =>
          (game: game ?? catan, platformGames: platforms ?? [tabletop, steam]);
      await show(tester, collection: collectionOf(() => Stream.value(entries)));
    }

    Finder chip(String platformGameId) =>
        find.byKey(GameDetailScreen.platformKey(platformGameId));
    Finder checkOn(String platformGameId) => find.descendant(
      of: chip(platformGameId),
      matching: find.byIcon(Icons.check),
    );
    Finder actionChipOf(String platformGameId) => find.descendant(
      of: chip(platformGameId),
      matching: find.byType(ActionChip),
    );
    final addButton = find.byKey(GameDetailScreen.addKey);
    final ownedLegend = find.byKey(GameDetailScreen.ownedLegendKey);

    Future<void> tapChip(WidgetTester tester, String platformGameId) async {
      await tester.ensureVisible(chip(platformGameId));
      await tester.pumpAndSettle();
      await tester.tap(chip(platformGameId));
      await tester.pump();
    }

    /// Expects the chips plain, as labels: no action, no check, and nothing
    /// said of ownership.
    void expectPlain(WidgetTester tester) {
      expect(find.byType(ActionChip), findsNothing);
      expect(find.byType(Chip), findsNWidgets(2));
      expect(find.byIcon(Icons.check), findsNothing);
      expect(ownedLegend, findsNothing);
      expect(addButton, findsNothing);
      expect(find.bySemanticsLabel(RegExp('collection')), findsNothing);
      expect(find.bySemanticsLabel('Tabletop'), findsOneWidget);
    }

    testWidgets('owned chips carry the check and say so; unowned ones say '
        'add', (tester) async {
      await showOwning(tester, [entry('pg_1', GameMedium.physical)]);

      expect(checkOn('pg_1'), findsOneWidget);
      expect(checkOn('pg_2'), findsNothing);

      // One node each, a button that a reader can press, named in full: the
      // shown platform name is not read again on its own.
      for (final spoken in [ownedSpoken, notOwnedSpoken]) {
        expect(
          tester.getSemantics(find.bySemanticsLabel(spoken)),
          isSemantics(
            label: spoken,
            isButton: true,
            hasTapAction: true,
            isFocusable: true,
          ),
        );
      }
      expect(find.bySemanticsLabel('Tabletop'), findsNothing);
      expect(find.bySemanticsLabel('Steam'), findsNothing);

      // Filled against outlined, from the roles the contrast test checks.
      final scheme = Theme.of(tester.element(chip('pg_1'))).colorScheme;
      final owned = tester.widget<ActionChip>(actionChipOf('pg_1'));
      expect(owned.backgroundColor, scheme.primary);
      expect(owned.side, BorderSide.none);
      expect(owned.labelStyle?.color, scheme.onPrimary);
      expect(tester.widget<Icon>(checkOn('pg_1')).color, scheme.onPrimary);
      final notOwned = tester.widget<ActionChip>(actionChipOf('pg_2'));
      expect(notOwned.backgroundColor?.a ?? 0, 0);
      expect(notOwned.side?.color, scheme.primary);
      expect(notOwned.labelStyle?.color, scheme.primary);
    });

    testWidgets('tapping an owned chip opens its entries', (tester) async {
      // Tabletop has no picture of its own, so its copies show the game's;
      // Steam's show Steam's.
      await showOwning(tester, [
        entry('pg_1', GameMedium.physical),
        entry('pg_1', GameMedium.digital),
        entry('pg_2', GameMedium.digital),
      ], game: catan.copyWith(thumbnail: 'https://example.com/catan.png'));

      await tapChip(tester, 'pg_1');
      await tapChip(tester, 'pg_2');

      expect(openedOwned, [
        [
          for (final medium in [GameMedium.physical, GameMedium.digital])
            GameCollectionListItem(
              entry: entry('pg_1', medium),
              gameId: 'g_catan',
              title: 'Catan',
              subtitle: 'Trade, build, settle',
              platformName: 'Tabletop',
              thumbnail: 'https://example.com/catan.png',
            ),
        ],
        [
          GameCollectionListItem(
            entry: entry('pg_2', GameMedium.digital),
            gameId: 'g_catan',
            title: 'Catan',
            subtitle: 'Trade, build, settle',
            platformName: 'Steam',
            thumbnail: 'https://example.com/steam.png',
          ),
        ],
      ]);
      expect(adds, isEmpty);
    });

    testWidgets("an owned copy's picture falls back through each one's full "
        'image (#709)', (tester) async {
      // Steam has only a full image of its own, which beats the game's
      // thumbnail; Tabletop has none, and the game has only a full image.
      await showOwning(
        tester,
        [entry('pg_1', GameMedium.physical), entry('pg_2', GameMedium.digital)],
        platforms: [
          tabletop,
          steam.copyWith(thumbnail: null, image: 'https://example.com/s.png'),
        ],
        game: catan.copyWith(image: 'https://example.com/catan_full.png'),
      );

      await tapChip(tester, 'pg_1');
      await tapChip(tester, 'pg_2');

      expect(openedOwned.map((items) => items.single.thumbnail), [
        'https://example.com/catan_full.png',
        'https://example.com/s.png',
      ]);
    });

    testWidgets('tapping an unowned chip opens the add with that platform '
        'chosen', (tester) async {
      await showOwning(tester, [entry('pg_1', GameMedium.physical)]);

      await tapChip(tester, 'pg_2');

      expect(adds, hasLength(1));
      expect(adds.single.platformGameId, 'pg_2');
      expect(adds.single.options, [
        CollectionAddOption(
          platformGame: tabletop,
          freeMediums: {GameMedium.digital},
        ),
        CollectionAddOption(
          platformGame: steam,
          freeMediums: {GameMedium.physical, GameMedium.digital},
        ),
      ]);
      expect(openedOwned, isEmpty);
    });

    testWidgets('the Add button offers only platforms with a free medium', (
      tester,
    ) async {
      await showOwning(tester, [
        entry('pg_1', GameMedium.physical),
        entry('pg_1', GameMedium.digital),
        entry('pg_2', GameMedium.digital),
      ]);

      expect(
        find.descendant(
          of: addButton,
          matching: find.text('Add to collection'),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      await tester.tap(addButton);
      await tester.pump();

      expect(adds, hasLength(1));
      expect(adds.single.platformGameId, isNull);
      expect(adds.single.options, [
        CollectionAddOption(
          platformGame: steam,
          freeMediums: {GameMedium.physical},
        ),
      ]);
    });

    testWidgets('the Add button is absent when everything is owned in both '
        'mediums', (tester) async {
      await showOwning(tester, [
        for (final id in ['pg_1', 'pg_2'])
          for (final medium in GameMedium.values) entry(id, medium),
      ]);

      expect(checkOn('pg_1'), findsOneWidget);
      expect(checkOn('pg_2'), findsOneWidget);
      expect(addButton, findsNothing);
    });

    testWidgets('the legend shows only when something is owned', (
      tester,
    ) async {
      final owned = StreamController<List<GameCollection>>();
      addTearDown(owned.close);
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop, steam]);
      await show(tester, collection: collectionOf(() => owned.stream));

      owned.add(const []);
      await tester.pumpAndSettle();
      expect(ownedLegend, findsNothing);
      expect(addButton, findsOneWidget);

      owned.add([entry('pg_2', GameMedium.digital)]);
      await tester.pumpAndSettle();
      expect(ownedLegend, findsOneWidget);
      expect(
        find.descendant(
          of: ownedLegend,
          matching: find.text('In your collection'),
        ),
        findsOneWidget,
      );

      // The legend shows the chips' own mark, as large, in the surface's ink,
      // and says only its words: the mark is decoration.
      final legendCheck = tester.widget<Icon>(
        find.descendant(of: ownedLegend, matching: find.byIcon(Icons.check)),
      );
      final chipCheck = tester.widget<Icon>(checkOn('pg_2'));
      final scheme = Theme.of(tester.element(ownedLegend)).colorScheme;
      expect(legendCheck.size, isNotNull);
      expect(legendCheck.size, chipCheck.size);
      expect(legendCheck.color, scheme.onSurface);
      expect(legendCheck.semanticLabel, isNull);
      expect(
        tester.getSemantics(find.bySemanticsLabel('In your collection')),
        isSemantics(label: 'In your collection'),
      );
    });

    testWidgets('a chip focused from the keyboard is ringed, owned or not', (
      tester,
    ) async {
      await showOwning(tester, [entry('pg_1', GameMedium.physical)]);

      /// The ring [BgeFocusRing] draws around [platformGameId]'s chip, or
      /// null while it draws none.
      Border? ringOn(String platformGameId) {
        final ring = find.descendant(
          of: find.descendant(
            of: chip(platformGameId),
            matching: find.byType(BgeFocusRing),
          ),
          matching: find.byType(DecoratedBox),
        );
        return (tester.widget<DecoratedBox>(ring.first).decoration
                    as BoxDecoration)
                .border
            as Border?;
      }

      /// Tabs until [platformGameId]'s chip has the focus.
      Future<void> tabTo(String platformGameId) async {
        for (var i = 0; i < 10; i++) {
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused != null &&
              find
                  .descendant(
                    of: chip(platformGameId),
                    matching: find.byWidget(focused.widget),
                  )
                  .evaluate()
                  .isNotEmpty) {
            return;
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
        }
        fail('Tab never reached $platformGameId');
      }

      expect(ringOn('pg_1'), isNull);
      expect(ringOn('pg_2'), isNull);

      await tabTo('pg_1');
      final scheme = Theme.of(tester.element(chip('pg_1'))).colorScheme;
      expect(ringOn('pg_1')?.top.color, scheme.primary);
      expect(ringOn('pg_2'), isNull);
      // Drawn a margin out from the chip's own edge, where it stands on the
      // surface rather than on a filled chip's own colour.
      final margin = BgeTokens.of(tester.element(chip('pg_1'))).spaceXs;
      final ringRect = tester.getRect(
        find
            .descendant(
              of: find.descendant(
                of: chip('pg_1'),
                matching: find.byType(BgeFocusRing),
              ),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(ringRect, tester.getRect(actionChipOf('pg_1')).inflate(margin));
      // The margin moves no chip: the first lines up with the heading.
      expect(
        tester.getRect(actionChipOf('pg_1')).left,
        tester.getRect(find.text('Available on')).left,
      );

      await tabTo('pg_2');
      expect(ringOn('pg_1'), isNull);
      expect(ringOn('pg_2')?.top.color, scheme.primary);

      // A touch hides it, though the chip keeps the focus.
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      expect(ringOn('pg_2'), isNull);
    });

    testWidgets("the ring follows the chip's own corners, a margin out", (
      tester,
    ) async {
      await showOwning(tester, [entry('pg_1', GameMedium.physical)]);
      final margin = BgeTokens.of(tester.element(chip('pg_1'))).spaceXs;

      // The corners the chip is drawn with, whatever the theme or Material
      // makes them, owned and not.
      for (final id in ['pg_1', 'pg_2']) {
        final shape = tester
            .widget<Material>(
              find
                  .descendant(
                    of: actionChipOf(id),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .shape;
        expect(shape, isA<RoundedRectangleBorder>(), reason: id);
        final corner = (shape! as RoundedRectangleBorder).borderRadius
            .resolve(TextDirection.ltr)
            .topLeft;
        final ring = tester
            .widget<BgeFocusRing>(
              find.descendant(
                of: chip(id),
                matching: find.byType(BgeFocusRing),
              ),
            )
            .borderRadius
            .topLeft;
        expect(ring.x, corner.x + margin, reason: id);
        expect(ring.y, corner.y + margin, reason: id);
      }
    });

    testWidgets('a one-letter platform keeps a 48 dp square tap target', (
      tester,
    ) async {
      final letter = PlatformGame(
        id: 'pg_4',
        gameId: 'g_catan',
        platformId: 'plat_i',
        platformName: 'I',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      // The test font draws every letter an em wide, so it takes small text
      // to make a one-letter chip narrower than the target, as an "I" is in
      // a real face at the normal size.
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(0.25)),
          child: catalogApp(
            Scaffold(
              body: GameDetailPlatforms(
                game: catan,
                // Second in its row, clear of the row's start, where the
                // slot's margin is drawn into the page's padding.
                platformGames: [tabletop, letter],
                collection: collectionOf(() => Stream.value(const [])),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final target = tester.getRect(chip('pg_4'));
      final drawn = tester.getRect(actionChipOf('pg_4'));
      expect(target.width, greaterThanOrEqualTo(48));
      expect(target.height, greaterThanOrEqualTo(48));
      expect(drawn.width, lessThan(target.width - 2 * 4));

      // Beside the chip, inside its target.
      await tester.tapAt(Offset(target.left + 1, target.center.dy));
      await tester.pump();

      expect(adds.single.platformGameId, 'pg_4');
    });

    testWidgets('a one-letter platform starting its row keeps 48 dp of its '
        'tap target where a press reaches it', (tester) async {
      final letter = PlatformGame(
        id: 'pg_4',
        gameId: 'g_catan',
        platformId: 'plat_i',
        platformName: 'I',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(0.25)),
          child: catalogApp(
            Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: GameDetailPlatforms(
                  game: catan,
                  platformGames: [letter, tabletop],
                  collection: collectionOf(() => Stream.value(const [])),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The slot's start margin lies in the padding, outside the section,
      // where no press reaches it.
      final section = tester.getRect(find.byType(GameDetailPlatforms));
      final target = tester.getRect(chip('pg_4'));
      expect(target.left, lessThan(section.left));
      expect(target.right - section.left, greaterThanOrEqualTo(48));

      await tester.tapAt(Offset(target.left + 1, target.center.dy));
      await tester.pump();
      expect(adds, isEmpty);

      await tester.tapAt(Offset(section.left + 1, target.center.dy));
      await tester.pump();
      expect(adds.single.platformGameId, 'pg_4');
    });

    testWidgets('a press beside a chip, inside its tap target, presses it', (
      tester,
    ) async {
      await showOwning(tester, [entry('pg_1', GameMedium.physical)]);
      await tester.ensureVisible(chip('pg_2'));
      await tester.pumpAndSettle();

      final drawn = tester.getRect(actionChipOf('pg_2'));
      final target = tester.getRect(chip('pg_2'));
      expect(target.height, greaterThanOrEqualTo(48));
      expect(target.top, lessThan(drawn.top));
      await tester.tapAt(Offset(drawn.center.dx, target.top + 1));
      await tester.pump();

      expect(adds.single.platformGameId, 'pg_2');
    });

    testWidgets('chips follow the ownership stream', (tester) async {
      final owned = StreamController<List<GameCollection>>();
      addTearDown(owned.close);
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop, steam]);
      await show(tester, collection: collectionOf(() => owned.stream));

      owned.add(const []);
      await tester.pumpAndSettle();
      expect(checkOn('pg_1'), findsNothing);
      expect(ownedLegend, findsNothing);
      expect(addButton, findsOneWidget);
      expect(find.bySemanticsLabel(notOwnedSpoken), findsOneWidget);

      owned.add([entry('pg_1', GameMedium.physical)]);
      await tester.pumpAndSettle();
      expect(checkOn('pg_1'), findsOneWidget);
      expect(find.bySemanticsLabel(ownedSpoken), findsOneWidget);
      expect(ownedLegend, findsOneWidget);
      expect(addButton, findsOneWidget);

      owned.add([
        for (final id in ['pg_1', 'pg_2'])
          for (final medium in GameMedium.values) entry(id, medium),
      ]);
      await tester.pumpAndSettle();
      expect(checkOn('pg_2'), findsOneWidget);
      expect(addButton, findsNothing);

      // The entry page removes the copies: the chips say add again, the legend
      // goes and the button comes back.
      owned.add(const []);
      await tester.pumpAndSettle();
      expect(checkOn('pg_1'), findsNothing);
      expect(checkOn('pg_2'), findsNothing);
      expect(
        find.bySemanticsLabel('Tabletop, not in your collection, add'),
        findsOneWidget,
      );
      expect(ownedLegend, findsNothing);
      expect(addButton, findsOneWidget);

      // One watch over the page's platforms, whatever it answers.
      expect(watched, [
        {'pg_1', 'pg_2'},
      ]);
    });

    testWidgets('the watch follows the platforms, not each rebuild', (
      tester,
    ) async {
      final streams = <StreamController<List<GameCollection>>>[];
      Stream<List<GameCollection>> next() {
        final owned = StreamController<List<GameCollection>>();
        addTearDown(owned.close);
        streams.add(owned);
        return owned.stream;
      }

      Future<void> platforms(
        List<PlatformGame> platformGames, {
        bool collection = true,
      }) async {
        await tester.pumpWidget(
          catalogApp(
            Scaffold(
              body: GameDetailPlatforms(
                game: catan,
                platformGames: platformGames,
                collection: collection ? collectionOf(next) : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await platforms([tabletop, steam]);
      streams.single.add([entry('pg_1', GameMedium.physical)]);
      await tester.pumpAndSettle();

      // A new list of the same platforms and a new collection, as a rebuild
      // from above hands over: the watch and its answer stay.
      await platforms([steam, tabletop]);
      expect(watched, [
        {'pg_1', 'pg_2'},
      ]);
      expect(checkOn('pg_1'), findsOneWidget);

      // A platform more, which the last answer says nothing of.
      await platforms([tabletop, steam, nintendoSwitch]);
      expect(watched.last, {'pg_1', 'pg_2', 'pg_3'});
      expect(streams.first.hasListener, isFalse);
      expect(find.byType(ActionChip), findsNothing);
      streams.last.add([entry('pg_3', GameMedium.digital)]);
      await tester.pumpAndSettle();
      expect(checkOn('pg_3'), findsOneWidget);

      // No collection, no watch.
      await platforms([tabletop, steam, nintendoSwitch], collection: false);
      expect(streams[1].hasListener, isFalse);
      expect(find.byType(ActionChip), findsNothing);

      // And none once the page goes.
      await platforms([tabletop, steam, nintendoSwitch]);
      expect(watched, hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(streams.last.hasListener, isFalse);
    });

    testWidgets('before ownership answers, chips are plain and nothing is '
        'offered', (tester) async {
      final owned = StreamController<List<GameCollection>>();
      addTearDown(owned.close);
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop, steam]);
      await show(tester, collection: collectionOf(() => owned.stream));

      expectPlain(tester);
      await tester.tap(chip('pg_2'));
      await tester.pump();
      expect(adds, isEmpty);
      expect(openedOwned, isEmpty);
    });

    testWidgets('after the ownership watch fails, chips are plain again and '
        'the add offers every platform in either medium', (tester) async {
      final owned = StreamController<List<GameCollection>>();
      addTearDown(owned.close);
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop, steam]);
      await show(tester, collection: collectionOf(() => owned.stream));
      owned.add([
        for (final id in ['pg_1', 'pg_2'])
          for (final medium in GameMedium.values) entry(id, medium),
      ]);
      await tester.pumpAndSettle();
      expect(ownedLegend, findsOneWidget);
      expect(addButton, findsNothing);

      owned.addError(StateError('the cache is gone'));
      await tester.pumpAndSettle();

      // Ownership is unknown, so nothing is said of it.
      expect(find.byType(ActionChip), findsNothing);
      expect(find.byType(Chip), findsNWidgets(2));
      expect(find.byIcon(Icons.check), findsNothing);
      expect(ownedLegend, findsNothing);
      expect(find.bySemanticsLabel(RegExp('in your collection')), findsNothing);
      expect(find.bySemanticsLabel('Tabletop'), findsOneWidget);

      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      await tester.tap(addButton);
      await tester.pump();
      expect(adds.single.platformGameId, isNull);
      expect(adds.single.options, [
        for (final platformGame in [tabletop, steam])
          CollectionAddOption(
            platformGame: platformGame,
            freeMediums: GameMedium.values.toSet(),
          ),
      ]);
    });

    /// Whether the primary focus is on a node built inside [finder].
    bool focusIn(Finder finder) {
      final focused = FocusManager.instance.primaryFocus?.context;
      return focused != null &&
          find
              .descendant(
                of: finder,
                matching: find.byElementPredicate((e) => identical(e, focused)),
              )
              .evaluate()
              .isNotEmpty;
    }

    /// Everything on Tabletop, and Steam's physical copy: the Add button
    /// offers Steam's digital copy alone.
    final allButSteamDigital = [
      entry('pg_1', GameMedium.physical),
      entry('pg_1', GameMedium.digital),
      entry('pg_2', GameMedium.physical),
    ];
    final everything = [
      ...allButSteamDigital,
      entry('pg_2', GameMedium.digital),
    ];

    testWidgets('focus on the Add button as it goes moves to the chip of the '
        'platform just filled', (tester) async {
      final owned = StreamController<List<GameCollection>>();
      addTearDown(owned.close);
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop, steam]);
      await show(tester, collection: collectionOf(() => owned.stream));
      owned.add(allButSteamDigital);
      await tester.pumpAndSettle();
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      Focus.of(
        tester.element(
          find.descendant(
            of: addButton,
            matching: find.text('Add to collection'),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      expect(focusIn(addButton), isTrue);

      owned.add(everything);
      await tester.pumpAndSettle();

      expect(addButton, findsNothing);
      expect(focusIn(chip('pg_2')), isTrue);
    });

    testWidgets('the Add button going under the open add leaves focus to come '
        'back to the chip before it', (tester) async {
      final owned = StreamController<List<GameCollection>>();
      addTearDown(owned.close);
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop, steam]);
      late BuildContext addContext;
      await show(
        tester,
        collection: GameDetailCollection(
          watchOwned: (_) => owned.stream,
          onAdd: (context, game, options, {platformGameId}) => unawaited(
            showDialog<void>(
              context: context,
              builder: (context) {
                addContext = context;
                return const AlertDialog(content: Text('The add'));
              },
            ),
          ),
          onOpenOwned: (context, items) {},
        ),
      );
      owned.add(allButSteamDigital);
      await tester.pumpAndSettle();
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();

      // From the keyboard: Steam's chip, Tab to the button, Enter.
      Focus.of(
        tester.element(
          find.descendant(of: chip('pg_2'), matching: find.text('Steam')),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusIn(addButton), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('The add'), findsOneWidget);

      owned.add(everything);
      await tester.pumpAndSettle();
      expect(addButton, findsNothing);
      Navigator.of(addContext).pop();
      await tester.pumpAndSettle();

      expect(focusIn(chip('pg_2')), isTrue);
    });

    testWidgets('without a collection, chips are plain and there is no '
        'button', (tester) async {
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop, steam]);

      await show(tester);

      expectPlain(tester);
      expect(watched, isEmpty);
    });

    testWidgets('at 320 dp and 2.0 text the chips, key and button fit', (
      tester,
    ) async {
      const view = Size(320, 640);
      useViewSize(tester, view);
      final longest = PlatformGame(
        id: 'pg_4',
        gameId: 'g_catan',
        platformId: 'plat_nes',
        platformName: 'Nintendo Entertainment System Classic Edition',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      remote.onFetchGame = (_) async => (
        game: catan,
        platformGames: [tabletop, steam, nintendoSwitch, longest],
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: view,
            textScaler: TextScaler.linear(2),
          ),
          child: catalogApp(
            GameDetailScreen(
              gameId: 'g_catan',
              remote: remote,
              collection: collectionOf(
                () => Stream.value([
                  entry('pg_1', GameMedium.physical),
                  entry('pg_3', GameMedium.physical),
                  entry('pg_3', GameMedium.digital),
                ]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(checkOn('pg_3'), findsOneWidget);
      for (final target in [
        chip('pg_1'),
        chip('pg_2'),
        chip('pg_3'),
        chip('pg_4'),
        ownedLegend,
        addButton,
      ]) {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        final rect = tester.getRect(target);
        expect(rect.left, greaterThanOrEqualTo(0), reason: '$target');
        expect(rect.right, lessThanOrEqualTo(view.width), reason: '$target');
      }
      // A name too long for any chip at this size is scaled down to fit:
      // laid out at full width, and drawn inside its chip.
      final fitted = find.descendant(
        of: chip('pg_4'),
        matching: find.byType(FittedBox),
      );
      final fullWidth = tester
          .renderObject<RenderBox>(
            find.descendant(of: fitted, matching: find.byType(RichText)),
          )
          .size
          .width;
      expect(fullWidth, greaterThan(tester.getSize(fitted).width));
      expect(
        tester.getRect(fitted).right,
        lessThanOrEqualTo(tester.getRect(actionChipOf('pg_4')).right),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the header (#735)', () {
    Future<void> showAt(
      WidgetTester tester, {
      required double scale,
      double width = 320,
      String title = 'Wingspan',
    }) async {
      final view = Size(width, 640);
      useViewSize(tester, view);
      remote.onFetchGame = (_) async => (
        game: catan.copyWith(title: title),
        platformGames: const <PlatformGame>[],
      );
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: view,
            textScaler: TextScaler.linear(scale),
          ),
          child: catalogApp(
            GameDetailScreen(gameId: 'g_catan', remote: remote),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder cover() => find.byType(BgeThumbnail);

    /// Expects the page's title under the cover, on one line at [scale].
    void expectUnderCoverOnOneLine(WidgetTester tester, double scale) {
      // The app bar repeats the title, after the page's own in the tree.
      final title = find.text('Wingspan').first;
      expect(
        tester.getTopLeft(title).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(cover()).dy),
      );
      final paragraph = tester.renderObject<RenderParagraph>(title);
      final style = tester.widget<Text>(title).style!;
      final oneLine = TextPainter(
        text: TextSpan(text: 'Wingspan', style: style),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.linear(scale),
      )..layout();
      addTearDown(oneLine.dispose);
      expect(paragraph.size.height, moreOrLessEquals(oneLine.height));
      expect(tester.takeException(), isNull);
    }

    testWidgets('at 320 dp and 2.0 text the title sits under the cover and no '
        'word breaks', (tester) async {
      await showAt(tester, scale: 2);

      expectUnderCoverOnOneLine(tester, 2);
    });

    testWidgets('at 320 dp and 1.0 text the title goes under the cover and no '
        'word breaks', (tester) async {
      await showAt(tester, scale: 1);

      expectUnderCoverOnOneLine(tester, 1);
    });

    testWidgets('at 1.0 text the title stays beside the cover where it has 8 '
        'ems', (tester) async {
      await showAt(tester, scale: 1, width: 430);

      expect(
        tester.getTopLeft(find.text('Wingspan').first).dx,
        greaterThanOrEqualTo(tester.getTopRight(cover()).dx),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('reading order stays cover, title, subtitle, facts', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // Disposed in the test body: flutter_test checks for live handles
      // before its tear-downs run.
      try {
        for (final scale in [1.0, 2.0]) {
          await showAt(tester, scale: scale);

          // The cover is drawn without semantics, so a reader passes it, and
          // what it hears is the title, then the subtitle, then the facts.
          final heard = <String>[];
          void walk(SemanticsNode node) {
            final label = node.getSemanticsData().label;
            if (label.isNotEmpty) heard.add(label);
            node.visitChildren((child) {
              walk(child);
              return true;
            });
          }

          var root = tester.getSemantics(find.text('Wingspan').first);
          while (root.parent != null) {
            root = root.parent!;
          }
          walk(root);
          // The app bar repeats the title elsewhere in the tree, so the
          // header's own is the one right before the subtitle.
          expect(
            heard.where((l) => l == 'Wingspan'),
            hasLength(2),
            reason: '$heard at $scale',
          );
          final subtitle = heard.indexOf('Trade, build, settle');
          expect(subtitle, greaterThan(0), reason: '$heard at $scale');
          expect(heard[subtitle - 1], 'Wingspan', reason: '$heard at $scale');
          expect(
            heard[subtitle + 1],
            startsWith('Base game'),
            reason: '$heard at $scale',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      } finally {
        handle.dispose();
      }
    });
  });

  group('accessibility audit', () {
    final steam = PlatformGame(
      id: 'pg_2',
      gameId: 'g_catan',
      platformId: 'plat_steam',
      platformName: 'Steam',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

    GameCollection owned(String platformGameId, GameMedium medium) =>
        GameCollection(
          id: 'e_${platformGameId}_${medium.name}',
          userId: 'u_1',
          platformGameId: platformGameId,
          medium: medium,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );

    GameDetailCollection watching(Stream<List<GameCollection>> stream) =>
        GameDetailCollection(
          watchOwned: (_) => stream,
          onAdd: (context, game, options, {platformGameId}) {},
          onOpenOwned: (context, items) {},
        );

    // Tabletop owned, Steam not: both chip kinds and the add button.
    GameDetailCollection owningTabletop() =>
        watching(Stream.value([owned('pg_1', GameMedium.physical)]));

    // The description and facts keep the page short of the fold at 390dp but
    // not at 320dp x 2.0, so the chips and the add button sit below it.
    void readyWithOwnership() {
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop, steam]);
    }

    // The fetch is held, so the spinner never settles.
    auditScreen(
      'loading',
      pump: (tester, theme) async {
        final pending = Completer<GameWithPlatformGames>();
        addTearDown(
          () => pending.complete((
            game: catan,
            platformGames: const <PlatformGame>[],
          )),
        );
        remote.onFetchGame = (_) => pending.future;
        await show(tester, theme: theme, settle: false);
        await tester.pump();
        expect(find.byKey(GameDetailScreen.loadingKey), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'unavailable',
      pump: (tester, theme) async {
        remote.onFetchGame = (_) async =>
            throw const GameNotFoundException('404');
        await show(tester, theme: theme);
        expect(find.byKey(GameDetailScreen.unavailableKey), findsOneWidget);
      },
    );

    auditScreen(
      'failed with a retry',
      pump: (tester, theme) async {
        remote.onFetchGame = (_) async => throw unreachable();
        await show(tester, theme: theme, cache: FakeGamesCache());
        expect(find.byKey(GameDetailScreen.errorKey), findsOneWidget);
        expect(find.text('Try again'), findsOneWidget);
      },
    );

    auditScreen(
      'ready, no collection',
      pump: (tester, theme) async {
        readyWithOwnership();
        await show(tester, theme: theme);
        expect(find.text('Trade, build, settle'), findsOneWidget);
        expect(find.byKey(GameDetailScreen.addKey), findsNothing);
        expect(
          find.byKey(GameDetailScreen.platformKey('pg_2')),
          findsOneWidget,
        );
      },
    );

    // Tabletop owned: the legend only an owned platform draws, a chip of
    // each kind, and the button.
    Future<void> showOwning(WidgetTester tester, ThemeData theme) async {
      readyWithOwnership();
      await show(tester, theme: theme, collection: owningTabletop());
      expect(find.byKey(GameDetailScreen.ownedLegendKey), findsOneWidget);
      expect(find.byType(ActionChip), findsNWidgets(2));
      expect(find.byKey(GameDetailScreen.addKey), findsOneWidget);
    }

    auditScreen('ready with ownership', pump: showOwning);

    auditScreen(
      'ready with ownership, scrolled to the end',
      pump: showOwning,
      arrange: scrollPageToEnd,
    );

    // The watch has not answered: plain chips, no legend, no button.
    Future<void> showUnanswered(WidgetTester tester, ThemeData theme) async {
      final pending = StreamController<List<GameCollection>>();
      addTearDown(pending.close);
      readyWithOwnership();
      await show(tester, theme: theme, collection: watching(pending.stream));
      expect(find.byType(Chip), findsNWidgets(2));
      expect(find.byType(ActionChip), findsNothing);
      expect(find.byKey(GameDetailScreen.ownedLegendKey), findsNothing);
      expect(find.byKey(GameDetailScreen.addKey), findsNothing);
    }

    auditScreen('ready, ownership not answered yet', pump: showUnanswered);

    auditScreen(
      'ready, ownership not answered yet, scrolled to the end',
      pump: showUnanswered,
      arrange: scrollPageToEnd,
    );

    // The watch failed: plain chips again, but the button offers everything.
    Future<void> showWatchFailed(WidgetTester tester, ThemeData theme) async {
      readyWithOwnership();
      await show(
        tester,
        theme: theme,
        collection: watching(
          Stream<List<GameCollection>>.error(StateError('the cache is gone')),
        ),
      );
      expect(find.byType(Chip), findsNWidgets(2));
      expect(find.byType(ActionChip), findsNothing);
      expect(find.byKey(GameDetailScreen.ownedLegendKey), findsNothing);
      expect(find.byKey(GameDetailScreen.addKey), findsOneWidget);
    }

    auditScreen('ready, ownership failed', pump: showWatchFailed);

    auditScreen(
      'ready, ownership failed, scrolled to the end',
      pump: showWatchFailed,
      arrange: scrollPageToEnd,
    );

    // Everything owned in both mediums: the legend, and no button.
    Future<void> showAllOwned(WidgetTester tester, ThemeData theme) async {
      readyWithOwnership();
      await show(
        tester,
        theme: theme,
        collection: watching(
          Stream.value([
            for (final id in ['pg_1', 'pg_2'])
              for (final medium in GameMedium.values) owned(id, medium),
          ]),
        ),
      );
      expect(find.byType(ActionChip), findsNWidgets(2));
      expect(find.byKey(GameDetailScreen.ownedLegendKey), findsOneWidget);
      expect(find.byKey(GameDetailScreen.addKey), findsNothing);
    }

    auditScreen('ready, everything owned', pump: showAllOwned);

    auditScreen(
      'ready, everything owned, scrolled to the end',
      pump: showAllOwned,
      arrange: scrollPageToEnd,
    );

    auditScreen(
      'from the cache, under the banner',
      pump: (tester, theme) async {
        remote.onFetchGame = (_) async => throw unreachable();
        await show(tester, theme: theme, cache: FakeGamesCache([catan]));
        expect(find.byKey(GameDetailScreen.fromCacheBannerKey), findsOneWidget);
        expect(find.text('Trade, build, settle'), findsOneWidget);
      },
    );
  });
}
