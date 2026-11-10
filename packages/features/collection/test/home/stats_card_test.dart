import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_connectivity.dart';
import '../support/fake_stats_sources.dart';
import '../support/list_items.dart';

const _landed = Hydration(state: HydrationState.refreshed, everRefreshed: true);

void main() {
  late FakeOwnGames own;
  late FakeGamePool pool;
  late FakeConnectivity connectivity;
  late StreamController<List<Household>> households;
  late StreamController<Hydration> householdHydration;
  late GlobalKey<NavigatorState> navigatorKey;

  setUp(() {
    own = FakeOwnGames();
    pool = FakeGamePool();
    connectivity = FakeConnectivity();
    households = StreamController<List<Household>>.broadcast();
    householdHydration = StreamController<Hydration>.broadcast();
    navigatorKey = GlobalKey<NavigatorState>();
  });

  tearDown(() {
    unawaited(own.close());
    unawaited(connectivity.close());
    unawaited(households.close());
    unawaited(householdHydration.close());
  });

  /// The card, in a scrolling page as the home page holds it. [textScaler],
  /// when given, overrides the scale the view gives the app.
  Widget harness({
    void Function(BuildContext context)? onOpenHouseholds,
    Stream<List<Household>>? Function()? householdsOf,
    bool householdHydrate = false,
    TextScaler? textScaler,
    ThemeData? theme,
    TextDirection direction = TextDirection.ltr,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: GameCollectionLocalizations.localizationsDelegates,
    supportedLocales: GameCollectionLocalizations.supportedLocales,
    builder: (context, child) {
      final app = Directionality(textDirection: direction, child: child!);
      if (textScaler == null) return app;
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: app,
      );
    },
    home: Scaffold(
      body: SingleChildScrollView(
        child: StatsCard(
          collection: own,
          households: householdsOf ?? () => households.stream,
          householdHydration: householdHydrate
              ? householdHydration.stream
              : null,
          pool: pool,
          connectivity: connectivity,
          onOpenHouseholds: onOpenHouseholds ?? (_) {},
        ),
      ),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    List<GameCollectionListItem>? games,
    List<Household>? inHouseholds,
    void Function(BuildContext context)? onOpenHouseholds,
    bool householdHydrate = false,
    TextScaler? textScaler,
    ThemeData? theme,
    TextDirection direction = TextDirection.ltr,
  }) async {
    await tester.pumpWidget(
      harness(
        onOpenHouseholds: onOpenHouseholds,
        householdHydrate: householdHydrate,
        textScaler: textScaler,
        theme: theme,
        direction: direction,
      ),
    );
    if (games != null) own.emit(games);
    if (inHouseholds != null) households.add(inHouseholds);
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, Key key) =>
      tester.widget<Text>(find.byKey(key)).data!;

  Finder byKey(Key key) => find.byKey(key);

  group('the numbers', () {
    testWidgets('heading and both counts', (tester) async {
      pool.answer(7);

      await show(
        tester,
        games: [
          listItem('a', gameId: 'g-1'),
          listItem('b', gameId: 'g-1', medium: GameMedium.digital),
          listItem('c', gameId: 'g-2'),
        ],
        inHouseholds: [household('h1')],
      );

      expect(textOf(tester, StatsCard.headingKey), 'Your stats');
      expect(textOf(tester, StatsCard.ownedKey), '2 games in your collection');
      expect(
        textOf(tester, StatsCard.householdsKey),
        '7 games across your households',
      );
      expect(byKey(StatsCard.promptKey), findsNothing);
      expect(pool.reads, [1]);
    });

    testWidgets('1 game reads in the singular', (tester) async {
      pool.answer(1);

      await show(
        tester,
        games: [listItem('a')],
        inHouseholds: [household('h1')],
      );

      expect(textOf(tester, StatsCard.ownedKey), '1 game in your collection');
      expect(
        textOf(tester, StatsCard.householdsKey),
        '1 game across your households',
      );
    });

    testWidgets('0 is a count, and says so', (tester) async {
      pool.answer(0);

      await show(tester, games: const [], inHouseholds: [household('h1')]);

      expect(textOf(tester, StatsCard.ownedKey), '0 games in your collection');
      expect(
        textOf(tester, StatsCard.householdsKey),
        '0 games across your households',
      );
    });

    testWidgets('a count that is not known draws no line', (tester) async {
      await show(tester, games: [listItem('a')]);

      expect(byKey(StatsCard.headingKey), findsOneWidget);
      expect(byKey(StatsCard.ownedKey), findsOneWidget);
      expect(byKey(StatsCard.householdsKey), findsNothing);
      expect(byKey(StatsCard.promptKey), findsNothing);
    });

    testWidgets('the heading is a header on a node of its own, and each count '
        'is a node of its own, not a header', (tester) async {
      final handle = tester.ensureSemantics();
      pool.answer(7);

      await show(
        tester,
        games: [listItem('a')],
        inHouseholds: [household('h1')],
      );

      final heading = tester.getSemantics(byKey(StatsCard.headingKey));
      final owned = tester.getSemantics(byKey(StatsCard.ownedKey));
      final households = tester.getSemantics(byKey(StatsCard.householdsKey));
      expect(heading, isSemantics(label: 'Your stats', isHeader: true));
      expect(
        owned,
        isSemantics(label: '1 game in your collection', isHeader: false),
      );
      expect(
        households,
        isSemantics(label: '7 games across your households', isHeader: false),
      );
      expect({heading.id, owned.id, households.id}, hasLength(3));
      handle.dispose();
    });

    testWidgets('beside the prompt, the heading and the count are still nodes '
        'of their own, and the button is a third', (tester) async {
      final handle = tester.ensureSemantics();

      await show(tester, games: [listItem('a')], inHouseholds: const []);

      final heading = tester.getSemantics(byKey(StatsCard.headingKey));
      final owned = tester.getSemantics(byKey(StatsCard.ownedKey));
      final prompt = tester.getSemantics(byKey(StatsCard.promptKey));
      expect(heading, isSemantics(label: 'Your stats', isHeader: true));
      expect(
        owned,
        isSemantics(label: '1 game in your collection', isHeader: false),
      );
      expect(
        prompt,
        isSemantics(label: 'Create or join a household', isButton: true),
      );
      expect({heading.id, owned.id, prompt.id}, hasLength(3));
      handle.dispose();
    });

    testWidgets('hidden draws no household line, and the collection count '
        'stays', (tester) async {
      pool.fail();

      await show(
        tester,
        games: [listItem('a')],
        inHouseholds: [household('h1')],
      );

      expect(byKey(StatsCard.householdsKey), findsNothing);
      expect(byKey(StatsCard.promptKey), findsNothing);
      expect(textOf(tester, StatsCard.ownedKey), '1 game in your collection');
    });

    testWidgets('offline hides the household line, and the collection count '
        'stays', (tester) async {
      pool.answer(7);
      await show(
        tester,
        games: [listItem('a')],
        inHouseholds: [household('h1')],
      );
      expect(byKey(StatsCard.householdsKey), findsOneWidget);

      connectivity.change(ConnectivityState.offline);
      await tester.pumpAndSettle();

      expect(byKey(StatsCard.householdsKey), findsNothing);
      expect(textOf(tester, StatsCard.ownedKey), '1 game in your collection');
    });
  });

  group('with no line to show', () {
    testWidgets('neither line known draws no card, and no heading', (
      tester,
    ) async {
      await show(tester);

      expect(byKey(StatsCard.headingKey), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(tester.getSize(find.byType(StatsCard)).height, 0);
    });

    testWidgets('a collection line arriving brings the card, and its going '
        'takes the card with it', (tester) async {
      await show(tester);
      expect(find.byType(Card), findsNothing);

      own.emit([listItem('a')]);
      await tester.pumpAndSettle();

      expect(find.byType(Card), findsOneWidget);
      expect(textOf(tester, StatsCard.headingKey), 'Your stats');
      expect(textOf(tester, StatsCard.ownedKey), '1 game in your collection');

      own.fail();
      await tester.pumpAndSettle();

      expect(find.byType(Card), findsNothing);
      expect(byKey(StatsCard.headingKey), findsNothing);
    });

    testWidgets('a household line alone brings the card', (tester) async {
      pool.answer(7);
      await show(tester);
      expect(find.byType(Card), findsNothing);

      households.add([household('h1')]);
      await tester.pumpAndSettle();

      expect(textOf(tester, StatsCard.headingKey), 'Your stats');
      expect(byKey(StatsCard.ownedKey), findsNothing);
      expect(
        textOf(tester, StatsCard.householdsKey),
        '7 games across your households',
      );
    });

    testWidgets('the prompt alone brings the card', (tester) async {
      await show(tester);
      expect(find.byType(Card), findsNothing);

      households.add(const []);
      await tester.pumpAndSettle();

      expect(textOf(tester, StatsCard.headingKey), 'Your stats');
      expect(byKey(StatsCard.ownedKey), findsNothing);
      expect(byKey(StatsCard.promptKey), findsOneWidget);
    });

    testWidgets('reads again when uncovered while it is blank, and the card '
        'comes up with the count', (tester) async {
      pool.fail();
      await show(tester, inHouseholds: [household('h1')]);
      expect(pool.reads, [1]);
      expect(find.byType(Card), findsNothing);

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(pool.reads, [1], reason: 'covering it reads nothing');

      pool.answer(8);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(pool.reads, [1, 1]);
      expect(
        textOf(tester, StatsCard.householdsKey),
        '8 games across your households',
      );
      expect(textOf(tester, StatsCard.headingKey), 'Your stats');
    });

    testWidgets('the cubit stays mounted as the card comes and goes', (
      tester,
    ) async {
      var asked = 0;
      await tester.pumpWidget(
        harness(
          householdsOf: () {
            asked++;
            return households.stream;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);

      own.emit([listItem('a')]);
      await tester.pumpAndSettle();
      own.fail();
      await tester.pumpAndSettle();
      own.emit([listItem('a')]);
      await tester.pumpAndSettle();

      expect(asked, 1);
      expect(find.byType(Card), findsOneWidget);
    });
  });

  group('the prompt', () {
    testWidgets('the prompt calls onOpenHouseholds, and the collection count '
        'stays', (tester) async {
      final opened = <BuildContext>[];

      await show(
        tester,
        games: [listItem('a')],
        inHouseholds: const [],
        onOpenHouseholds: opened.add,
      );

      expect(byKey(StatsCard.householdsKey), findsNothing);
      expect(
        find.descendant(
          of: byKey(StatsCard.promptKey),
          matching: find.text('Create or join a household'),
        ),
        findsOneWidget,
      );
      expect(textOf(tester, StatsCard.ownedKey), '1 game in your collection');
      expect(pool.reads, isEmpty, reason: 'a user with no household asks none');

      await tester.tap(byKey(StatsCard.promptKey));
      await tester.pump();

      expect(opened, hasLength(1));
      expect(opened.single.mounted, isTrue);
      expect(textOf(tester, StatsCard.ownedKey), '1 game in your collection');
    });

    testWidgets('waits for the first household pass', (tester) async {
      await show(tester, inHouseholds: const [], householdHydrate: true);
      expect(byKey(StatsCard.promptKey), findsNothing);

      householdHydration.add(_landed);
      await tester.pumpAndSettle();

      expect(byKey(StatsCard.promptKey), findsOneWidget);
    });

    testWidgets('is a button that is enabled and takes focus', (tester) async {
      final handle = tester.ensureSemantics();

      await show(tester, inHouseholds: const []);

      expect(
        tester.getSemantics(byKey(StatsCard.promptKey)),
        isSemantics(
          label: 'Create or join a household',
          isButton: true,
          isEnabled: true,
          isFocusable: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('its focus ring follows its own rounded corners, inside its '
        'edge (#644)', (tester) async {
      await show(tester, inHouseholds: const []);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final ring = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: byKey(StatsCard.promptKey),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((paint) => paint.foregroundPainter)
          .whereType<BgeButtonFocusRingPainter>()
          .single;
      const tokens = BgeTokens.standard;
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusSm),
      );
      expect(ring.color, BgeTheme.light().colorScheme.primary);
      expect(ring.shape, shape, reason: 'not the theme stadium');
      // A `TextButton()` clips to its shape, so its ring is inside the edge.
      expect(ring.placement, BgeButtonFocusRingPlacement.inside);

      // And it is drawn so: just inside the left edge, a little below the top
      // corner, is on a rounded rectangle's ring. A stadium this tall would
      // curve away from the edge there and leave the button's inside showing.
      var boundary = tester.renderObject(byKey(StatsCard.promptKey));
      while (!boundary.isRepaintBoundary) {
        boundary = boundary.parent!;
      }
      final button = tester.renderObject<RenderBox>(
        find
            .descendant(
              of: byKey(StatsCard.promptKey),
              matching: find.byType(Material),
            )
            .first,
      );
      final corner = button.localToGlobal(
        Offset(
          tokens.focusOutlineWidth / 2,
          tokens.radiusSm + tokens.focusOutlineWidth / 2,
        ),
        ancestor: boundary,
      );
      final pixel = (await tester.runAsync(() async {
        final image = await (boundary.debugLayer! as OffsetLayer).toImage(
          boundary.paintBounds,
        );
        final bytes = (await image.toByteData())!;
        final at = (corner.dy.floor() * image.width + corner.dx.floor()) * 4;
        image.dispose();
        return Color.fromARGB(
          bytes.getUint8(at + 3),
          bytes.getUint8(at),
          bytes.getUint8(at + 1),
          bytes.getUint8(at + 2),
        );
      }))!;
      expect(pixel, ring.color);
    });

    testWidgets('keeps its element and its focus as the lines above it come '
        'and go', (tester) async {
      await show(tester, inHouseholds: const []);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);
      final button = tester.element(byKey(StatsCard.promptKey));

      Future<void> expectUntouched(String when) async {
        await tester.pumpAndSettle();
        expect(
          tester.element(byKey(StatsCard.promptKey)),
          same(button),
          reason: when,
        );
        expect(FocusManager.instance.primaryFocus, same(focused), reason: when);
      }

      own.emit([listItem('a')]);
      await expectUntouched('the collection line appears');
      expect(byKey(StatsCard.ownedKey), findsOneWidget);

      own.emit([listItem('a'), listItem('b')]);
      await expectUntouched('the collection count changes');

      own.fail();
      await expectUntouched('the collection line goes');
      expect(byKey(StatsCard.ownedKey), findsNothing);

      own.emit(const []);
      await expectUntouched('it comes back as a 0');
      expect(textOf(tester, StatsCard.ownedKey), '0 games in your collection');

      // The page being uncovered reads again, and a user with no household has
      // nothing to read.
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.element(byKey(StatsCard.promptKey)), same(button));
      expect(pool.reads, isEmpty);
    });
  });

  group('across states', () {
    testWidgets('the collection line keeps its element as the household line '
        'comes and goes', (tester) async {
      pool.answer(7);
      await show(
        tester,
        games: [listItem('a')],
        inHouseholds: [household('h1')],
      );
      final owned = tester.element(byKey(StatsCard.ownedKey));
      expect(byKey(StatsCard.householdsKey), findsOneWidget);

      connectivity.change(ConnectivityState.offline);
      await tester.pumpAndSettle();
      expect(byKey(StatsCard.householdsKey), findsNothing);
      expect(tester.element(byKey(StatsCard.ownedKey)), same(owned));

      connectivity.change(ConnectivityState.online);
      await tester.pumpAndSettle();
      expect(byKey(StatsCard.householdsKey), findsOneWidget);
      expect(tester.element(byKey(StatsCard.ownedKey)), same(owned));

      households.add(const []);
      await tester.pumpAndSettle();
      expect(byKey(StatsCard.promptKey), findsOneWidget);
      expect(tester.element(byKey(StatsCard.ownedKey)), same(owned));
    });

    testWidgets('reads again when uncovered', (tester) async {
      pool.answer(7);
      await show(tester, inHouseholds: [household('h1')]);
      expect(pool.reads, [1]);

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(pool.reads, [1], reason: 'covering it reads nothing');

      pool.answer(8);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(pool.reads, [1, 1]);
      expect(
        textOf(tester, StatsCard.householdsKey),
        '8 games across your households',
      );
    });

    testWidgets('reads again on reconnecting', (tester) async {
      pool.answer(7);
      connectivity.current = ConnectivityState.offline;
      await show(tester, inHouseholds: [household('h1')]);
      expect(pool.reads, isEmpty);
      expect(byKey(StatsCard.householdsKey), findsNothing);

      connectivity.change(ConnectivityState.online);
      await tester.pumpAndSettle();

      expect(pool.reads, [1]);
      expect(
        textOf(tester, StatsCard.householdsKey),
        '7 games across your households',
      );
    });

    testWidgets('asks for the households stream once', (tester) async {
      var asked = 0;
      await tester.pumpWidget(
        harness(
          householdsOf: () {
            asked++;
            return households.stream;
          },
        ),
      );
      await tester.pumpWidget(
        harness(
          householdsOf: () {
            asked++;
            return households.stream;
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(asked, 1);
    });

    testWidgets('leaving the page closes its streams quietly', (tester) async {
      pool.answer(7);
      await show(
        tester,
        games: [listItem('a')],
        inHouseholds: [household('h1')],
      );

      await tester.pumpWidget(const SizedBox());
      own.emit([listItem('a'), listItem('b')]);
      households.add(const []);
      connectivity.change(ConnectivityState.offline);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('layout', () {
    // Half of an 840 page, and the narrowest window.
    for (final width in <double>[420, 320]) {
      for (final scale in <double>[1, 2]) {
        for (final prompt in [false, true]) {
          testWidgets('${width == 420 ? 'half of 840' : '320dp'} at $scale, '
              '${prompt ? 'the prompt' : 'both counts'}: '
              'no overflow, no clipped text', (tester) async {
            useViewSize(tester, Size(width, 800));
            pool.answer(12345);

            await show(
              tester,
              games: [for (var n = 0; n < 1234; n++) listItem('$n')],
              inHouseholds: prompt ? const [] : [household('h1')],
              textScaler: TextScaler.linear(scale),
            );

            expect(tester.takeException(), isNull);
            expect(
              MediaQuery.textScalerOf(
                tester.element(byKey(StatsCard.headingKey)),
              ).scale(10),
              10 * scale,
              reason: 'the scale reaches the card',
            );

            final card = tester.getRect(find.byType(Card));
            expect(card.left, greaterThanOrEqualTo(0));
            expect(card.right, lessThanOrEqualTo(width));

            final texts = [
              StatsCard.headingKey,
              StatsCard.ownedKey,
              if (prompt) StatsCard.promptKey else StatsCard.householdsKey,
            ];
            for (final key in texts) {
              final rect = tester.getRect(byKey(key));
              expect(
                rect.left,
                greaterThanOrEqualTo(card.left),
                reason: '$key',
              );
              expect(rect.right, lessThanOrEqualTo(card.right), reason: '$key');
              expect(
                rect.bottom,
                lessThanOrEqualTo(card.bottom),
                reason: '$key',
              );
            }

            // Every line of text is whole: none is cut short, and none
            // reaches past the edge of the card it is in.
            for (final paragraph in tester.renderObjectList<RenderParagraph>(
              find.descendant(
                of: find.byType(Card),
                matching: find.byType(RichText),
              ),
            )) {
              expect(paragraph.didExceedMaxLines, isFalse);
              expect(paragraph.maxLines, isNull);
              expect(paragraph.overflow, TextOverflow.clip);
            }
            for (final text in tester.widgetList<Text>(
              find.descendant(
                of: find.byType(Card),
                matching: find.byType(Text),
              ),
            )) {
              expect(text.maxLines, isNull, reason: '${text.data}');
              expect(text.overflow, isNull, reason: '${text.data}');
            }

            if (width == 320 && scale == 2) {
              // The count does not fit on one line, and wraps instead.
              final owned = tester.renderObject<RenderParagraph>(
                find
                    .descendant(
                      of: byKey(StatsCard.ownedKey),
                      matching: find.byType(RichText),
                    )
                    .first,
              );
              final lines = owned
                  .getBoxesForSelection(
                    TextSelection(
                      baseOffset: 0,
                      extentOffset: textOf(tester, StatsCard.ownedKey).length,
                    ),
                  )
                  .map((box) => box.top)
                  .toSet();
              expect(lines.length, greaterThan(1), reason: 'it wrapped');
            }

            if (!prompt) return;
            final button = tester.getRect(byKey(StatsCard.promptKey));
            expect(
              button.height,
              greaterThanOrEqualTo(BgeTokens.standard.minTapTarget),
            );
            expect(
              button.width,
              greaterThanOrEqualTo(BgeTokens.standard.minTapTarget),
            );
            final label = tester.getRect(
              find.descendant(
                of: byKey(StatsCard.promptKey),
                matching: find.text('Create or join a household'),
              ),
            );
            expect(label.left, greaterThanOrEqualTo(button.left));
            expect(label.right, lessThanOrEqualTo(button.right));
            expect(label.top, greaterThanOrEqualTo(button.top));
            expect(label.bottom, lessThanOrEqualTo(button.bottom));
          });
        }
      }
    }

    testWidgets('the card has no margin, so it lines up with other sections', (
      tester,
    ) async {
      await show(tester, games: const []);

      final surface = tester.getRect(
        find
            .descendant(of: find.byType(Card), matching: find.byType(Material))
            .first,
      );
      expect(surface.left, 0);
      expect(surface.top, 0);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets("the prompt's label lines up with the lines above it at "
          '$scale text, and is still a 48dp target', (tester) async {
        await show(
          tester,
          games: const [],
          inHouseholds: const [],
          textScaler: TextScaler.linear(scale),
        );

        final left = tester.getTopLeft(byKey(StatsCard.headingKey)).dx;
        expect(tester.getTopLeft(byKey(StatsCard.ownedKey)).dx, left);
        expect(
          tester
              .getTopLeft(
                find.descendant(
                  of: byKey(StatsCard.promptKey),
                  matching: find.text('Create or join a household'),
                ),
              )
              .dx,
          left,
        );
        final button = tester.getSize(byKey(StatsCard.promptKey));
        expect(button.height, greaterThanOrEqualTo(48));
        expect(button.width, greaterThanOrEqualTo(48));
      });
    }

    testWidgets("the prompt's label lines up with the lines above it in a "
        'right-to-left language too', (tester) async {
      await show(
        tester,
        games: const [],
        inHouseholds: const [],
        direction: TextDirection.rtl,
      );

      final right = tester.getTopRight(byKey(StatsCard.headingKey)).dx;
      expect(tester.getTopRight(byKey(StatsCard.ownedKey)).dx, right);
      expect(
        tester
            .getTopRight(
              find.descendant(
                of: byKey(StatsCard.promptKey),
                matching: find.text('Create or join a household'),
              ),
            )
            .dx,
        right,
      );
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets("the prompt's tint holds its label, with room at both ends "
          'and small corners, at $scale text', (tester) async {
        const tokens = BgeTokens.standard;
        await show(
          tester,
          games: const [],
          inHouseholds: const [],
          textScaler: TextScaler.linear(scale),
        );

        final button = tester.getRect(byKey(StatsCard.promptKey));
        final label = tester.getRect(
          find.descendant(
            of: byKey(StatsCard.promptKey),
            matching: find.text('Create or join a household'),
          ),
        );
        expect(label.left - button.left, tokens.spaceSm);
        expect(
          button.right - label.right,
          greaterThanOrEqualTo(tokens.spaceSm),
        );

        // Corners no wider than the room the label has, so that the tint's
        // edge never cuts under its first or last letter.
        final shape =
            tester
                    .widget<TextButton>(byKey(StatsCard.promptKey))
                    .style!
                    .shape!
                    .resolve(const {})!
                as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(tokens.radiusSm));
        expect(tokens.radiusSm, lessThanOrEqualTo(tokens.spaceSm));

        // And the card still holds the tint, which reaches out of the column.
        final card = tester.getRect(find.byType(Card));
        expect(button.left, greaterThanOrEqualTo(card.left));
        expect(button.right, lessThanOrEqualTo(card.right));
      });
    }

    for (final direction in TextDirection.values) {
      testWidgets('the prompt takes a press and a hover in the room around its '
          'label, as well as on it, in ${direction.name}', (tester) async {
        final opened = <BuildContext>[];
        await show(
          tester,
          games: const [],
          inHouseholds: const [],
          onOpenHouseholds: opened.add,
          direction: direction,
        );
        final rtl = direction == TextDirection.rtl;
        final button = tester.getRect(byKey(StatsCard.promptKey));
        final label = tester.getRect(
          find.descendant(
            of: byKey(StatsCard.promptKey),
            matching: find.text('Create or join a household'),
          ),
        );
        final y = button.center.dy;
        final room = BgeTokens.standard.spaceSm / 2;
        // Where the label starts, a little beyond it, and either end of the
        // tint.
        final xs = [
          if (rtl) label.right + room else label.left - room,
          if (rtl) button.right - 1 else button.left + 1,
          if (rtl) button.left + 1 else button.right - 1,
          if (rtl) label.right - 1 else label.left + 1,
        ];

        // What hovers the button is the mouse region under it.
        final regions = tester.renderObjectList<RenderMouseRegion>(
          find.descendant(
            of: byKey(StatsCard.promptKey),
            matching: find.byType(MouseRegion),
          ),
        );
        for (final x in xs) {
          opened.clear();
          await tester.tapAt(Offset(x, y));
          await tester.pump();
          expect(opened, hasLength(1), reason: 'a press at x=$x');

          final hit = tester.hitTestOnBinding(Offset(x, y));
          expect(
            hit.path.any((entry) => regions.contains(entry.target)),
            isTrue,
            reason: 'a hover at x=$x',
          );
        }
      });
    }

    testWidgets('the prompt is a 48dp target even under a theme that shrinks '
        'its buttons', (tester) async {
      final opened = <BuildContext>[];
      await show(
        tester,
        inHouseholds: const [],
        onOpenHouseholds: opened.add,
        theme: BgeTheme.light().copyWith(
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );

      final button = tester.getRect(byKey(StatsCard.promptKey));
      expect(button.height, greaterThanOrEqualTo(48));
      expect(button.width, greaterThanOrEqualTo(48));

      // Just inside the target's top and bottom edges.
      await tester.tapAt(button.topCenter + const Offset(0, 1));
      await tester.tapAt(button.bottomCenter - const Offset(0, 1));

      expect(opened, hasLength(2));
    });
  });

  // Home composes the card in `BgeApp`, so `HomeScreen`'s own audit hosts a
  // placeholder in its place; the card is audited here, in a scrolling page
  // as home holds it (#50). It has no loading or failure UI of its own: it
  // draws nothing until a line is known, and a household count it can't
  // vouch for is left out, which the failure call audits.
  group('accessibility audit', () {
    Widget build(ThemeData theme) =>
        harness(theme: theme, onOpenHouseholds: (_) {});

    /// The collection holds one game, and the user is in [inHouseholds].
    Future<void> showLines(
      WidgetTester tester, {
      required List<Household> inHouseholds,
    }) async {
      own.emit([listItem('a')]);
      households.add(inHouseholds);
      await tester.pumpAndSettle();
    }

    auditScreen(
      'ready',
      build: build,
      arrange: (tester) async {
        pool.answer(7);
        await showLines(tester, inHouseholds: [household('h1')]);
        expect(byKey(StatsCard.ownedKey), findsOneWidget);
        expect(byKey(StatsCard.householdsKey), findsOneWidget);
      },
    );

    // In no household: the link to the households screen in the count's
    // place.
    auditScreen(
      'ready, in no household',
      build: build,
      arrange: (tester) async {
        await showLines(tester, inHouseholds: const []);
        expect(byKey(StatsCard.promptKey), findsOneWidget);
      },
    );

    // The households' count couldn't be read: the collection's line alone.
    auditScreen(
      'failure',
      build: build,
      arrange: (tester) async {
        pool.fail();
        await showLines(tester, inHouseholds: [household('h1')]);
        expect(byKey(StatsCard.ownedKey), findsOneWidget);
        expect(byKey(StatsCard.householdsKey), findsNothing);
        expect(byKey(StatsCard.promptKey), findsNothing);
      },
    );
  });
}
