import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

/// The quick look a DataGateway search hit opens (#713): drawn from the hit
/// alone, with nothing read. The search screen's tests check that no read is
/// sent, since only there is a remote within the quick look's reach.
void main() {
  /// Many lines of one paragraph at any width these tests use.
  final long = List.filled(80, 'word').join(' ');

  final hit = GameSearchHit(
    externalId: 'bgg-266192',
    title: 'Wingspan',
    contentType: ContentType.baseGame,
    yearPublished: 2019,
    minPlayers: 1,
    maxPlayers: 5,
    summary: 'Attract **birds** to your wildlife preserves.\n\n$long',
    platforms: const [
      GameSearchPlatform(name: 'Tabletop', platformType: PlatformType.tabletop),
      GameSearchPlatform(name: 'Steam', platformType: PlatformType.pc),
    ],
  );

  Widget opener(
    GameSearchHit hit, {
    String? sourceName,
    List<Widget> sections = const [],
    List<Widget> actions = const [],
    Widget? footer,
    QuickLookHost? host,
  }) => Builder(
    builder: (context) => TextButton(
      onPressed: () => unawaited(
        showSearchHitQuickLook(
          context,
          hit: hit,
          sourceName: sourceName,
          sections: sections,
          actions: actions,
          footer: footer,
          host: host,
        ),
      ),
      child: const Text('open'),
    ),
  );

  Future<void> open(
    WidgetTester tester,
    GameSearchHit hit, {
    String? sourceName,
    List<Widget> sections = const [],
    List<Widget> actions = const [],
    Widget? footer,
    QuickLookHost? host,
  }) async {
    await tester.pumpWidget(
      catalogApp(
        Scaffold(
          body: Center(
            child: opener(
              hit,
              sourceName: sourceName,
              sections: sections,
              actions: actions,
              footer: footer,
              host: host,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  String? factsShown(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(SearchHitQuickLook.factsKey),
          matching: find.byType(Text),
        ),
      )
      .data;

  testWidgets('shows the hit at once and reads nothing', (tester) async {
    await open(tester, hit);

    expect(find.text('Wingspan'), findsOneWidget);
    expect(find.text('Published 2019'), findsOneWidget);
    expect(find.byType(SearchHitQuickLook), findsOneWidget);
    // Nothing is there to read the game: no detail read, and no quick look
    // that makes one.
    expect(
      find.byWidgetPredicate((w) => w is BlocProvider<GameDetailBloc>),
      findsNothing,
    );
    expect(find.byType(GameQuickLook), findsNothing);
    // The year is in the header, not repeated in the facts.
    expect(factsShown(tester), '1–5 players');
    // The title is plain text: the game has no page here yet (#798).
    expect(find.byKey(GameQuickLook.titleLinkKey), findsNothing);
  });

  testWidgets('the summary is the description, shown whole', (tester) async {
    await open(tester, hit);

    expect(find.byType(GameDescription), findsOneWidget);
    expect(find.text('More'), findsNothing);
    expect(find.text('Less'), findsNothing);
  });

  testWidgets('a hit with no summary draws no description', (tester) async {
    await open(tester, hit.copyWith(summary: null));

    expect(find.byType(GameDescription), findsNothing);
  });

  testWidgets("the platforms are the hit's", (tester) async {
    await open(tester, hit);

    expect(find.byKey(SearchHitQuickLook.platformsKey), findsOneWidget);
    expect(find.byKey(const ValueKey('hit_platform_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('hit_platform_1')), findsOneWidget);
    expect(find.text('Tabletop'), findsOneWidget);
    expect(find.text('Steam'), findsOneWidget);
  });

  testWidgets('a hit with no platforms draws none', (tester) async {
    await open(tester, hit.copyWith(platforms: const []));

    expect(find.byKey(SearchHitQuickLook.platformsKey), findsNothing);
  });

  testWidgets('the source is a fact', (tester) async {
    await open(tester, hit, sourceName: 'BoardGameGeek');

    expect(factsShown(tester), '1–5 players · BoardGameGeek');
  });

  testWidgets('the title is plain text', (tester) async {
    await open(tester, hit.copyWith(title: '**Wingspan**'));

    expect(find.text('**Wingspan**'), findsOneWidget);
  });

  testWidgets('sections sit below the description', (tester) async {
    await open(
      tester,
      hit,
      sections: const [Text('A section')],
      actions: const [Text('An action')],
    );

    final section = find.text('A section');
    expect(section, findsOneWidget);
    expect(find.text('An action'), findsOneWidget);
    expect(
      tester.getTopLeft(section).dy,
      greaterThan(tester.getBottomLeft(find.byType(GameDescription)).dy),
    );
  });

  testWidgets('sections that draw nothing leave no gap below the '
      'description', (tester) async {
    // As an import's section with no checklist draws nothing until the
    // import starts.
    await open(tester, hit, sections: const [SizedBox.shrink()]);

    final content = find
        .descendant(
          of: find.descendant(
            of: find.byType(SearchHitQuickLook),
            matching: find.byType(SingleChildScrollView),
          ),
          matching: find.byType(Column),
        )
        .first;
    expect(
      tester.getBottomLeft(content).dy,
      tester.getBottomLeft(find.byType(GameDescription)).dy,
    );
  });

  group('the pinned footer (#1037)', () {
    final footer = find.byKey(SearchHitQuickLook.footerKey);

    /// The quick look's own scroll view, which the footer is pinned under.
    final body = find
        .descendant(
          of: find.byType(SearchHitQuickLook),
          matching: find.byType(Scrollable),
        )
        .first;
    final importButton = find.byKey(GameImportPanel.importKey);

    testWidgets('a hit not on the server pins its Import', (tester) async {
      useViewSize(tester, const Size(400, 500));
      final remote = FakeGamesRemote();
      await open(
        tester,
        hit,
        host: (context, layout) => GameImportPanel(
          remote: remote,
          gatewayId: 'bgg',
          hit: hit,
          mayChooseExpansions: false,
          onImported: (_, _) {},
          child: layout,
        ),
        sections: const [GameImportSection()],
        footer: const GameImportButton(),
      );

      // The host is the quick look's, around all it draws.
      expect(
        find.descendant(
          of: find.byType(SearchHitQuickLook),
          matching: find.byType(GameImportPanel),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(GameImportPanel),
          matching: find.text('Wingspan'),
        ),
        findsOneWidget,
      );
      // Import is under the scroll view, not in it, and on screen wherever
      // the long summary is scrolled to.
      expect(find.ancestor(of: importButton, matching: footer), findsOneWidget);
      expect(find.descendant(of: body, matching: importButton), findsNothing);
      expect(
        tester.getRect(footer).top,
        moreOrLessEquals(tester.getRect(body).bottom),
      );
      final position = tester.state<ScrollableState>(body).position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(importButton.hitTestable(), findsOneWidget);
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(importButton.hitTestable(), findsOneWidget);
      // Nothing is read for a hit: not the game, and no expansions unasked.
      expect(remote.calls, isEmpty);
    });

    testWidgets('with no footer the band takes no room', (tester) async {
      await open(tester, hit);

      expect(tester.getSize(footer).height, 0);
    });

    testWidgets("the keyboard's Page Down scrolls the body under a pinned "
        'footer', (tester) async {
      useViewSize(tester, const Size(400, 500));
      await open(
        tester,
        hit,
        footer: FilledButton(onPressed: () {}, child: const Text('Pinned')),
      );
      final position = tester.state<ScrollableState>(body).position;
      expect(position.pixels, 0);
      expect(position.maxScrollExtent, greaterThan(0));

      // Focus is on the pop-up, not in it, as it is when it opens: the key
      // goes to the route's primary scroll view, which is the body alone.
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(position.pixels, greaterThan(0));
    });

    for (final (width, form) in [(500.0, 'a sheet'), (700.0, 'a dialog')]) {
      testWidgets('in $form, a footer taller than half the pop-up is held to '
          'half, and scrolls within it', (tester) async {
        useViewSize(tester, Size(width, 600));
        await open(
          tester,
          hit,
          footer: Column(
            children: [
              for (var n = 1; n <= 12; n++)
                FilledButton(onPressed: () {}, child: Text('Action $n')),
            ],
          ),
        );
        expect(tester.takeException(), isNull);
        expect(
          find.byType(width < 600 ? BottomSheet : Dialog),
          findsOneWidget,
        );

        // Half each, of all the pop-up may be: the body is never starved.
        final layout = tester.getSize(find.byType(SearchHitQuickLook));
        final band = tester.getRect(footer);
        final view = tester.getRect(body);
        expect(band.height, moreOrLessEquals(layout.height / 2));
        expect(view.height, moreOrLessEquals(layout.height / 2));
        expect(band.top, moreOrLessEquals(view.bottom));
        expect(
          tester.state<ScrollableState>(body).position.maxScrollExtent,
          greaterThan(0),
        );

        // The footer's last action is reached by scrolling the footer.
        final last = find.widgetWithText(FilledButton, 'Action 12');
        expect(last.hitTestable(), findsNothing);
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        expect(tester.getRect(last).bottom, lessThanOrEqualTo(band.bottom));
        expect(tester.takeException(), isNull);
      });
    }
  });

  for (final (width, label) in [(500.0, 'a sheet'), (700.0, 'a dialog')]) {
    testWidgets(
      'opened through showSearchHitQuickLook, it is $label at '
      '${width.toInt()} dp',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await open(tester, hit);

        expect(
          find.byType(BottomSheet),
          width < 600 ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(Dialog),
          width < 600 ? findsNothing : findsOneWidget,
        );
      },
    );
  }

  test('a seed from a hit the server holds carries its id and thumbnail', () {
    final seed = GameQuickLookSeed.fromHit(
      hit.copyWith(gameId: 'g_wingspan', thumbnailUrl: 'https://x/t.png'),
    );

    expect(seed.id, 'g_wingspan');
    expect(seed.title, 'Wingspan');
    expect(seed.thumbnail, 'https://x/t.png');
    expect(seed.game, isNull);
  });

  group('accessibility audit', () {
    auditScreen(
      'a hit',
      build: (theme) => catalogApp(
        Scaffold(
          body: Center(child: opener(hit, sourceName: 'BoardGameGeek')),
        ),
        theme: theme,
      ),
      arrange: (tester) async {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byType(SearchHitQuickLook), findsOneWidget);
      },
    );
  });
}
