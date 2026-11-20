import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/list_items.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

const _notSyncedCopy = 'Not yet synced';
const _couldNotSyncCopy = "Couldn't sync";

/// The collection list says which entries the server hasn't had (#47): "Not
/// yet synced" while a change waits, "Couldn't sync" once its queued op is
/// stuck. A row says it in a badge under its details, a cover in a mark and
/// its label, and a stack says the worst of its copies.
void main() {
  late _MockGameCollectionRepository repository;

  setUp(() => repository = _MockGameCollectionRepository());

  /// Shows [rows] as the list, or as covers with [thumbnails], under a sync
  /// scope that names [stuck] as stuck. With [scoped] false there is no
  /// scope above the screen, as in a host that reads no queue.
  ///
  /// With [stuckIds] the scope names its value instead, and follows it while
  /// the screen stays: the screen is the same child each time, so only the
  /// widgets that read the scope rebuild, as under the app's host.
  Future<void> show(
    WidgetTester tester,
    List<GameCollectionListItem> rows, {
    Set<String> stuck = const {},
    ValueListenable<Set<String>>? stuckIds,
    bool scoped = true,
    bool thumbnails = false,
    TextScaler? textScaler,
  }) async {
    when(
      repository.watchCollectionListItems,
    ).thenAnswer((_) => Stream.value(rows));
    Widget scope(Set<String> stuck, Widget child) => BgeSyncStatusScope(
      stuck: stuck.length,
      stuckRecordIds: stuck,
      child: child,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: const [
          ...GameCollectionLocalizations.localizationsDelegates,
          GameFiltersLocalizations.delegate,
        ],
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        builder: (context, child) {
          var host = child!;
          if (stuckIds != null) {
            host = ValueListenableBuilder<Set<String>>(
              valueListenable: stuckIds,
              builder: (context, stuck, child) => scope(stuck, child!),
              child: host,
            );
          } else if (scoped) {
            host = scope(stuck, host);
          }
          if (textScaler != null) {
            host = MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: host,
            );
          }
          return host;
        },
        home: GameCollectionListScreen(
          repository: repository,
          layouts: thumbnails ? _Thumbnails() : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder within(Key key, Finder matching) =>
      find.descendant(of: find.byKey(key), matching: matching);

  /// The merged node of the row [row] finds: the `MergeSemantics` sits inside
  /// the row's outline (#647), below the key. A cover has none, so its own
  /// node answers.
  SemanticsNode mergedNode(WidgetTester tester, Finder row) {
    final merged = find.descendant(
      of: row,
      matching: find.byType(MergeSemantics),
    );
    return tester.getSemantics(merged.evaluate().isEmpty ? row : merged.first);
  }

  /// [key]'s merged semantics label: a row's, with its badge's words, or a
  /// cover's.
  String labelOf(WidgetTester tester, Key key) =>
      mergedNode(tester, find.byKey(key)).label;

  /// One copy of Wingspan, which a second copy makes a stack.
  GameCollectionListItem wingspan(
    String id,
    String platformName, {
    bool isDirty = false,
    bool isLocalOnly = false,
    bool? favorite,
  }) => listItem(
    id,
    gameId: 'g-wingspan',
    title: 'Wingspan',
    platformName: platformName,
    isDirty: isDirty,
    isLocalOnly: isLocalOnly,
    favorite: favorite,
  );

  group('a row', () {
    testWidgets("a local-only entry's row says Not yet synced", (
      tester,
    ) async {
      await show(tester, [listItem('e-1', isLocalOnly: true)]);

      expect(
        within(
          GameCollectionListScreen.rowKey('e-1'),
          find.text(_notSyncedCopy),
        ),
        findsOneWidget,
      );
      expect(find.byType(BgeSyncBadge), findsOneWidget);
    });

    testWidgets("a dirty entry's row says Not yet synced", (tester) async {
      await show(tester, [listItem('e-1', isDirty: true)]);

      expect(
        within(
          GameCollectionListScreen.rowKey('e-1'),
          find.text(_notSyncedCopy),
        ),
        findsOneWidget,
      );
    });

    testWidgets("a synced entry's row shows no badge", (tester) async {
      await show(tester, [listItem('e-1')]);

      expect(
        find.byKey(GameCollectionListScreen.rowKey('e-1')),
        findsOneWidget,
      );
      expect(find.byType(BgeSyncBadge), findsNothing);
      expect(find.text(_notSyncedCopy), findsNothing);
    });

    testWidgets("a stuck entry's row says Couldn't sync", (tester) async {
      // A stuck op never sends on its own, so "not yet synced" would promise
      // what will not happen.
      await show(
        tester,
        [
          listItem('e-1', title: 'Azul', isLocalOnly: true),
          listItem('e-2', title: 'Brass', isLocalOnly: true),
        ],
        stuck: {'e-1'},
      );

      expect(
        within(
          GameCollectionListScreen.rowKey('e-1'),
          find.text(_couldNotSyncCopy),
        ),
        findsOneWidget,
      );
      expect(
        within(
          GameCollectionListScreen.rowKey('e-1'),
          find.text(_notSyncedCopy),
        ),
        findsNothing,
      );
      expect(
        within(
          GameCollectionListScreen.rowKey('e-2'),
          find.text(_notSyncedCopy),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the badge is read with the row', (tester) async {
      await show(tester, [listItem('e-1', isDirty: true, favorite: true)]);

      final row = mergedNode(
        tester,
        find.byKey(GameCollectionListScreen.rowKey('e-1')),
      );
      expect(row.label, contains('Catan'));
      expect(row.label, contains(_notSyncedCopy));
      // Drawn text with no node of its own: its nearest node is the row's.
      expect(tester.getSemantics(find.text(_notSyncedCopy)).id, row.id);
    });

    testWidgets('a stack shows the worst state of its copies', (tester) async {
      await show(
        tester,
        [
          wingspan('e-1', 'Tabletop', isDirty: true),
          wingspan('e-2', 'Steam', isLocalOnly: true),
        ],
        stuck: {'e-2'},
      );

      final stack = GameCollectionListScreen.stackKey('g-wingspan');
      expect(within(stack, find.text(_couldNotSyncCopy)), findsOneWidget);
      expect(within(stack, find.text(_notSyncedCopy)), findsNothing);
      expect(within(stack, find.byType(BgeSyncBadge)), findsOneWidget);
      expect(
        mergedNode(tester, find.byKey(stack)).label,
        contains(_couldNotSyncCopy),
      );
    });

    testWidgets('a stack with one copy waiting says Not yet synced', (
      tester,
    ) async {
      await show(tester, [
        wingspan('e-1', 'Tabletop'),
        wingspan('e-2', 'Steam', isDirty: true),
      ]);

      final stack = GameCollectionListScreen.stackKey('g-wingspan');
      expect(within(stack, find.text(_notSyncedCopy)), findsOneWidget);
    });

    testWidgets('a stack whose copies have all synced shows no badge', (
      tester,
    ) async {
      await show(tester, [
        wingspan('e-1', 'Tabletop'),
        wingspan('e-2', 'Steam'),
      ]);

      expect(
        find.byKey(GameCollectionListScreen.stackKey('g-wingspan')),
        findsOneWidget,
      );
      expect(find.byType(BgeSyncBadge), findsNothing);
    });

    testWidgets("a nested expansion's row carries its own badge", (
      tester,
    ) async {
      GameCollectionListItem expansion(String id, String platformName) =>
          listItem(
            id,
            gameId: 'g-exp',
            title: 'European Expansion',
            platformName: platformName,
            contentType: ContentType.expansion,
            baseGames: const [
              ExpansionLink(gameId: 'g-base', isStandalone: false),
            ],
            isLocalOnly: true,
          );
      await show(
        tester,
        [
          listItem(
            'base-1',
            gameId: 'g-base',
            title: 'Wingspan',
            isDirty: true,
          ),
          expansion('exp-1', 'Tabletop'),
          listItem(
            'other-1',
            gameId: 'g-other',
            title: 'Oceania Expansion',
            contentType: ContentType.expansion,
            baseGames: const [
              ExpansionLink(gameId: 'g-base', isStandalone: false),
            ],
          ),
        ],
        stuck: {'exp-1'},
      );

      final base = GameCollectionListScreen.rowKey('base-1');
      final nested = GameCollectionListScreen.nestedRowKey('g-base', 'exp-1');
      final synced = GameCollectionListScreen.nestedRowKey('g-base', 'other-1');
      expect(within(base, find.text(_notSyncedCopy)), findsOneWidget);
      expect(within(base, find.text(_couldNotSyncCopy)), findsNothing);
      expect(within(nested, find.text(_couldNotSyncCopy)), findsOneWidget);
      expect(
        mergedNode(tester, find.byKey(nested)).label,
        contains(_couldNotSyncCopy),
      );
      expect(find.byKey(synced), findsOneWidget);
      expect(within(synced, find.byType(BgeSyncBadge)), findsNothing);
    });

    testWidgets("a nested stack carries its copies' worst state", (
      tester,
    ) async {
      GameCollectionListItem copy(String id, String platformName) => listItem(
        id,
        gameId: 'g-exp',
        title: 'European Expansion',
        platformName: platformName,
        contentType: ContentType.expansion,
        baseGames: const [ExpansionLink(gameId: 'g-base', isStandalone: false)],
        isDirty: true,
      );
      await show(
        tester,
        [
          listItem('base-1', gameId: 'g-base', title: 'Wingspan'),
          copy('exp-1', 'Tabletop'),
          copy('exp-2', 'Steam'),
        ],
        stuck: {'exp-1'},
      );

      final stack = GameCollectionListScreen.nestedStackKey('g-base', 'g-exp');
      final base = GameCollectionListScreen.rowKey('base-1');
      expect(within(stack, find.text(_couldNotSyncCopy)), findsOneWidget);
      expect(find.byKey(base), findsOneWidget);
      expect(within(base, find.byType(BgeSyncBadge)), findsNothing);
    });

    testWidgets('with no scope, rows still show Not yet synced from their '
        'flags', (tester) async {
      // Stuck can't be known without the queue; waiting can, from the
      // entry's own flags.
      await show(
        tester,
        [listItem('e-1', isLocalOnly: true), listItem('e-2', title: 'Azul')],
        scoped: false,
      );

      final synced = GameCollectionListScreen.rowKey('e-2');
      expect(
        within(
          GameCollectionListScreen.rowKey('e-1'),
          find.text(_notSyncedCopy),
        ),
        findsOneWidget,
      );
      expect(find.byKey(synced), findsOneWidget);
      expect(within(synced, find.byType(BgeSyncBadge)), findsNothing);
    });

    for (final width in <double>[320, 360]) {
      testWidgets('a row and a stack with their badges lay out at 200% text '
          'on a ${width.toInt()}dp window', (tester) async {
        // Tall, so that both rows are built: at 200% text on a phone's
        // width the header and the full row alone outrun a phone's height.
        useViewSize(tester, Size(width, 4000));
        await show(
          tester,
          [
            listItem(
              'e-1',
              title: 'Twilight Imperium',
              subtitle: 'Fourth Edition',
              quantity: 2,
              rating: 9,
              favorite: true,
              lastPlayed: DateTime(2026, 10, 3),
              isLocalOnly: true,
            ),
            wingspan('w-1', 'Tabletop', isDirty: true),
            wingspan('w-2', 'Steam', isLocalOnly: true),
          ],
          stuck: {'w-2'},
          textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
        );

        expect(tester.takeException(), isNull);
        expect(find.text(_notSyncedCopy), findsOneWidget);
        expect(find.text(_couldNotSyncCopy), findsOneWidget);
        // Wrapped inside its row, not drawn past it: a badge that doesn't
        // overflow its own row can still spill out of the row's bounds.
        for (final key in [
          GameCollectionListScreen.rowKey('e-1'),
          GameCollectionListScreen.stackKey('g-wingspan'),
        ]) {
          final row = tester.getRect(find.byKey(key));
          final badge = tester.getRect(within(key, find.byType(BgeSyncBadge)));
          expect(badge.left, greaterThanOrEqualTo(row.left), reason: '$key');
          expect(badge.top, greaterThanOrEqualTo(row.top), reason: '$key');
          expect(badge.right, lessThanOrEqualTo(row.right), reason: '$key');
          expect(badge.bottom, lessThanOrEqualTo(row.bottom), reason: '$key');
        }
      });
    }
  });

  group('as the queue changes', () {
    // The two views, with the keys of an entry's item and of a stack's.
    final views = <(String, bool, Key Function(String), Key)>[
      (
        'the list',
        false,
        GameCollectionListScreen.rowKey,
        GameCollectionListScreen.stackKey('g-wingspan'),
      ),
      (
        'thumbnails',
        true,
        GameCollectionListScreen.tileKey,
        GameCollectionListScreen.stackTileKey('g-wingspan'),
      ),
    ];

    for (final (view, thumbnails, entryKey, stack) in views) {
      testWidgets("an entry and a stack say Couldn't sync while an id they "
          'show is stuck, and Not yet synced once it clears, in $view', (
        tester,
      ) async {
        // Only the scope changes; the screen above the rows does not
        // rebuild, so each item has to rebuild for its own ids.
        final stuckIds = ValueNotifier<Set<String>>(const {});
        addTearDown(stuckIds.dispose);
        await show(
          tester,
          [
            listItem('e-1', title: 'Azul', isLocalOnly: true),
            wingspan('w-1', 'Tabletop', isDirty: true),
            wingspan('w-2', 'Steam', isDirty: true),
          ],
          stuckIds: stuckIds,
          thumbnails: thumbnails,
        );
        final entry = entryKey('e-1');

        /// The item under [key] draws [state], as the badge or the mark, and
        /// its label says it and not the other state.
        void says(Key key, BgeSyncState state) {
          final (words, not) = switch (state) {
            BgeSyncState.waiting => (_notSyncedCopy, _couldNotSyncCopy),
            BgeSyncState.stuck => (_couldNotSyncCopy, _notSyncedCopy),
          };
          expect(find.byKey(key), findsOneWidget);
          final drawn = within(
            key,
            find.byType(thumbnails ? BgeSyncMark : BgeSyncBadge),
          );
          expect(drawn, findsOneWidget, reason: '$key');
          expect(
            thumbnails
                ? tester.widget<BgeSyncMark>(drawn).state
                : tester.widget<BgeSyncBadge>(drawn).state,
            state,
            reason: '$key',
          );
          final label = labelOf(tester, key);
          expect(label, contains(words), reason: '$key');
          expect(label, isNot(contains(not)), reason: '$key');
        }

        says(entry, BgeSyncState.waiting);
        says(stack, BgeSyncState.waiting);

        stuckIds.value = {'e-1'};
        await tester.pump();
        says(entry, BgeSyncState.stuck);
        says(stack, BgeSyncState.waiting);

        // The stack's second copy, so a stack that read only its first
        // wouldn't hear it.
        stuckIds.value = {'e-1', 'w-2'};
        await tester.pump();
        says(entry, BgeSyncState.stuck);
        says(stack, BgeSyncState.stuck);

        stuckIds.value = const {};
        await tester.pump();
        says(entry, BgeSyncState.waiting);
        says(stack, BgeSyncState.waiting);
      });
    }
  });

  group('a cover', () {
    testWidgets("a tile's mark and label follow its state", (tester) async {
      await show(
        tester,
        [
          listItem('e-1', title: 'Azul', isLocalOnly: true, favorite: true),
          listItem('e-2', title: 'Brass', isDirty: true),
          listItem('e-3'),
        ],
        stuck: {'e-2'},
        thumbnails: true,
      );

      String tileLabel(String id) =>
          labelOf(tester, GameCollectionListScreen.tileKey(id));
      BgeSyncState? markOf(String id) {
        final mark = within(
          GameCollectionListScreen.tileKey(id),
          find.byType(BgeSyncMark),
        );
        return mark.evaluate().isEmpty
            ? null
            : tester.widget<BgeSyncMark>(mark).state;
      }

      expect(
        within(
          GameCollectionListScreen.tileKey('e-1'),
          find.byKey(BgeCoverTile.syncMarkKey),
        ),
        findsOneWidget,
      );
      expect(markOf('e-1'), BgeSyncState.waiting);
      // Before the favourite, where the row reads its badge.
      expect(tileLabel('e-1'), endsWith(', $_notSyncedCopy, Favorite'));

      expect(markOf('e-2'), BgeSyncState.stuck);
      expect(tileLabel('e-2'), endsWith(', $_couldNotSyncCopy'));
      expect(tileLabel('e-2'), isNot(contains(_notSyncedCopy)));

      final synced = GameCollectionListScreen.tileKey('e-3');
      expect(find.byKey(synced), findsOneWidget);
      expect(
        within(synced, find.byKey(BgeCoverTile.syncMarkKey)),
        findsNothing,
      );
      expect(tileLabel('e-3'), isNot(contains(_notSyncedCopy)));
      expect(tileLabel('e-3'), isNot(contains(_couldNotSyncCopy)));
    });

    // A cover is named as its row is read, so the state comes in the same
    // place in both: after the details, before the favourite.
    for (final (view, thumbnails, key) in [
      ('a row', false, GameCollectionListScreen.rowKey('e-1')),
      ('a cover', true, GameCollectionListScreen.tileKey('e-1')),
    ]) {
      testWidgets('$view reads the state after the details and before the '
          'favourite', (tester) async {
        await show(
          tester,
          [listItem('e-1', isDirty: true, favorite: true)],
          thumbnails: thumbnails,
        );

        final label = labelOf(tester, key);
        final state = label.indexOf(_notSyncedCopy);
        expect(label, contains('Physical'));
        expect(label, contains('Favorite'));
        expect(state, greaterThan(label.indexOf('Physical')));
        expect(state, lessThan(label.indexOf('Favorite')));
      });
    }

    testWidgets("a stack's cover says the worst state of its copies, once", (
      tester,
    ) async {
      await show(
        tester,
        [
          wingspan('e-1', 'Tabletop', isDirty: true, favorite: true),
          wingspan('e-2', 'Steam', isLocalOnly: true),
        ],
        stuck: {'e-2'},
        thumbnails: true,
      );

      final stack = GameCollectionListScreen.stackTileKey('g-wingspan');
      expect(
        within(stack, find.byKey(BgeCoverTile.syncMarkKey)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<BgeSyncMark>(within(stack, find.byType(BgeSyncMark)))
            .state,
        BgeSyncState.stuck,
      );
      final label = labelOf(tester, stack);
      expect(label, endsWith(', $_couldNotSyncCopy, Favorite'));
      expect(_couldNotSyncCopy.allMatches(label), hasLength(1));
      expect(label, isNot(contains(_notSyncedCopy)));
    });

    testWidgets('with no scope, a cover still says Not yet synced from its '
        'flags', (tester) async {
      await show(
        tester,
        [listItem('e-1', isDirty: true)],
        scoped: false,
        thumbnails: true,
      );

      expect(
        labelOf(tester, GameCollectionListScreen.tileKey('e-1')),
        endsWith(', $_notSyncedCopy'),
      );
    });
  });
}

/// A user who keeps the thumbnails.
class _Thumbnails implements ListLayoutRepository {
  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async =>
      ListLayout.thumbnails;

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async {}
}
