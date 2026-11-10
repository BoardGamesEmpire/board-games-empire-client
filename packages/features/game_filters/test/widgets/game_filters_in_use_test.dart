import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsAction, SemanticsNode;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';

import '../support/game_filters_app.dart';

// #715: the chips naming the filters in use, for the medium, the
// missing-base switch and a flipped filter, and the count the Filters button
// shows beside them.

/// Pumps the chips for [filter] under [options]. Returns the list each
/// filter a chip hands back is added to, in order.
Future<List<CollectionFilter>> _showChips(
  WidgetTester tester,
  CollectionFilter filter, {
  GameFilterOptions options = everyOption,
}) async {
  final sent = <CollectionFilter>[];
  await tester.pumpWidget(
    gameFiltersApp(
      Scaffold(
        body: GameFiltersInUse(
          filter: filter,
          options: options,
          onChanged: sent.add,
        ),
      ),
    ),
  );
  return sent;
}

/// The text a chip shows for the filter in use [id].
String? _shown(WidgetTester tester, String id) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(GameFilterKeys.inUse(id)),
        matching: find.byType(Text),
      ),
    )
    .data;

void main() {
  testWidgets('a medium and the missing-base switch each show as a chip', (
    tester,
  ) async {
    await _showChips(
      tester,
      const CollectionFilter(
        mediums: {GameMedium.physical, GameMedium.digital},
        missingBaseGame: true,
      ),
    );

    expect(_shown(tester, 'medium_physical'), 'Physical');
    expect(_shown(tester, 'medium_digital'), 'Digital');
    expect(_shown(tester, 'missing_base_game'), 'Missing base game');
  });

  testWidgets("a flipped filter's chip says Not", (tester) async {
    final handle = tester.ensureSemantics();
    await _showChips(
      tester,
      const CollectionFilter(
        game: GameSearchFilter(
          platformTypes: {PlatformType.tabletop},
          playerCount: GameSearchRange(min: 2, max: 4),
          publishYear: GameSearchRange(min: 1990, includeUnknown: true),
        ),
        mediums: {GameMedium.physical},
        missingBaseGame: true,
        excluded: {
          CollectionFacet.platformType,
          CollectionFacet.playerCount,
          CollectionFacet.publishYear,
          CollectionFacet.missingBaseGame,
        },
      ),
    );

    expect(_shown(tester, 'platform_tabletop'), 'Not Tabletop');
    expect(_shown(tester, 'players'), 'Not 2–4 players');
    expect(_shown(tester, 'year'), 'Not From 1990 or no year');
    expect(_shown(tester, 'missing_base_game'), 'Not missing base game');
    // A facet that isn't flipped reads as before.
    expect(_shown(tester, 'medium_physical'), 'Physical');

    expect(find.bySemanticsLabel('Not 2 to 4 players'), findsOneWidget);
    expect(find.byTooltip('Remove Not 2 to 4 players'), findsOneWidget);
    expect(find.byTooltip('Remove Not missing base game'), findsOneWidget);
    handle.dispose();
  });

  group('removing a chip', () {
    testWidgets('removing a flipped chip clears the facet and the flip', (
      tester,
    ) async {
      final sent = await _showChips(
        tester,
        const CollectionFilter(
          game: GameSearchFilter(
            platformTypes: {PlatformType.tabletop},
            playerCount: GameSearchRange(min: 2, max: 4),
          ),
          excluded: {CollectionFacet.platformType, CollectionFacet.playerCount},
        ),
      );

      await tester.tap(find.byTooltip('Remove Not Tabletop'));
      await tester.pump();

      expect(
        sent.single,
        const CollectionFilter(
          game: GameSearchFilter(playerCount: GameSearchRange(min: 2, max: 4)),
          excluded: {CollectionFacet.playerCount},
        ),
      );
    });

    testWidgets('a flip stays while its facet has a value left', (
      tester,
    ) async {
      final sent = await _showChips(
        tester,
        const CollectionFilter(
          mediums: {GameMedium.physical, GameMedium.digital},
          excluded: {CollectionFacet.medium},
        ),
      );

      await tester.tap(find.byTooltip('Remove Not Physical'));
      await tester.pump();

      expect(
        sent.single,
        const CollectionFilter(
          mediums: {GameMedium.digital},
          excluded: {CollectionFacet.medium},
        ),
      );
    });

    testWidgets('the missing-base chip takes its flip with it', (tester) async {
      final sent = await _showChips(
        tester,
        const CollectionFilter(
          missingBaseGame: true,
          excluded: {CollectionFacet.missingBaseGame},
        ),
      );

      await tester.tap(find.byKey(GameFilterKeys.inUse('missing_base_game')));
      await tester.pump();

      expect(sent.single, const CollectionFilter());
    });
  });

  group('focus (#715)', () {
    /// Three platform chips, in the sheet's order: Tabletop, Console, PC.
    const three = CollectionFilter(
      game: GameSearchFilter(
        platformTypes: {
          PlatformType.tabletop,
          PlatformType.console,
          PlatformType.pc,
        },
      ),
    );

    /// The chips for a filter the page holds and applies as each chip
    /// sends it, unless [ignore]. A button above them stands for the
    /// caller's own control. Returns how often [GameFiltersInUse.onEmptied]
    /// was called, read through the returned getter.
    Future<int Function()> holdChips(
      WidgetTester tester,
      CollectionFilter initial, {
      bool ignore = false,
      ValueNotifier<CollectionFilter>? filter,
    }) async {
      var emptied = 0;
      final held = filter ?? ValueNotifier(initial);
      addTearDown(held.dispose);
      await tester.pumpWidget(
        gameFiltersApp(
          Scaffold(
            body: Column(
              children: [
                TextButton(onPressed: () {}, child: const Text('Elsewhere')),
                ValueListenableBuilder<CollectionFilter>(
                  valueListenable: held,
                  builder: (context, value, _) => GameFiltersInUse(
                    filter: value,
                    options: everyOption,
                    onChanged: (next) {
                      if (!ignore) held.value = next;
                    },
                    onEmptied: () => emptied++,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return () => emptied;
    }

    Finder chip(String id) => find.byKey(GameFilterKeys.inUse(id));

    /// The chip's own focus node.
    FocusNode chipFocus(WidgetTester tester, String id) => Focus.of(
      tester.element(
        find.descendant(of: chip(id), matching: find.byType(Text)).first,
      ),
    );

    /// The focus node of the chip's remove button.
    FocusNode removeFocus(WidgetTester tester, String id) => Focus.of(
      tester.element(
        find.descendant(of: chip(id), matching: find.byType(Icon)).last,
      ),
    );

    /// The semantics node a screen reader activates to remove a chip: the
    /// remove button's, named by its tooltip and carrying the tap.
    FinderBase<SemanticsNode> removeAction(String tooltip) =>
        find.semantics.byPredicate(
          (node) =>
              node.tooltip == tooltip &&
              node.getSemanticsData().hasAction(SemanticsAction.tap),
          describeMatch: (_) => 'the remove button "$tooltip"',
        );

    /// Leaves input focus on no control, as a screen reader's user's is.
    Future<void> focusNothing(WidgetTester tester) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(focused == null || focused is FocusScopeNode, isTrue);
    }

    Future<void> focusAndPress(WidgetTester tester, FocusNode node) async {
      node.requestFocus();
      await tester.pump();
      expect(node.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    testWidgets('a focused chip removed hands focus to the chip that took '
        'its place', (tester) async {
      await holdChips(tester, three);

      await focusAndPress(tester, chipFocus(tester, 'platform_tabletop'));

      expect(chip('platform_tabletop'), findsNothing);
      expect(chipFocus(tester, 'platform_console').hasPrimaryFocus, isTrue);
    });

    testWidgets('the last chip in order, removed, hands focus to the one '
        'before it', (tester) async {
      await holdChips(tester, three);

      await focusAndPress(tester, chipFocus(tester, 'platform_pc'));

      expect(chip('platform_pc'), findsNothing);
      expect(chipFocus(tester, 'platform_console').hasPrimaryFocus, isTrue);
    });

    testWidgets('removed from its focused remove button, it hands focus on '
        'the same way', (tester) async {
      await holdChips(tester, three);

      await focusAndPress(tester, removeFocus(tester, 'platform_console'));

      expect(chip('platform_console'), findsNothing);
      expect(chipFocus(tester, 'platform_pc').hasPrimaryFocus, isTrue);
    });

    testWidgets('a flipped chip hands focus on the same way', (tester) async {
      await holdChips(
        tester,
        three.copyWith(excluded: {CollectionFacet.platformType}),
      );
      expect(find.text('Not Tabletop'), findsOneWidget);

      await focusAndPress(tester, chipFocus(tester, 'platform_tabletop'));

      expect(chip('platform_tabletop'), findsNothing);
      expect(chipFocus(tester, 'platform_console').hasPrimaryFocus, isTrue);
    });

    testWidgets('a chip removed by a pointer while another chip holds focus '
        'moves no focus', (tester) async {
      // Four chips: Tabletop, Console, PC, Physical. PC, third, holds focus;
      // Tabletop, first, is removed. A hand-off armed by the focused chip's
      // place would land on Physical, now third; one armed by the removed
      // chip's place would land on Console, now first.
      await holdChips(
        tester,
        three.copyWith(mediums: {GameMedium.physical}),
      );
      final pc = chipFocus(tester, 'platform_pc')..requestFocus();
      await tester.pump();

      await tester.tap(find.byTooltip('Remove Tabletop'));
      await tester.pumpAndSettle();

      expect(chip('platform_tabletop'), findsNothing);
      expect(pc.hasPrimaryFocus, isTrue);
    });

    testWidgets('a chip removed by a pointer before the focused middle chip '
        'moves no focus', (tester) async {
      // Tabletop, Console, PC, with Console focused and Tabletop removed. A
      // hand-off armed by the focused chip's place would land on PC.
      await holdChips(tester, three);
      final console = chipFocus(tester, 'platform_console')..requestFocus();
      await tester.pump();

      await tester.tap(find.byTooltip('Remove Tabletop'));
      await tester.pumpAndSettle();

      expect(chip('platform_tabletop'), findsNothing);
      expect(console.hasPrimaryFocus, isTrue);
    });

    testWidgets('the only chip, removed while focused, calls onEmptied '
        'once', (tester) async {
      final emptied = await holdChips(
        tester,
        const CollectionFilter(mediums: {GameMedium.physical}),
      );

      await focusAndPress(tester, chipFocus(tester, 'medium_physical'));
      await tester.pump();

      expect(chip('medium_physical'), findsNothing);
      expect(emptied(), 1);
    });

    testWidgets('the only chip, removed by a pointer while another control '
        'holds focus, does not call onEmptied', (tester) async {
      final emptied = await holdChips(
        tester,
        const CollectionFilter(mediums: {GameMedium.physical}),
      );
      final elsewhere = Focus.of(tester.element(find.text('Elsewhere')))
        ..requestFocus();
      await tester.pump();

      await tester.tap(find.byTooltip('Remove Physical'));
      await tester.pumpAndSettle();

      expect(chip('medium_physical'), findsNothing);
      expect(emptied(), 0);
      expect(elsewhere.hasPrimaryFocus, isTrue);
    });

    testWidgets('the only chip, removed by a pointer with focus on nothing, '
        'calls onEmptied once', (tester) async {
      final emptied = await holdChips(
        tester,
        const CollectionFilter(mediums: {GameMedium.physical}),
      );
      await focusNothing(tester);

      await tester.tap(find.byTooltip('Remove Physical'));
      await tester.pumpAndSettle();

      expect(chip('medium_physical'), findsNothing);
      expect(emptied(), 1);
    });

    testWidgets('a chip removed by a pointer with focus on nothing hands '
        'focus to the chip that took its place', (tester) async {
      await holdChips(tester, three);
      await focusNothing(tester);

      await tester.tap(find.byTooltip('Remove Tabletop'));
      await tester.pumpAndSettle();

      expect(chip('platform_tabletop'), findsNothing);
      expect(chipFocus(tester, 'platform_console').hasPrimaryFocus, isTrue);
    });

    testWidgets("a screen reader's activation of a chip's remove button "
        'hands focus to the chip that took its place', (tester) async {
      // A TalkBack or VoiceOver double-tap is a semantics tap, which moves
      // no input focus.
      final handle = tester.ensureSemantics();
      await holdChips(tester, three);
      await focusNothing(tester);

      tester.semantics.tap(removeAction('Remove Console'));
      await tester.pumpAndSettle();

      expect(chip('platform_console'), findsNothing);
      expect(chipFocus(tester, 'platform_pc').hasPrimaryFocus, isTrue);
      handle.dispose();
    });

    testWidgets("a screen reader's activation of the only chip's remove "
        'button calls onEmptied once', (tester) async {
      final handle = tester.ensureSemantics();
      final emptied = await holdChips(
        tester,
        const CollectionFilter(mediums: {GameMedium.physical}),
      );
      await focusNothing(tester);

      tester.semantics.tap(removeAction('Remove Physical'));
      await tester.pumpAndSettle();

      expect(chip('medium_physical'), findsNothing);
      expect(emptied(), 1);
      handle.dispose();
    });

    testWidgets('a removal the caller ignores moves nothing, then or at a '
        'later change', (tester) async {
      final held = ValueNotifier<CollectionFilter>(three);
      await holdChips(tester, three, ignore: true, filter: held);
      final tabletop = chipFocus(tester, 'platform_tabletop');

      await focusAndPress(tester, tabletop);
      expect(chip('platform_tabletop'), findsOneWidget);
      expect(tabletop.hasPrimaryFocus, isTrue);

      // A change from elsewhere, not the one the chip sent, which drops the
      // hand-off. It takes Tabletop away, so focus is left free.
      held.value = three.copyWith(
        game: const GameSearchFilter(platformTypes: {PlatformType.pc}),
      );
      await tester.pumpAndSettle();
      expect(chip('platform_tabletop'), findsNothing);

      // Then the filter the chip sent arrives. A hand-off still armed would
      // put focus on Console, in Tabletop's place.
      held.value = three.copyWith(
        game: const GameSearchFilter(
          platformTypes: {PlatformType.console, PlatformType.pc},
        ),
      );
      await tester.pumpAndSettle();

      expect(chip('platform_console'), findsOneWidget);
      expect(chipFocus(tester, 'platform_console').hasFocus, isFalse);
      expect(chipFocus(tester, 'platform_pc').hasFocus, isFalse);
    });
  });

  group('the count', () {
    const filter = CollectionFilter(
      game: GameSearchFilter(
        contentTypes: {ContentType.baseGame, ContentType.expansion},
        playerCount: GameSearchRange(min: 2),
      ),
      mediums: {GameMedium.digital},
      missingBaseGame: true,
      excluded: {CollectionFacet.medium},
    );

    for (final (name, options) in [
      ('every option', everyOption),
      ('the default options', const GameFilterOptions()),
      (
        'options that hide a content type and the medium',
        const GameFilterOptions(
          contentTypes: [ContentType.baseGame],
          missingBaseGame: true,
        ),
      ),
    ]) {
      testWidgets('equals the chips under $name', (tester) async {
        await _showChips(tester, filter, options: options);

        expect(
          find.byType(InputChip),
          findsNWidgets(gameFiltersInUseCount(filter, options: options)),
        );
      });
    }

    test('counts only what the options offer', () {
      expect(gameFiltersInUseCount(filter, options: everyOption), 5);
      // Two content types and the players; the game search offers no medium
      // and no missing-base switch.
      expect(gameFiltersInUseCount(filter), 3);
      expect(
        gameFiltersInUseCount(
          filter,
          options: const GameFilterOptions(
            contentTypes: [ContentType.baseGame],
            missingBaseGame: true,
          ),
        ),
        3,
      );
    });
  });
}
