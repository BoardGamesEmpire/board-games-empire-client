import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/list_items.dart';

const _openKey = Key('test.open_picker');

GameCollectionListItem _entry(
  String id, {
  required String platformName,
  GameMedium medium = GameMedium.physical,
}) => listItem(
  id,
  gameId: 'g-wingspan',
  title: 'Wingspan',
  platformName: platformName,
  medium: medium,
);

final GameCollectionListItem _tabletopPhysical = _entry(
  'e-1',
  platformName: 'Tabletop',
);
final GameCollectionListItem _tabletopDigital = _entry(
  'e-2',
  platformName: 'Tabletop',
  medium: GameMedium.digital,
);
final GameCollectionListItem _steam = _entry('e-3', platformName: 'Steam');
final GameCollectionListItem _longPlatform = _entry(
  'e-4',
  platformName: 'Nintendo Switch 2 Edition',
);

Finder _tile(String entryId) =>
    find.byKey(CollectionEntryPicker.tileKey(entryId));

/// Whether [context] is [element] or below it.
bool _isWithin(BuildContext context, Element element) {
  var within = identical(context, element);
  context.visitAncestorElements((ancestor) {
    within = within || identical(ancestor, element);
    return !within;
  });
  return within;
}

/// Whether the tile's own focus ring is drawn: the ring around the whole
/// tile, not the one inside its cover.
bool _ringShows(WidgetTester tester, String entryId) {
  final ring = find
      .descendant(of: _tile(entryId), matching: find.byType(BgeFocusRing))
      .first;
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: ring, matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).border != null;
}

/// A page with a button that opens the picker over `items`, recording what
/// each tile's tap hands to `onOpen`.
class _Host {
  final opener = FocusNode(debugLabel: 'opener');
  final opened = <({BuildContext context, String entryId})>[];

