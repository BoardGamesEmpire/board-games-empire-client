import 'package:bge_test_support/images.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

void main() {
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
    playingTime: 90,
    minAge: 10,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  const tabletop = PlatformGameSummary(
    id: 'pg_1',
    platformId: 'plat_tabletop',
    platformName: 'Tabletop',
    game: GameSummary(id: 'g_catan', title: 'Catan'),
  );

  Future<void> show(
    WidgetTester tester, {
    String gameId = 'g_catan',
    FakeGamesCache? cache,
    void Function(BuildContext context, PlatformGameSummary platformGame)?
    onAdd,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        GameDetailScreen(
          gameId: gameId,
          remote: remote,
          cache: cache,
          onAdd: onAdd,
          openLink: (uri) async => opened.add(uri),
        ),
      ),
    );
    await tester.pumpAndSettle();
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

  testWidgets('shows the game\'s facts', (tester) async {
    remote.onFetchGame = (_) async =>
        (game: catan, platformGames: const <PlatformGameSummary>[]);

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
      'Base game · Published 1995 · 3–4 players · 90 minutes · Ages 10+',
    );
  });

  testWidgets('reads an imported game\'s play time from its range, which has '
      'no unit', (tester) async {
    // What the server's import writes: minimum and maximum, in minutes, with
    // no unit and no playingTime.
    final imported = Game(
      id: 'g_brass',
      title: 'Brass',
      minPlayTime: 60,
      maxPlayTime: 120,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    remote.onFetchGame = (_) async =>
        (game: imported, platformGames: const <PlatformGameSummary>[]);

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
      'Base game · 60–120 minutes',
    );
  });

  for (final (bound, game, facts) in [
    (
      'a lone minimum',
      // The maximum is in hours, which the screen does not show.
      (minPlayTime: 30, maxPlayTime: 2, maxUnit: TimeMeasure.hours),
      'Base game · 30+ minutes',
    ),
    (
      'a lone maximum',
      (minPlayTime: null, maxPlayTime: 120, maxUnit: null),
      'Base game · Up to 120 minutes',
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
        maxPlayTimeMeasure: game.maxUnit,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      remote.onFetchGame = (_) async =>
          (game: bounded, platformGames: const <PlatformGameSummary>[]);

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
        (game: catan, platformGames: const <PlatformGameSummary>[]);

    await show(tester);

    expect(find.textContaining('**'), findsNothing);
    expect(
      find.textContaining('the island', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('opens a web link outside the app', (tester) async {
    remote.onFetchGame = (_) async =>
        (game: catan, platformGames: const <PlatformGameSummary>[]);

    await show(tester);
    tapLink(tester, 'the rules');

    expect(opened, [Uri.parse('https://example.com/rules')]);
  });

  testWidgets('lists the platforms, with an add for each where adding is '
      'offered', (tester) async {
    remote.onFetchGame = (_) async =>
        (game: catan, platformGames: const [tabletop]);
    final added = <String>[];

    await show(tester);
    expect(find.text('Tabletop'), findsOneWidget);
    expect(find.byKey(GameDetailScreen.addKey('pg_1')), findsNothing);

    await show(tester, onAdd: (_, platformGame) => added.add(platformGame.id));
    await tester.tap(find.byKey(GameDetailScreen.addKey('pg_1')));

    expect(added, ['pg_1']);
  });

  testWidgets('rebuilt in place for another game, reads that game', (
    tester,
  ) async {
    remote.onFetchGame = (id) async => (
      game: game(id, title: 'Title of $id'),
      platformGames: const <PlatformGameSummary>[],
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
          (game: catan, platformGames: const <PlatformGameSummary>[]);

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
        (game: catan, platformGames: const <PlatformGameSummary>[]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Trade, build, settle'), findsOneWidget);
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

      testWidgets('is held to the display\'s width, keeping its shape', (
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
}
