import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';

import '../support/game_filters_app.dart';

// #715: the sheet's medium section, its missing-base switch and its
// leave-out switches, each offered only where the options ask for it. The
// game search opens it with none of them; its own suite covers that sheet.

const _nothingChosen = 'Choose something above first';

/// The leave-out switch under [facet]'s section.
Finder _flip(CollectionFacet facet) =>
    find.byKey(GameFilterKeys.exclude(facet));

/// Whether the switch [finder] finds can be turned.
bool _enabled(WidgetTester tester, Finder finder) =>
    tester.widget<SwitchListTile>(finder).onChanged != null;

void main() {
  testWidgets('the default options show no medium, missing-base or leave-out '
      'controls', (tester) async {
    await openFilterSheet(tester);

    for (final medium in GameMedium.values) {
      expect(find.byKey(GameFilterKeys.medium(medium)), findsNothing);
    }
    expect(find.text('Medium'), findsNothing);
    expect(find.byKey(GameFilterKeys.missingBaseGame), findsNothing);
    for (final facet in CollectionFacet.values) {
      expect(_flip(facet), findsNothing);
    }
    // Only the three ranges' switches that keep games with no value.
    expect(find.byType(SwitchListTile), findsNWidgets(3));
  });

  testWidgets('a medium chip sends the medium', (tester) async {
    final sent = await openFilterSheet(
      tester,
      options: const GameFilterOptions(medium: true),
    );

    expect(find.text('Medium'), findsOneWidget);
    expect(find.text('Physical'), findsOneWidget);
    await tapInSheet(
      tester,
      find.byKey(GameFilterKeys.medium(GameMedium.digital)),
    );

    expect(sent.last, const CollectionFilter(mediums: {GameMedium.digital}));
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(GameFilterKeys.medium(GameMedium.digital)),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets('the medium section comes after Platform', (tester) async {
    await openFilterSheet(
      tester,
      options: const GameFilterOptions(medium: true),
    );

    final platform = tester.getRect(find.text('Platform'));
    final medium = tester.getRect(find.text('Medium'));
    final year = tester.getRect(find.text('Publish year'));
    expect(medium.top, greaterThan(platform.bottom));
    expect(year.top, greaterThan(medium.bottom));
  });

  testWidgets('the leave-out switch is disabled until its section narrows', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final sent = await openFilterSheet(tester, options: everyOption);
    final flip = _flip(CollectionFacet.platformType);

    // Disabled, not hidden, and it says why, shown and spoken.
    expect(_enabled(tester, flip), isFalse);
    expect(
      find.descendant(of: flip, matching: find.text(_nothingChosen)),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(flip),
      isSemantics(
        label: 'Platform, leave these out instead\n$_nothingChosen',
        hasToggledState: true,
        isToggled: false,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    await tapInSheet(
      tester,
      find.byKey(GameFilterKeys.platformType(PlatformType.tabletop)),
    );
    expect(_enabled(tester, flip), isTrue);
    expect(
      find.descendant(of: flip, matching: find.text(_nothingChosen)),
      findsNothing,
    );
    expect(
      tester.getSemantics(flip),
      isSemantics(
        label: 'Platform, leave these out instead',
        hasToggledState: true,
        isToggled: false,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );

    await tapInSheet(tester, flip);
    expect(
      sent.last,
      const CollectionFilter(
        game: GameSearchFilter(platformTypes: {PlatformType.tabletop}),
        excluded: {CollectionFacet.platformType},
      ),
    );
    expect(tester.getSemantics(flip), isSemantics(isToggled: true));
    handle.dispose();
  });

  testWidgets('every section that can narrow has its own leave-out switch, '
      'under its controls', (tester) async {
    await openFilterSheet(tester, options: everyOption);

    for (final facet in CollectionFacet.values) {
      expect(_flip(facet), findsOneWidget, reason: '$facet');
      expect(_enabled(tester, _flip(facet)), isFalse, reason: '$facet');
    }
    double top(Finder finder) => tester.getRect(finder).top;
    expect(
      top(_flip(CollectionFacet.platformType)),
      greaterThan(
        top(find.byKey(GameFilterKeys.platformType(PlatformType.other))),
      ),
    );
    expect(
      top(_flip(CollectionFacet.playerCount)),
      greaterThan(
        top(
          find.byKey(
            GameFilterKeys.includeUnknown(CollectionFacet.playerCount),
          ),
        ),
      ),
    );
    expect(
      top(_flip(CollectionFacet.missingBaseGame)),
      greaterThan(top(find.byKey(GameFilterKeys.missingBaseGame))),
    );
  });

  group('the missing-base switch', () {
    testWidgets('is last, and sends the filter', (tester) async {
      final sent = await openFilterSheet(
        tester,
        options: const GameFilterOptions(missingBaseGame: true),
      );
      final missingBase = find.byKey(GameFilterKeys.missingBaseGame);

      expect(
        find.descendant(
          of: missingBase,
          matching: find.text('Only expansions missing their base game'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(missingBase).top,
        greaterThan(
          tester
              .getRect(
                find.byKey(
                  GameFilterKeys.includeUnknown(CollectionFacet.playTime),
                ),
              )
              .top,
        ),
      );

      await tapInSheet(tester, missingBase);
      expect(sent.last, const CollectionFilter(missingBaseGame: true));
    });

    testWidgets('can be flipped once it is on, and its flip goes when it is '
        'turned off', (tester) async {
      final sent = await openFilterSheet(tester, options: everyOption);
      final missingBase = find.byKey(GameFilterKeys.missingBaseGame);
      final flip = _flip(CollectionFacet.missingBaseGame);

      expect(_enabled(tester, flip), isFalse);
      await tapInSheet(tester, missingBase);
      expect(_enabled(tester, flip), isTrue);

      await tapInSheet(tester, flip);
      expect(
        sent.last,
        const CollectionFilter(
          missingBaseGame: true,
          excluded: {CollectionFacet.missingBaseGame},
        ),
      );

      await tapInSheet(tester, missingBase);
      expect(sent.last, const CollectionFilter());
      expect(_enabled(tester, flip), isFalse);
      expect(tester.widget<SwitchListTile>(flip).value, isFalse);
    });
  });

  group('a flip never outlives its choices', () {
    testWidgets('it stays while a choice is left, and goes with the last', (
      tester,
    ) async {
      final sent = await openFilterSheet(
        tester,
        options: everyOption,
        initial: const CollectionFilter(
          game: GameSearchFilter(
            platformTypes: {PlatformType.tabletop, PlatformType.pc},
          ),
          excluded: {CollectionFacet.platformType},
        ),
      );

      await tapInSheet(
        tester,
        find.byKey(GameFilterKeys.platformType(PlatformType.tabletop)),
      );
      expect(
        sent.last,
        const CollectionFilter(
          game: GameSearchFilter(platformTypes: {PlatformType.pc}),
          excluded: {CollectionFacet.platformType},
        ),
      );

      await tapInSheet(
        tester,
        find.byKey(GameFilterKeys.platformType(PlatformType.pc)),
      );
      expect(sent.last, const CollectionFilter());
      expect(sent, hasLength(2));
    });

    testWidgets("a range's flip goes as the range is cleared", (tester) async {
      final sent = await openFilterSheet(
        tester,
        options: everyOption,
        initial: CollectionFilter(
          game: GameSearchFilter(playTime: GameLengthBand.medium.range),
          excluded: const {CollectionFacet.playTime},
        ),
      );

      // The chosen band, tapped again, clears the play time.
      await tapInSheet(
        tester,
        find.byKey(GameFilterKeys.band(GameLengthBand.medium)),
      );

      expect(sent.last, const CollectionFilter());
    });

    testWidgets('a reversed range keeps its flip, though it narrows nothing', (
      tester,
    ) async {
      final sent = await openFilterSheet(
        tester,
        options: everyOption,
        initial: const CollectionFilter(
          game: GameSearchFilter(playerCount: GameSearchRange(min: 4, max: 2)),
          excluded: {CollectionFacet.playerCount},
        ),
      );
      final flip = _flip(CollectionFacet.playerCount);

      expect(_enabled(tester, flip), isFalse);
      expect(tester.widget<SwitchListTile>(flip).value, isTrue);

      await tapInSheet(
        tester,
        find.byKey(GameFilterKeys.contentType(ContentType.baseGame)),
      );
      expect(sent.last.excluded, {CollectionFacet.playerCount});
    });
  });

  group("a flipped range's no-value switch", () {
    // Each range, its no-value switch's two titles, and a filter with a
    // bound in it.
    const ranges = [
      (
        CollectionFacet.publishYear,
        include: 'Include games with no year',
        leaveOut: 'Leave out games with no year too',
        filter: GameSearchFilter(publishYear: GameSearchRange(min: 2000)),
      ),
      (
        CollectionFacet.playerCount,
        include: 'Include games with no player count',
        leaveOut: 'Leave out games with no player count too',
        filter: GameSearchFilter(playerCount: GameSearchRange(min: 2)),
      ),
      (
        CollectionFacet.playTime,
        include: 'Include games with no play time',
        leaveOut: 'Leave out games with no play time too',
        filter: GameSearchFilter(playTime: GameSearchRange(max: 30)),
      ),
    ];

    for (final (facet, :include, :leaveOut, :filter) in ranges) {
      testWidgets('says it leaves out under a flipped $facet, and includes '
          'once the flip is off', (tester) async {
        final handle = tester.ensureSemantics();
        final sent = await openFilterSheet(
          tester,
          options: everyOption,
          initial: CollectionFilter(game: filter, excluded: {facet}),
        );
        final unknown = find.byKey(GameFilterKeys.includeUnknown(facet));

        expect(
          find.descendant(of: unknown, matching: find.text(leaveOut)),
          findsOneWidget,
        );
        expect(find.text(include), findsNothing);
        expect(tester.getSemantics(unknown), isSemantics(label: leaveOut));

        // The switch keeps its value through the flip: only its title
        // changes.
        await tapInSheet(tester, unknown);
        expect(sent.last.excluded, {facet});
        expect(tester.widget<SwitchListTile>(unknown).value, isTrue);
        expect(
          find.descendant(of: unknown, matching: find.text(leaveOut)),
          findsOneWidget,
        );

        await tapInSheet(tester, _flip(facet));
        expect(sent.last.excluded, isEmpty);
        expect(tester.widget<SwitchListTile>(unknown).value, isTrue);
        expect(
          find.descendant(of: unknown, matching: find.text(include)),
          findsOneWidget,
        );
        expect(find.text(leaveOut), findsNothing);
        expect(tester.getSemantics(unknown), isSemantics(label: include));
        handle.dispose();
      });
    }

    testWidgets('the default options never show the leave-out wording', (
      tester,
    ) async {
      await openFilterSheet(
        tester,
        initial: const CollectionFilter(
          game: GameSearchFilter(
            publishYear: GameSearchRange(min: 2000),
            playerCount: GameSearchRange(min: 2),
            playTime: GameSearchRange(max: 30),
          ),
        ),
      );

      for (final (_, :include, :leaveOut, filter: _) in ranges) {
        expect(find.text(include), findsOneWidget);
        expect(find.text(leaveOut), findsNothing);
      }
    });
  });

  group('Clear all', () {
    testWidgets('clears the flips', (tester) async {
      final sent = await openFilterSheet(
        tester,
        options: everyOption,
        initial: const CollectionFilter(
          query: 'cat',
          game: GameSearchFilter(
            platformTypes: {PlatformType.tabletop},
            playerCount: GameSearchRange(min: 2, max: 4),
          ),
          mediums: {GameMedium.physical},
          missingBaseGame: true,
          excluded: {
            CollectionFacet.platformType,
            CollectionFacet.playerCount,
            CollectionFacet.medium,
            CollectionFacet.missingBaseGame,
          },
        ),
      );

      await tapInSheet(tester, find.byKey(GameFilterKeys.clearAll));

      expect(sent.last, const CollectionFilter(query: 'cat'));
      for (final facet in CollectionFacet.values) {
        expect(tester.widget<SwitchListTile>(_flip(facet)).value, isFalse);
      }
    });

    testWidgets('clears only what the options offer, with the flips that go '
        'with it', (tester) async {
      final sent = await openFilterSheet(
        tester,
        options: const GameFilterOptions(
          contentTypes: [ContentType.baseGame],
          exclusion: true,
        ),
        initial: const CollectionFilter(
          query: 'cat',
          game: GameSearchFilter(
            contentTypes: {ContentType.baseGame, ContentType.expansion},
            platformTypes: {PlatformType.pc},
          ),
          mediums: {GameMedium.digital},
          missingBaseGame: true,
          excluded: {
            CollectionFacet.contentType,
            CollectionFacet.platformType,
            CollectionFacet.medium,
          },
        ),
      );

      await tapInSheet(tester, find.byKey(GameFilterKeys.clearAll));

      // The expansion and the medium aren't offered, so they stay, and so do
      // their flips.
      expect(
        sent.last,
        const CollectionFilter(
          query: 'cat',
          game: GameSearchFilter(contentTypes: {ContentType.expansion}),
          mediums: {GameMedium.digital},
          missingBaseGame: true,
          excluded: {CollectionFacet.contentType, CollectionFacet.medium},
        ),
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(GameFilterKeys.clearAll))
            .onPressed,
        isNull,
      );
    });

    testWidgets('is disabled while only what the options leave out is chosen', (
      tester,
    ) async {
      await openFilterSheet(
        tester,
        initial: const CollectionFilter(
          query: 'cat',
          mediums: {GameMedium.digital},
          missingBaseGame: true,
        ),
      );

      expect(
        tester
            .widget<TextButton>(find.byKey(GameFilterKeys.clearAll))
            .onPressed,
        isNull,
      );
    });
  });

  // A range field filled without focus, as an assistive tool's set-text
  // fills it, commits from its dispose as the sheet closes, when nothing may
  // be marked to build.
  testWidgets('a bound a field still holds as the sheet closes reaches a '
      'caller that rebuilds on every change', (tester) async {
    await tester.pumpWidget(gameFiltersApp(const _RebuildingOpener()));
    await tester.tap(find.byKey(openSheetKey));
    await tester.pumpAndSettle();
    final from = find.byKey(
      GameFilterKeys.rangeField(CollectionFacet.playerCount, from: true),
    );
    await tester.ensureVisible(from);
    await tester.pumpAndSettle();
    tester.widget<TextField>(from).controller!.text = '4';
    await tester.pump();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('from 4'), findsOneWidget);
  });

  testWidgets('at 320x640 and text scale 2.0, the sheet with every option on '
      'has no overflow, and each switch row is at least 48dp tall', (
    tester,
  ) async {
    useNarrowWindowAndLargeText(tester);
    await openFilterSheet(
      tester,
      options: everyOption,
      initial: const CollectionFilter(
        game: GameSearchFilter(platformTypes: {PlatformType.tabletop}),
        mediums: {GameMedium.physical},
        excluded: {CollectionFacet.platformType},
      ),
    );

    expect(tester.takeException(), isNull);
    final switches = find.byType(SwitchListTile);
    // Three keep-unknown switches, the missing-base switch, and a leave-out
    // switch per facet.
    expect(switches, findsNWidgets(4 + CollectionFacet.values.length));
    for (final row in switches.evaluate()) {
      expect(
        tester.getSize(find.byWidget(row.widget)).height,
        greaterThanOrEqualTo(48),
        reason: '${row.widget.key}',
      );
    }
  });
}

/// A page that opens the sheet and draws the filter it last sent, calling
/// `setState` straight from the sheet's `onChanged`, as a caller holding the
/// filter in its own state does.
class _RebuildingOpener extends StatefulWidget {
  const _RebuildingOpener();

  @override
  State<_RebuildingOpener> createState() => _RebuildingOpenerState();
}

class _RebuildingOpenerState extends State<_RebuildingOpener> {
  CollectionFilter _filter = const CollectionFilter();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          key: openSheetKey,
          onPressed: () => showGameFilterSheet(
            context,
            initial: _filter,
            onChanged: (filter) => setState(() => _filter = filter),
          ),
          child: const Text('Open'),
        ),
        Text('from ${_filter.game.playerCount.min}'),
      ],
    ),
  );
}