  Future<void> pump(
    WidgetTester tester,
    List<GameCollectionListItem> items, {
    Size size = const Size(400, 800),
    double textScale = 1,
  }) async {
    useViewSize(tester, size);
    addTearDown(opener.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates:
            GameCollectionLocalizations.localizationsDelegates,
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                key: _openKey,
                focusNode: opener,
                onPressed: () => unawaited(
                  showCollectionEntryPicker(
                    context,
                    items: items,
                    onOpen: (context, entryId) =>
                        opened.add((context: context, entryId: entryId)),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(_openKey));
    // The pop-up slides or fades in from nothing, which drops its semantics.
    await tester.pumpAndSettle();
  }
}

void main() {
  // The heading is drawn in the display face. Loaded for the whole file, so
  // every test measures it as a user's screen does (#710).
  setUpAll(loadDisplayFont);

  testWidgets('one tile per entry, two across', (tester) async {
    final host = _Host();
    final items = [_tabletopPhysical, _tabletopDigital, _steam, _longPlatform];
    await host.pump(tester, items);
    await host.open(tester);

    for (final item in items) {
      expect(_tile(item.entry.id), findsOneWidget);
    }
    final rects = [
      for (final item in items) tester.getRect(_tile(item.entry.id)),
    ];
    // In the order given: the first two side by side, the next two below.
    expect(rects[1].top, rects[0].top);
    expect(rects[1].left, greaterThan(rects[0].right));
    expect(rects[2].top, greaterThan(rects[0].bottom));
    expect(rects[2].left, rects[0].left);
    expect(rects[3].top, rects[2].top);
    expect(rects[3].left, rects[1].left);
  });

  testWidgets('a platform with two entries names the medium', (tester) async {
    final host = _Host();
    final items = [_tabletopPhysical, _tabletopDigital, _steam];
    await host.pump(tester, items);
    await host.open(tester);

    final l10n = await GameCollectionLocalizations.delegate.load(
      const Locale('en'),
    );
    expect(collectionEntryLabel(l10n, _tabletopPhysical, items), (
      shown: 'Tabletop · Physical',
      spoken: 'Tabletop Physical',
    ));
    expect(collectionEntryLabel(l10n, _tabletopDigital, items), (
      shown: 'Tabletop · Digital',
      spoken: 'Tabletop Digital',
    ));
    expect(collectionEntryLabel(l10n, _steam, items), (
      shown: 'Steam',
      spoken: 'Steam',
    ));

    // Each label is drawn under its own tile.
    for (final (id, shown) in [
      ('e-1', 'Tabletop · Physical'),
      ('e-2', 'Tabletop · Digital'),
      ('e-3', 'Steam'),
    ]) {
      expect(
        find.descendant(of: _tile(id), matching: find.text(shown)),
        findsOneWidget,
      );
    }
    expect(find.textContaining('Steam ·'), findsNothing);
  });

  testWidgets('tapping a tile opens that entry', (tester) async {
    final host = _Host();
    await host.pump(tester, [_tabletopPhysical, _tabletopDigital, _steam]);
    await host.open(tester);

    await tester.tap(_tile('e-2'));
    await tester.pump();

    expect(host.opened.map((o) => o.entryId), ['e-2']);
    // The tile's own context, in the pop-up, for the caller to push the
    // entry's page from: not the page's, which can go while it is open.
    expect(
      _isWithin(host.opened.single.context, tester.element(_tile('e-2'))),
      isTrue,
    );
  });

  testWidgets('each tile is a button named for its platform', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final host = _Host();
      await host.pump(tester, [_tabletopPhysical, _tabletopDigital, _steam]);
      await host.open(tester);

      for (final (id, spoken) in [
        ('e-1', 'Tabletop Physical'),
        ('e-2', 'Tabletop Digital'),
        ('e-3', 'Steam'),
      ]) {
        final tile = tester.getSemantics(_tile(id));
        expect(
          tile,
          isSemantics(
            label: spoken,
            isButton: true,
            hasTapAction: true,
            isFocusable: true,
          ),
          reason: id,
        );
        // The cover and the drawn label are the same node, or none.
        expect(tile.childrenCount, 0, reason: id);
      }
      // The drawn label isn't read a second time.
      expect(find.bySemanticsLabel('Tabletop · Physical'), findsNothing);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('focus returns to the opener on close', (tester) async {
    final host = _Host();
    await host.pump(tester, [_tabletopPhysical, _steam]);
    host.opener.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(_tile('e-1'), findsOneWidget);
    // The picker takes focus: the focus scope of the pop-up's route has it,
    // which is above the sheet, until a Tab moves it to a tile.
    final tile = tester.element(_tile('e-1'));
    final focus = FocusManager.instance.primaryFocus!;
    expect(focus, same(FocusScope.of(tile)));
    expect(ModalRoute.of(focus.context!), isA<BgePopupSheetRoute<void>>());
    expect(ModalRoute.of(focus.context!), same(ModalRoute.of(tile)));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(_tile('e-1'), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(host.opener));
  });

  for (final (form, size) in [
    ('sheet', const Size(400, 800)),
    ('dialog', const Size(800, 600)),
  ]) {
    testWidgets('in a $form, Tab reaches the first tile, ringed, Enter '
        'opens its entry, and the next Tab is the next tile', (tester) async {
      final host = _Host();
      await host.pump(tester, [_tabletopPhysical, _steam], size: size);
      host.opener.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_ringShows(tester, 'e-1'), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(
        _isWithin(
          FocusManager.instance.primaryFocus!.context!,
          tester.element(_tile('e-1')),
        ),
        isTrue,
      );
      expect(_ringShows(tester, 'e-1'), isTrue);
      expect(_ringShows(tester, 'e-3'), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(host.opened.map((o) => o.entryId), ['e-1']);

      // One stop per tile: the cover inside it is not one.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(
        _isWithin(
          FocusManager.instance.primaryFocus!.context!,
          tester.element(_tile('e-3')),
        ),
        isTrue,
      );
      expect(_ringShows(tester, 'e-3'), isTrue);
      expect(_ringShows(tester, 'e-1'), isFalse);
    });
  }

  testWidgets('a dialog is as wide as its tiles, and four entries fit an '
      '800 by 600 window', (tester) async {
    final host = _Host();
    final items = [_tabletopPhysical, _tabletopDigital, _steam, _longPlatform];
    await host.pump(tester, items, size: const Size(800, 600));
    await host.open(tester);

    final dialog = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    final tiles = [
      for (final item in items) tester.getRect(_tile(item.entry.id)),
    ];
    final padding = BgeTokens.standard.spaceMd;
    expect(dialog.width, lessThan(BgeTokens.standard.contentMaxWidth));
    expect(tiles[0].left, dialog.left + padding);
    expect(tiles[1].right, dialog.right - padding);
    for (final tile in tiles) {
      expect(dialog.expandToInclude(tile), dialog);
    }
  });

  testWidgets('a sheet spans the window, with its tiles centred', (
    tester,
  ) async {
    final host = _Host();
    await host.pump(tester, [_tabletopPhysical, _steam]);
    await host.open(tester);

    final sheet = tester.getRect(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Material),
          )
          .first,
    );
    final first = tester.getRect(_tile('e-1'));
    final second = tester.getRect(_tile('e-3'));
    expect(sheet.width, 400);
    expect(first.left - sheet.left, sheet.right - second.right);
  });

  testWidgets('at 320 dp and 2.0 text a long platform label grows its row '
      'and does not overflow', (tester) async {
    final host = _Host();
    await host.pump(
      tester,
      [_longPlatform, _tabletopPhysical, _tabletopDigital],
      size: const Size(320, 640),
      textScale: 2,
    );
    await host.open(tester);

    expect(tester.takeException(), isNull);

    final long = tester.getRect(_tile('e-4'));
    final beside = tester.getRect(_tile('e-1'));
    final below = tester.getRect(_tile('e-2'));
    final label = find.descendant(
      of: _tile('e-4'),
      matching: find.text('Nintendo Switch 2 Edition'),
    );

    // The label wraps rather than being cut, and its tile holds all of it.
    final paragraph = tester.renderObject<RenderParagraph>(label);
    expect(
      paragraph.size.height,
      greaterThan(paragraph.getMinIntrinsicHeight(double.infinity)),
    );
    expect(long.expandToInclude(tester.getRect(label)), long);
    // The next row starts below it, so the row grew with it.
    expect(below.top, greaterThan(long.bottom));
    // Both columns on screen, and the last row's single tile keeps the width
    // of one column.
    expect(long.left, greaterThanOrEqualTo(0));
    expect(beside.right, lessThanOrEqualTo(320));
    expect(below.width, long.width);
    expect(below.left, long.left);
  });

  group('openCollectionEntries', () {
    Future<List<String>> pumpOpener(
      WidgetTester tester,
      List<GameCollectionListItem> items,
    ) async {
      final opened = <String>[];
      useViewSize(tester, const Size(400, 800));
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              GameCollectionLocalizations.localizationsDelegates,
          supportedLocales: GameCollectionLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  key: _openKey,
                  onPressed: () => unawaited(
                    openCollectionEntries(
                      context,
                      items: items,
                      onOpen: (context, entryId) => opened.add(entryId),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(_openKey));
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('one entry is opened directly, with no picker', (tester) async {
      final opened = await pumpOpener(tester, [_steam]);

      expect(opened, ['e-3']);
      expect(_tile('e-3'), findsNothing);
    });

    testWidgets('several entries open the picker, and open nothing yet', (
      tester,
    ) async {
      final opened = await pumpOpener(tester, [_tabletopPhysical, _steam]);

      expect(_tile('e-1'), findsOneWidget);
      expect(_tile('e-3'), findsOneWidget);
      expect(opened, isEmpty);

      await tester.tap(_tile('e-3'));
      await tester.pumpAndSettle();
      expect(opened, ['e-3']);
    });
  });
}
