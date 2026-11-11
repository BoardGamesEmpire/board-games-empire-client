import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A collection cache the test feeds: [items] adds a list, as the
/// repository's watch emits one, and [fail] and [end] stop it.
class _Collection implements GameCollectionRepository {
  final _items = StreamController<List<GameCollectionListItem>>();
  int watches = 0;

  void items(List<GameCollectionListItem> items) => _items.add(items);

  void fail() => _items.addError(StateError('the collection failed'));

  Future<void> end() => _items.close();

  @override
  Stream<List<GameCollectionListItem>> watchCollectionListItems() {
    watches++;
    return _items.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final _at = DateTime.utc(2026);

/// A collection entry [id], titled [title], on [platform] of [type].
GameCollectionListItem _item(
  String id,
  String title, {
  String platform = 'Tabletop',
  PlatformType type = PlatformType.tabletop,
  GameMedium medium = GameMedium.physical,
  bool localOnly = false,
  String? gameId,
  String? subtitle,
  int? publishYear,
  ContentType contentType = ContentType.baseGame,
  List<ExpansionLink> baseGames = const [],
}) => GameCollectionListItem(
  entry: GameCollection(
    id: id,
    userId: 'u1',
    platformGameId: 'pg-$id',
    medium: medium,
    createdAt: _at,
    updatedAt: _at,
    isLocalOnly: localOnly,
  ),
  gameId: gameId ?? 'g-$id',
  title: title,
  subtitle: subtitle,
  platformName: platform,
  platformType: type,
  contentType: contentType,
  publishYear: publishYear,
  baseGames: baseGames,
);

const _longTitle =
    'Twilight Imperium: Fourth Edition, Prophecy of Kings and the Codex '
    'Volumes';

// In title order, as the repository gives them.
final GameCollectionListItem _ark = _item(
  'c-ark',
  'Ark Nova',
  platform: 'Steam',
  type: PlatformType.pc,
  medium: GameMedium.digital,
);
final GameCollectionListItem _azul = _item('c-azul', 'Azul');
final GameCollectionListItem _catan = _item('c-catan', 'Catan');
final GameCollectionListItem _root = _item(
  'c-root',
  'Root',
  platform: 'Board Game Arena',
  type: PlatformType.pc,
  medium: GameMedium.digital,
);
final GameCollectionListItem _wingspan = _item(
  'c-wing',
  'Wingspan',
  localOnly: true,
);

/// Catan is offered already, and Wingspan isn't on the server.
final List<GameCollectionListItem> _five = [
  _ark,
  _azul,
  _catan,
  _root,
  _wingspan,
];
const _args = OfferGamesArgs(offeredCollectionIds: {'c-catan'});

/// The Offer games page (#516): the collection's rows, flat and in title
/// order, the search and the shared filters, picks that last through both,
/// Select all shown, its states, and the footer's button, which pops the
/// picks for the event's screen to send.
void main() {
  late _Collection collection;
  late bool popped;
  late List<OfferPick>? popResult;

  setUp(() {
    collection = _Collection();
    popped = false;
    popResult = null;
  });

  /// The page, pushed above a page of its own as the shell pushes it, so
  /// that what it pops with can be read.
  Widget harness({OfferGamesArgs args = _args, ThemeData? theme}) =>
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        localizationsDelegates: const [
          ...EventsLocalizations.localizationsDelegates,
          GameFiltersLocalizations.delegate,
        ],
        supportedLocales: EventsLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            Future<void> open() async {
              popResult = await Navigator.of(context).push<List<OfferPick>>(
                MaterialPageRoute(
                  builder: (_) =>
                      OfferGamesScreen(collection: collection, args: args),
                ),
              );
              popped = true;
            }

            return Scaffold(
              body: TextButton(
                onPressed: () => unawaited(open()),
                child: const Text('open'),
              ),
            );
          },
        ),
      );

  /// Opens the page; with [items], the collection answers with them, and
  /// without, the page waits.
  Future<void> reach(
    WidgetTester tester, {
    List<GameCollectionListItem>? items,
  }) async {
    if (items != null) collection.items(items);
    await tester.tap(find.text('open'));
    if (items != null) {
      await tester.pumpAndSettle();
    } else {
      // Fixed pumps: the spinner never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(OfferGamesScreen), findsOneWidget);
  }

  Future<void> open(
    WidgetTester tester, {
    List<GameCollectionListItem>? items,
    OfferGamesArgs args = _args,
  }) async {
    await tester.pumpWidget(harness(args: args));
    await reach(tester, items: items ?? _five);
  }

  Finder row(String id) =>
      find.byKey(OfferGamesScreen.rowKey(id), skipOffstage: false);
  CheckboxListTile tile(WidgetTester tester, String id) =>
      tester.widget<CheckboxListTile>(
        find.descendant(
          of: row(id),
          matching: find.byType(CheckboxListTile, skipOffstage: false),
          skipOffstage: false,
        ),
      );
  Finder send() => find.byKey(OfferGamesScreen.sendKey);
  FilledButton sendButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.descendant(of: send(), matching: find.byType(FilledButton)),
  );
  Finder selectAll() => find.byKey(OfferGamesScreen.selectAllKey);
  Finder search() => find.byKey(OfferGamesScreen.searchKey);
  Finder count() => find.byKey(OfferGamesScreen.countKey);

  /// The rows shown, by entry id, in order down the page.
  List<String> rowsShown(WidgetTester tester) {
    final ids = [
      for (final item in [..._five, _item('c-tw', _longTitle)])
        if (row(item.entry.id).evaluate().isNotEmpty) item.entry.id,
    ];
    return ids..sort(
      (a, b) =>
          tester.getTopLeft(row(a)).dy.compareTo(tester.getTopLeft(row(b)).dy),
    );
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String id) async {
    await reveal(tester, row(id));
    await tester.tap(row(id));
    await tester.pumpAndSettle();
  }

  Future<void> tapSend(WidgetTester tester) async {
    await tester.tap(send(), warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  Future<void> openFilters(WidgetTester tester) async {
    await reveal(tester, find.byKey(GameFilterKeys.button));
    await tester.tap(find.byKey(GameFilterKeys.button));
    await tester.pumpAndSettle();
  }

  Future<void> tapInSheet(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Closes the filter sheet by tapping the barrier above it.
  Future<void> closeFilters(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  Future<void> filterBy(WidgetTester tester, PlatformType type) async {
    await openFilters(tester);
    await tapInSheet(tester, find.byKey(GameFilterKeys.platformType(type)));
    await closeFilters(tester);
  }

  String countText(WidgetTester tester) => tester
      .widget<Text>(find.descendant(of: count(), matching: find.byType(Text)))
      .data!;

  FocusNode searchFocus(WidgetTester tester) =>
      tester.widget<TextField>(search()).focusNode!;

  testWidgets('the rows are the collection, flat, in title order', (
    tester,
  ) async {
    // Two copies of one game and an expansion with its base game owned:
    // each is a row of its own, in the order the collection gives.
    final azulDigital = _item(
      'c-azul-2',
      'Azul',
      gameId: 'g-c-azul',
      platform: 'Board Game Arena',
      type: PlatformType.pc,
      medium: GameMedium.digital,
    );
    final expansion = _item(
      'c-azul-x',
      'Azul: Crystal Mosaic',
      contentType: ContentType.expansion,
      baseGames: const [ExpansionLink(gameId: 'g-c-azul', isStandalone: false)],
    );
    await open(
      tester,
      items: [_ark, _azul, azulDigital, expansion, _catan, _root, _wingspan],
    );

    final ids = [
      'c-ark',
      'c-azul',
      'c-azul-2',
      'c-azul-x',
      'c-catan',
      'c-root',
      'c-wing',
    ];
    var above = double.negativeInfinity;
    for (final id in ids) {
      expect(row(id), findsOneWidget, reason: id);
      final top = tester.getTopLeft(row(id)).dy;
      expect(top, greaterThan(above), reason: id);
      above = top;
      // Every row starts at the same edge: nothing sits under another.
      expect(
        tester.getTopLeft(row(id)).dx,
        tester.getTopLeft(row('c-ark')).dx,
        reason: id,
      );
    }
    expect(
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount,
      ids.length,
    );
    expect(find.text('Offer games'), findsWidgets);
    expect(collection.watches, 1);
  });

  testWidgets('an offered entry is checked, disabled and says so; an unsynced '
      'one is disabled and says so', (tester) async {
    await open(tester);

    expect(tile(tester, 'c-catan').value, isTrue);
    expect(tile(tester, 'c-catan').onChanged, isNull);
    expect(
      find.descendant(
        of: row('c-catan'),
        matching: find.text('Already offered'),
      ),
      findsOneWidget,
    );
    await reveal(tester, row('c-wing'));
    expect(tile(tester, 'c-wing').value, isFalse);
    expect(tile(tester, 'c-wing').onChanged, isNull);
    expect(
      find.descendant(of: row('c-wing'), matching: find.text('Not synced yet')),
      findsOneWidget,
    );
    expect(tile(tester, 'c-azul').onChanged, isNotNull);

    // A tap on either changes nothing and picks nothing.
    await pick(tester, 'c-catan');
    await pick(tester, 'c-wing');
    expect(tile(tester, 'c-catan').value, isTrue);
    expect(tile(tester, 'c-wing').value, isFalse);
    expect(sendButton(tester).onPressed, isNull);
  });

  testWidgets("Tab passes over a row that can't be picked, as over any "
      'disabled control, and Space picks the row it lands on', (tester) async {
    await open(tester);
    FocusNode rowFocus(String title) => Focus.of(
      tester.element(
        find.descendant(of: row(title), matching: find.byType(Text)).first,
      ),
    );
    await reveal(tester, row('c-azul'));
    rowFocus('c-azul').requestFocus();
    await tester.pump();

    // Catan, offered already, is between them.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(rowFocus('c-root').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(tile(tester, 'c-root').value, isTrue);
  });

  testWidgets('picking two enables Offer 2 games, and it pops with them in '
      'list order', (tester) async {
    await open(tester);
    expect(sendButton(tester).onPressed, isNull);
    expect(
      find.descendant(of: send(), matching: find.text('Offer games')),
      findsOneWidget,
    );

    // Root first, then Azul: the order ticked isn't the order sent.
    await pick(tester, 'c-root');
    expect(
      find.descendant(of: send(), matching: find.text('Offer 1 game')),
      findsOneWidget,
    );
    await pick(tester, 'c-azul');
    expect(
      find.descendant(of: send(), matching: find.text('Offer 2 games')),
      findsOneWidget,
    );
    expect(sendButton(tester).onPressed, isNotNull);

    await tapSend(tester);

    expect(popped, isTrue);
    expect(popResult, const [
      OfferPick(collectionId: 'c-azul', title: 'Azul'),
      OfferPick(collectionId: 'c-root', title: 'Root'),
    ]);
    expect(find.byType(OfferGamesScreen), findsNothing);
  });

  // Two rows of one title are told apart by the subtitle, which the search
  // matches too.
  testWidgets('a row names its game with its subtitle, as Collection does, '
      'and the pick carries that name', (tester) async {
    await open(
      tester,
      items: [
        _item('c-catan', 'Catan'),
        _item('c-sea', 'Catan', subtitle: 'Seafarers'),
      ],
      args: const OfferGamesArgs(),
    );

    expect(
      find.descendant(of: row('c-catan'), matching: find.text('Catan')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row('c-sea'),
        matching: find.text('Catan: Seafarers'),
      ),
      findsOneWidget,
    );

    await tester.enterText(search(), 'seafarers');
    await tester.pumpAndSettle();
    expect(row('c-catan'), findsNothing);
    await pick(tester, 'c-sea');
    await tapSend(tester);

    expect(popResult, const [
      OfferPick(collectionId: 'c-sea', title: 'Catan: Seafarers'),
    ]);
  });

  testWidgets('a platform filter then Select all shown picks only what is '
      'shown, and never an offered or unsynced entry', (tester) async {
    await open(tester);
    await filterBy(tester, PlatformType.tabletop);
    expect(rowsShown(tester), ['c-azul', 'c-catan', 'c-wing']);

    await reveal(tester, selectAll());
    await tester.tap(selectAll());
    await tester.pumpAndSettle();

    expect(tile(tester, 'c-azul').value, isTrue);
    expect(tile(tester, 'c-catan').value, isTrue);
    expect(tile(tester, 'c-wing').value, isFalse);
    expect(
      find.descendant(of: send(), matching: find.text('Offer 1 game')),
      findsOneWidget,
    );

    await tapSend(tester);
    expect(popResult, const [OfferPick(collectionId: 'c-azul', title: 'Azul')]);
  });

  testWidgets('Select all shown adds to what is already picked', (
    tester,
  ) async {
    await open(tester);
    await pick(tester, 'c-ark');
    await filterBy(tester, PlatformType.tabletop);

    await reveal(tester, selectAll());
    await tester.tap(selectAll());
    await tester.pumpAndSettle();

    await tapSend(tester);
    expect(popResult, const [
      OfferPick(collectionId: 'c-ark', title: 'Ark Nova'),
      OfferPick(collectionId: 'c-azul', title: 'Azul'),
    ]);
  });

  testWidgets('a pick survives a filter that hides it, and the button still '
      'counts it', (tester) async {
    await open(tester);
    await pick(tester, 'c-root');

    await tester.enterText(search(), 'azul');
    await tester.pumpAndSettle();
    expect(rowsShown(tester), ['c-azul']);
    expect(
      find.descendant(of: send(), matching: find.text('Offer 1 game')),
      findsOneWidget,
    );

    await pick(tester, 'c-azul');
    expect(
      find.descendant(of: send(), matching: find.text('Offer 2 games')),
      findsOneWidget,
    );

    await tapSend(tester);
    expect(popResult, const [
      OfferPick(collectionId: 'c-azul', title: 'Azul'),
      OfferPick(collectionId: 'c-root', title: 'Root'),
    ]);
  });

  testWidgets('Select all shown becomes Clear selection', (tester) async {
    await open(tester);
    await pick(tester, 'c-azul');
    await filterBy(tester, PlatformType.pc);
    expect(rowsShown(tester), ['c-ark', 'c-root']);

    // By keyboard, so its focus is watched as its label swaps.
    await reveal(tester, selectAll());
    final node = Focus.of(
      tester.element(
        find.descendant(of: selectAll(), matching: find.byType(Text)),
      ),
    )..requestFocus();
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: selectAll(), matching: find.text('Clear selection')),
      findsOneWidget,
    );
    expect(node.hasPrimaryFocus, isTrue);
    expect(
      find.descendant(of: send(), matching: find.text('Offer 3 games')),
      findsOneWidget,
    );

    // A row left unpicked turns it back.
    await pick(tester, 'c-root');
    expect(
      find.descendant(of: selectAll(), matching: find.text('Select all shown')),
      findsOneWidget,
    );
    await pick(tester, 'c-root');

    // Clear selection clears every pick, Azul's too, which the filter hides.
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: selectAll(), matching: find.text('Select all shown')),
      findsOneWidget,
    );
    expect(node.hasPrimaryFocus, isTrue);
    expect(sendButton(tester).onPressed, isNull);
    final chip = find.byKey(GameFilterKeys.inUse('platform_pc'));
    await reveal(tester, chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(tile(tester, 'c-azul').value, isFalse);
    // The offered entry stays checked: it was never a pick.
    expect(tile(tester, 'c-catan').value, isTrue);
  });

  testWidgets('Select all shown is disabled, saying why, when nothing shown '
      'can be picked', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    await tester.enterText(search(), 'catan');
    await tester.pumpAndSettle();

    expect(tester.widget<ButtonStyleButton>(selectAll()).onPressed, isNull);
    expect(
      tester.getSemantics(selectAll()),
      isSemantics(
        label: 'Select all shown',
        hint: 'None of the games shown can be offered.',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('a flipped filter leaves its games out of the rows', (
    tester,
  ) async {
    await open(tester);
    await openFilters(tester);
    await tapInSheet(
      tester,
      find.byKey(GameFilterKeys.platformType(PlatformType.tabletop)),
    );
    await tapInSheet(
      tester,
      find.byKey(GameFilterKeys.exclude(CollectionFacet.platformType)),
    );
    await closeFilters(tester);

    expect(rowsShown(tester), ['c-ark', 'c-root']);
    expect(
      find.descendant(
        of: find.byKey(GameFilterKeys.inUse('platform_tabletop')),
        matching: find.text('Not Tabletop'),
      ),
      findsOneWidget,
    );
    expect(find.text('Filters (1)'), findsOneWidget);
  });

  // A range field commits what it holds as the sheet closes, from its
  // dispose when it doesn't hold focus, while the tree is locked.
  for (final focused in [true, false]) {
    testWidgets('a bound typed in the sheet narrows the rows once the sheet '
        'closes unsubmitted, the field '
        '${focused ? 'focused' : 'filled with no focus'}', (tester) async {
      await open(
        tester,
        items: [
          _item('c-azul', 'Azul', publishYear: 2017),
          _item('c-brass', 'Brass', publishYear: 2007),
          _item('c-catan', 'Catan', publishYear: 1995),
        ],
        args: const OfferGamesArgs(),
      );
      await openFilters(tester);
      final from = find.byKey(
        GameFilterKeys.rangeField(CollectionFacet.publishYear, from: true),
      );
      await tester.ensureVisible(from);
      await tester.pumpAndSettle();
      if (focused) {
        await tester.enterText(from, '2000');
      } else {
        // As an assistive tool's set-text does, with no focus on it.
        tester.widget<TextField>(from).controller!.text = '2000';
      }
      await tester.pump();

      await closeFilters(tester);

      expect(tester.takeException(), isNull);
      expect(row('c-azul'), findsOneWidget);
      expect(row('c-brass'), findsOneWidget);
      expect(row('c-catan'), findsNothing);
      expect(countText(tester), '2 games shown');
      expect(find.text('Filters (1)'), findsOneWidget);
    });
  }

  testWidgets('the sheet offers the medium and the flips, and no missing '
      'base game', (tester) async {
    await open(tester);
    await openFilters(tester);

    expect(
      find.byKey(GameFilterKeys.medium(GameMedium.digital)),
      findsOneWidget,
    );
    expect(
      find.byKey(GameFilterKeys.exclude(CollectionFacet.platformType)),
      findsOneWidget,
    );
    expect(find.byKey(GameFilterKeys.missingBaseGame), findsNothing);
  });

  testWidgets('the last chip removed hands focus to Filters', (tester) async {
    await open(tester);
    await filterBy(tester, PlatformType.pc);
    final chip = find.byKey(GameFilterKeys.inUse('platform_pc'));
    await reveal(tester, chip);
    Focus.of(
      tester.element(
        find.descendant(of: chip, matching: find.byType(Text)).first,
      ),
    ).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(chip, findsNothing);
    expect(
      tester
          .widget<ButtonStyleButton>(find.byKey(GameFilterKeys.button))
          .focusNode!
          .hasPrimaryFocus,
      isTrue,
    );
  });

  testWidgets('leaving without sending pops with null', (tester) async {
    await open(tester);
    await pick(tester, 'c-azul');

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(popped, isTrue);
    expect(popResult, isNull);
  });

  testWidgets('the count is always shown, in a live region, and counts the '
      'rows shown', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    expect(countText(tester), '5 games shown');
    expect(
      tester.getSemantics(count()),
      isSemantics(label: '5 games shown', isLiveRegion: true),
    );

    await tester.enterText(search(), 'azul');
    await tester.pumpAndSettle();
    expect(countText(tester), '1 game shown');
    // Under the controls.
    expect(
      tester.getTopLeft(count()).dy,
      greaterThan(tester.getBottomLeft(find.byKey(GameFilterKeys.button)).dy),
    );
    handle.dispose();
  });

  testWidgets('a pick survives a list update that reorders the rows', (
    tester,
  ) async {
    await open(tester);
    await pick(tester, 'c-root');

    // Root's title is changed elsewhere, which moves it to the top.
    final renamed = _item(
      'c-root',
      'Aardvark',
      platform: 'Board Game Arena',
      type: PlatformType.pc,
      medium: GameMedium.digital,
    );
    collection.items([renamed, _ark, _azul, _catan, _wingspan]);
    await tester.pumpAndSettle();

    expect(rowsShown(tester).first, 'c-root');
    expect(tile(tester, 'c-root').value, isTrue);
    expect(
      find.descendant(of: send(), matching: find.text('Offer 1 game')),
      findsOneWidget,
    );
    await tapSend(tester);
    expect(popResult, const [
      OfferPick(collectionId: 'c-root', title: 'Aardvark'),
    ]);
  });

  testWidgets('a picked entry that leaves the collection leaves the picks', (
    tester,
  ) async {
    await open(tester);
    await pick(tester, 'c-azul');
    await pick(tester, 'c-root');

    // Root is removed elsewhere while the page is open.
    collection.items([_ark, _azul, _catan, _wingspan]);
    await tester.pumpAndSettle();

    expect(row('c-root'), findsNothing);
    expect(
      find.descendant(of: send(), matching: find.text('Offer 1 game')),
      findsOneWidget,
    );
    await tapSend(tester);
    expect(popResult, const [OfferPick(collectionId: 'c-azul', title: 'Azul')]);
  });

  group('states', () {
    testWidgets('loading until the collection first answers', (tester) async {
      await tester.pumpWidget(harness());
      await reach(tester);

      expect(find.byType(BgeLoadingState), findsOneWidget);
      expect(search(), findsNothing);
      expect(sendButton(tester).onPressed, isNull);

      collection.items(_five);
      await tester.pumpAndSettle();
      expect(find.byType(BgeLoadingState), findsNothing);
      expect(row('c-azul'), findsOneWidget);
    });

    testWidgets('an empty collection says so, with no action', (tester) async {
      await open(tester, items: const []);

      expect(
        find.descendant(
          of: find.byType(BgeEmptyState),
          matching: find.text('Your collection is empty'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(BgeEmptyState),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
        findsNothing,
      );
      expect(sendButton(tester).onPressed, isNull);
    });

    testWidgets('a search that leaves nothing says No games match, and Clear '
        'filters clears it and the filters, empties the field and hands '
        'focus to Filters, with no keyboard left open', (tester) async {
      await open(tester);
      await filterBy(tester, PlatformType.pc);
      await tester.enterText(search(), 'gloomhaven');
      await tester.pumpAndSettle();

      expect(find.text('No games match'), findsOneWidget);
      expect(countText(tester), '0 games shown');
      final clear = find.byKey(OfferGamesScreen.clearFiltersKey);
      await reveal(tester, clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();

      expect(clear, findsNothing);
      expect(rowsShown(tester), hasLength(5));
      expect(tester.widget<TextField>(search()).controller!.text, isEmpty);
      expect(find.text('Filters'), findsOneWidget);
      expect(searchFocus(tester).hasFocus, isFalse);
      expect(
        Focus.of(tester.element(find.text('Filters'))).hasPrimaryFocus,
        isTrue,
      );
      expect(tester.testTextInput.isVisible, isFalse);
    });

    group('Clear filters hands focus to Filters', () {
      final clear = find.byKey(OfferGamesScreen.clearFiltersKey);
      FocusNode filtersFocus(WidgetTester tester) =>
          Focus.of(tester.element(find.text('Filters (1)')));
      FocusNode filtersFocusAfter(WidgetTester tester) =>
          Focus.of(tester.element(find.text('Filters')));

      /// A medium no game has: nothing matches, with focus moved by none of
      /// it but the sheet's own, given back to Filters as it closes.
      Future<void> noneMatch(WidgetTester tester) async {
        await open(tester, items: [_azul, _catan]);
        await openFilters(tester);
        await tapInSheet(
          tester,
          find.byKey(GameFilterKeys.medium(GameMedium.digital)),
        );
        await closeFilters(tester);
        expect(clear, findsOneWidget);
        await reveal(tester, clear);
      }

      testWidgets('from the keyboard', (tester) async {
        await noneMatch(tester);

        await activateByKeyboard(tester, clear);

        expect(clear, findsNothing);
        expect(filtersFocusAfter(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets("from a screen reader's activation, with focus on nothing", (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await noneMatch(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        tester.semantics.tap(
          find.semantics.byPredicate(
            (node) =>
                node.label == 'Clear filters' &&
                node.getSemanticsData().hasAction(SemanticsAction.tap),
            describeMatch: (_) => 'Clear filters',
          ),
        );
        await tester.pumpAndSettle();

        expect(clear, findsNothing);
        expect(filtersFocusAfter(tester).hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets('a pointer press while focus sits on another control '
          'moves nothing', (tester) async {
        await noneMatch(tester);
        final filters = filtersFocus(tester);
        final back = Focus.of(
          tester.element(
            find.descendant(
              of: find.byType(BackButton),
              matching: find.byType(Icon),
            ),
          ),
        )..requestFocus();
        await tester.pump();
        expect(back.hasPrimaryFocus, isTrue);

        await tester.tap(clear);
        await tester.pumpAndSettle();

        expect(clear, findsNothing);
        expect(back.hasPrimaryFocus, isTrue);
        expect(filters.hasFocus, isFalse);
      });
    });

    for (final (name, stop) in [
      ('fails', (_Collection c) async => c.fail()),
      ('ends', (_Collection c) => c.end()),
    ]) {
      testWidgets('a collection read that $name says so, and its button goes '
          'back with nothing', (tester) async {
        await open(tester);
        await pick(tester, 'c-azul');

        await stop(collection);
        await tester.pumpAndSettle();

        expect(find.byType(BgeErrorState), findsOneWidget);
        expect(find.text("Couldn't read your collection"), findsOneWidget);
        expect(row('c-azul'), findsNothing);
        // Nothing read can be sent.
        expect(sendButton(tester).onPressed, isNull);

        await tester.tap(find.byKey(OfferGamesScreen.backKey));
        await tester.pumpAndSettle();
        expect(popped, isTrue);
        expect(popResult, isNull);
      });
    }
  });

  group('accessibility audit', () {
    // The rows are each one merged node whose label differs from any one
    // drawn text, so the contrast guideline never reads them. The reason a
    // row can't be picked is what the user reads to know why: it is held
    // to AA here, against the surface it is drawn on, from the colours the
    // widgets resolve. The title and platform line of a disabled row keep
    // the disabled look, which WCAG 1.4.3 exempts.
    for (final (name, theme) in [
      ('light', BgeTheme.light()),
      ('dark', BgeTheme.dark()),
    ]) {
      testWidgets("in $name, the reason a row can't be picked is drawn at "
          'AA contrast', (tester) async {
        await tester.pumpWidget(harness(theme: theme));
        await reach(tester, items: _five);

        for (final (id, reason) in [
          ('c-catan', 'Already offered'),
          ('c-wing', 'Not synced yet'),
        ]) {
          await reveal(tester, row(id));
          final text = find.descendant(
            of: row(id),
            matching: find.text(reason),
          );
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: text, matching: find.byType(RichText)),
          );
          final color = paragraph.text.style!.color!;
          // The first opaque surface under it.
          final ground = tester
              .widgetList<Material>(
                find.ancestor(of: text, matching: find.byType(Material)),
              )
              .map((material) => material.color)
              .firstWhere((color) => color != null && color.a > 0)!;
          expect(
            Wcag.contrastRatio(Color.alphaBlend(color, ground), ground),
            greaterThanOrEqualTo(Wcag.aaNormalText),
            reason: '$reason on ${row(id)}',
          );
        }
      });
    }

    testWidgets('each row is one node saying its title, platform, checked '
        'state and, where it applies, why it can not be picked', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      await pick(tester, 'c-root');

      SemanticsNode node(String id) => tester.getSemantics(
        find.descendant(of: row(id), matching: find.byType(CheckboxListTile)),
      );
      expect(
        node('c-root'),
        isSemantics(
          label: 'Root\nBoard Game Arena, Digital',
          hasCheckedState: true,
          isChecked: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(
        node('c-azul'),
        isSemantics(
          label: 'Azul\nTabletop, Physical',
          hasCheckedState: true,
          isChecked: false,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      expect(
        node('c-catan'),
        isSemantics(
          label: 'Catan\nTabletop, Physical\nAlready offered',
          hasCheckedState: true,
          isChecked: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      expect(
        node('c-wing'),
        isSemantics(
          label: 'Wingspan\nTabletop, Physical\nNot synced yet',
          hasCheckedState: true,
          isChecked: false,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('at 320×640 and 200% text, with a long title: no overflow, '
        'the rows wrap, and the footer button is whole', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, items: [..._five, _item('c-tw', _longTitle)]);
      await pick(tester, 'c-azul');
      await pick(tester, 'c-root');

      expect(tester.takeException(), isNull);
      final title = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text(_longTitle, skipOffstage: false),
          matching: find.byType(RichText, skipOffstage: false),
          skipOffstage: false,
        ),
      );
      expect(title.didExceedMaxLines, isFalse);
      // The button's label is drawn whole, inside the window and the button.
      final label = find.descendant(
        of: send(),
        matching: find.text('Offer 2 games'),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: label, matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      final button = tester.getRect(send());
      final text = tester.getRect(label);
      expect(button.left, greaterThanOrEqualTo(0));
      expect(button.right, lessThanOrEqualTo(320));
      expect(text.left, greaterThanOrEqualTo(button.left));
      expect(text.right, lessThanOrEqualTo(button.right));
      expect(button.bottom, lessThanOrEqualTo(640));
      // Each checkbox stays on its row.
      for (final id in ['c-azul', 'c-tw']) {
        await tester.scrollUntilVisible(
          row(id),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await reveal(tester, row(id));
        final box = tester.getRect(
          find.descendant(of: row(id), matching: find.byType(Checkbox)),
        );
        expect(box.right, lessThanOrEqualTo(320), reason: id);
        expect(box.left, greaterThanOrEqualTo(0), reason: id);
      }
    });

    Widget build(ThemeData theme) => harness(theme: theme);

    Future<void> ready(WidgetTester tester) async {
      await reach(tester, items: _five);
      await pick(tester, 'c-azul');
      await scrollPageToTop(tester);
    }

    auditScreen('OfferGamesScreen, with picks', build: build, arrange: ready);

    auditScreen(
      'OfferGamesScreen, with picks, whole page',
      build: build,
      arrange: (tester) async {
        await useWholePage(tester);
        await ready(tester);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'OfferGamesScreen, when no game matches',
      build: build,
      arrange: (tester) async {
        await reach(tester, items: _five);
        await tester.enterText(search(), 'gloomhaven');
        await tester.pumpAndSettle();
        expect(find.text('No games match'), findsOneWidget);
      },
    );

    auditScreen(
      'OfferGamesScreen, with an empty collection',
      build: build,
      arrange: (tester) => reach(tester, items: const []),
    );

    auditScreen(
      'OfferGamesScreen, when the collection fails',
      build: build,
      arrange: (tester) async {
        await reach(tester);
        collection.fail();
        await tester.pumpAndSettle();
        expect(find.byType(BgeErrorState), findsOneWidget);
      },
    );

    auditScreen(
      'OfferGamesScreen, while the collection loads',
      build: build,
      settle: false,
      arrange: reach,
    );
  });
}
