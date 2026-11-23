import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';

import '../support/catalog_app.dart';

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
  }) => Builder(
    builder: (context) => TextButton(
      onPressed: () => unawaited(
        showSearchHitQuickLook(
          context,
          hit: hit,
          sourceName: sourceName,
          sections: sections,
          actions: actions,
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
    expect(find.text('View full details'), findsNothing);
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
