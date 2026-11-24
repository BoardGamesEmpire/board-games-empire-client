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

final GameCollectionListItem _switchPhysical = _entry(
  'e-1',
  platformName: 'Switch',
);
final GameCollectionListItem _switchDigital = _entry(
  'e-2',
  platformName: 'Switch',
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
/// each tile's tap hands to `onOpen`. With a `relay`, the page sits under the
/// session's scope as the app holds it: below the root navigator, built from
/// the relay and carrying it, as `SyncStatusScopeHost` does. A pop-up on the
/// root navigator is above it.
class _Host {
  final opener = FocusNode(debugLabel: 'opener');
  final opened = <({BuildContext context, String entryId})>[];

  Future<void> pump(
    WidgetTester tester,
    List<GameCollectionListItem> items, {
    Size size = const Size(400, 800),
    double textScale = 1,
    ThemeData? theme,
    ValueNotifier<BgeSyncStatusData>? relay,
    Stream<List<GameCollection>>? updates,
  }) async {
    useViewSize(tester, size);
    addTearDown(opener.dispose);
    Widget page = Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => TextButton(
            key: _openKey,
            focusNode: opener,
            onPressed: () => unawaited(
              showCollectionEntryPicker(
                context,
                items: items,
                updates: updates,
                onOpen: (context, entryId) =>
                    opened.add((context: context, entryId: entryId)),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    page = BgeSyncStatusRelayScope(relay: relay, child: page);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        localizationsDelegates:
            GameCollectionLocalizations.localizationsDelegates,
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: page,
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
    final items = [_switchPhysical, _switchDigital, _steam, _longPlatform];
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
    final items = [_switchPhysical, _switchDigital, _steam];
    await host.pump(tester, items);
    await host.open(tester);

    final l10n = await GameCollectionLocalizations.delegate.load(
      const Locale('en'),
    );
    expect(collectionEntryLabel(l10n, _switchPhysical, items), (
      shown: 'Switch · Physical',
      spoken: 'Switch Physical',
    ));
    expect(collectionEntryLabel(l10n, _switchDigital, items), (
      shown: 'Switch · Digital',
      spoken: 'Switch Digital',
    ));
    expect(collectionEntryLabel(l10n, _steam, items), (
      shown: 'Steam',
      spoken: 'Steam',
    ));

    // Each label is drawn under its own tile.
    for (final (id, shown) in [
      ('e-1', 'Switch · Physical'),
      ('e-2', 'Switch · Digital'),
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
    await host.pump(tester, [_switchPhysical, _switchDigital, _steam]);
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
      await host.pump(tester, [_switchPhysical, _switchDigital, _steam]);
      await host.open(tester);

      for (final (id, spoken) in [
        ('e-1', 'Switch Physical'),
        ('e-2', 'Switch Digital'),
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
      expect(find.bySemanticsLabel('Switch · Physical'), findsNothing);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('focus returns to the opener on close', (tester) async {
    final host = _Host();
    await host.pump(tester, [_switchPhysical, _steam]);
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
    expect(
      ModalRoute.of(focus.context!),
      isA<BgePopupRoute<void>>().having(
        (route) => route.form,
        'form',
        BgePopupForm.sheet,
      ),
    );
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
      await host.pump(tester, [_switchPhysical, _steam], size: size);
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
    final items = [_switchPhysical, _switchDigital, _steam, _longPlatform];
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
    await host.pump(tester, [_switchPhysical, _steam]);
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

  // The pop-up changes form with the window while it is open, and the
  // picker's width follows the form it is in then (#733).
  testWidgets('resized while open, it is as wide as its tiles in the dialog '
      'and spans the window in the sheet', (tester) async {
    final host = _Host();
    await host.pump(tester, [_switchPhysical, _steam]);
    await host.open(tester);
    Rect surface(Type chrome) => tester.getRect(
      find
          .descendant(of: find.byType(chrome), matching: find.byType(Material))
          .first,
    );
    final padding = BgeTokens.standard.spaceMd;

    tester.view.physicalSize = const Size(800, 600);
    await tester.pump();

    final dialog = surface(Dialog);
    expect(find.byType(BottomSheet), findsNothing);
    expect(dialog.width, lessThan(BgeTokens.standard.contentMaxWidth));
    expect(tester.getRect(_tile('e-1')).left, dialog.left + padding);
    expect(tester.getRect(_tile('e-3')).right, dialog.right - padding);

    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();

    final sheet = surface(BottomSheet);
    expect(find.byType(Dialog), findsNothing);
    expect(sheet.width, 400);
    expect(
      tester.getRect(_tile('e-1')).left - sheet.left,
      sheet.right - tester.getRect(_tile('e-3')).right,
    );
  });

  testWidgets('at 320 dp and 2.0 text a long platform label grows its row '
      'and does not overflow', (tester) async {
    final host = _Host();
    await host.pump(
      tester,
      [_longPlatform, _switchPhysical, _switchDigital],
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

  group('a copy that has not synced', () {
    const notSynced = 'Not yet synced';
    const couldNotSync = "Couldn't sync";

    GameCollectionListItem copy(
      String id,
      String platform, {
      bool isDirty = false,
      bool isLocalOnly = false,
    }) => listItem(
      id,
      gameId: 'g-wingspan',
      title: 'Wingspan',
      platformName: platform,
      isDirty: isDirty,
      isLocalOnly: isLocalOnly,
    );

    /// Sends [entries] down [updates] and lets the picker see them: a
    /// broadcast stream delivers in a microtask, which a pump runs after its
    /// frame, so the frame it asks for takes a second.
    Future<void> emit(
      WidgetTester tester,
      StreamController<List<GameCollection>> updates,
      List<GameCollection> entries,
    ) async {
      updates.add(entries);
      await tester.pump();
      await tester.pump();
    }

    Finder badgeIn(String entryId, String text) =>
        find.descendant(of: _tile(entryId), matching: find.text(text));

    testWidgets("a stuck change says Couldn't sync, and a waiting one says "
        'Not yet synced', (tester) async {
      // The session's scope is below the opener's navigator, so the picker,
      // on the root navigator, hears it only through the relay.
      final relay = ValueNotifier(
        const BgeSyncStatusData(
          waiting: 2,
          stuck: 1,
          stuckRecordIds: {'e-1'},
        ),
      );
      addTearDown(relay.dispose);
      final host = _Host();
      await host.pump(tester, [
        copy('e-1', 'Switch', isDirty: true),
        copy('e-2', 'Steam', isDirty: true),
      ], relay: relay);
      await host.open(tester);

      expect(badgeIn('e-1', couldNotSync), findsOneWidget);
      expect(badgeIn('e-1', notSynced), findsNothing);
      expect(badgeIn('e-2', notSynced), findsOneWidget);
      expect(badgeIn('e-2', couldNotSync), findsNothing);
    });

    testWidgets('a local-only copy says Not synced with no session', (
      tester,
    ) async {
      final host = _Host();
      await host.pump(tester, [
        copy('e-1', 'Switch', isLocalOnly: true),
        copy('e-2', 'Steam'),
      ]);
      await host.open(tester);

      expect(badgeIn('e-1', notSynced), findsOneWidget);
      expect(find.text(notSynced), findsOneWidget);
    });

    testWidgets('a copy the server has shows no badge', (tester) async {
      final relay = ValueNotifier(
        const BgeSyncStatusData(waiting: 0, stuck: 0),
      );
      addTearDown(relay.dispose);
      final host = _Host();
      await host.pump(tester, [
        copy('e-1', 'Switch'),
        copy('e-2', 'Steam'),
      ], relay: relay);
      await host.open(tester);

      expect(find.text(notSynced), findsNothing);
      expect(find.text(couldNotSync), findsNothing);
      expect(find.byType(BgeSyncBadge), findsNothing);
    });

    testWidgets('a badge changes while the picker is open, down to synced', (
      tester,
    ) async {
      final relay = ValueNotifier(const BgeSyncStatusData());
      addTearDown(relay.dispose);
      final updates = StreamController<List<GameCollection>>.broadcast();
      addTearDown(updates.close);
      final host = _Host();
      await host.pump(
        tester,
        [
          copy('e-1', 'Switch', isDirty: true),
          copy('e-2', 'Steam'),
        ],
        relay: relay,
        updates: updates.stream,
      );
      await host.open(tester);
      expect(badgeIn('e-1', notSynced), findsOneWidget);

      relay.value = const BgeSyncStatusData(
        waiting: 1,
        stuck: 1,
        stuckRecordIds: {'e-1'},
      );
      await tester.pump();
      expect(badgeIn('e-1', couldNotSync), findsOneWidget);
      expect(badgeIn('e-1', notSynced), findsNothing);

      // Retried: no longer stuck, and the copy's own flags still say the
      // server hasn't had it.
      relay.value = const BgeSyncStatusData(waiting: 1, stuck: 0);
      await tester.pump();
      expect(badgeIn('e-1', notSynced), findsOneWidget);
      expect(badgeIn('e-1', couldNotSync), findsNothing);

      // The push landed: the entry is clean in the live source, and the
      // queue is clear.
      await emit(tester, updates, [
        copy('e-1', 'Switch').entry,
        copy('e-2', 'Steam').entry,
      ]);
      relay.value = const BgeSyncStatusData(waiting: 0, stuck: 0);
      await tester.pump();
      expect(find.byType(BgeSyncBadge), findsNothing);
      // The tiles are the ones the picker opened with.
      expect(_tile('e-1'), findsOneWidget);
      expect(_tile('e-2'), findsOneWidget);
    });

    testWidgets('a copy the live source goes dirty on says Not yet synced', (
      tester,
    ) async {
      final updates = StreamController<List<GameCollection>>.broadcast();
      addTearDown(updates.close);
      final host = _Host();
      await host.pump(tester, [
        copy('e-1', 'Switch'),
        copy('e-2', 'Steam'),
      ], updates: updates.stream);
      await host.open(tester);
      expect(find.byType(BgeSyncBadge), findsNothing);

      await emit(tester, updates, [copy('e-1', 'Switch', isDirty: true).entry]);

      expect(badgeIn('e-1', notSynced), findsOneWidget);
      // Only the copy the emission names changed: the other, left out of it,
      // keeps the entry it had.
      expect(find.byType(BgeSyncBadge), findsOneWidget);
    });

    testWidgets('a tile missing from an emission keeps its last entry, and '
        'an entry the picker has no tile for adds none', (tester) async {
      final updates = StreamController<List<GameCollection>>.broadcast();
      addTearDown(updates.close);
      final host = _Host();
      await host.pump(tester, [
        copy('e-1', 'Switch', isDirty: true),
        copy('e-2', 'Steam'),
      ], updates: updates.stream);
      await host.open(tester);

      await emit(tester, updates, [copy('e-9', 'Stadia', isDirty: true).entry]);

      expect(badgeIn('e-1', notSynced), findsOneWidget);
      expect(find.byType(BgeSyncBadge), findsOneWidget);
      expect(_tile('e-9'), findsNothing);
    });

    testWidgets('closing the picker cancels its subscription to the live '
        'source', (tester) async {
      final updates = StreamController<List<GameCollection>>.broadcast();
      addTearDown(updates.close);
      final host = _Host();
      await host.pump(tester, [
        copy('e-1', 'Switch'),
        copy('e-2', 'Steam'),
      ], updates: updates.stream);
      expect(updates.hasListener, isFalse);
      await host.open(tester);
      expect(updates.hasListener, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_tile('e-1'), findsNothing);
      expect(updates.hasListener, isFalse);
    });

    testWidgets('a live source that errors leaves the tiles as they were', (
      tester,
    ) async {
      final updates = StreamController<List<GameCollection>>.broadcast();
      addTearDown(updates.close);
      final host = _Host();
      await host.pump(tester, [
        copy('e-1', 'Switch', isDirty: true),
        copy('e-2', 'Steam'),
      ], updates: updates.stream);
      await host.open(tester);

      updates.addError(StateError('session ended'));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(badgeIn('e-1', notSynced), findsOneWidget);
    });

    testWidgets("the badge is read in the copy's merged node", (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final relay = ValueNotifier(
          const BgeSyncStatusData(
            waiting: 1,
            stuck: 1,
            stuckRecordIds: {'e-1'},
          ),
        );
        addTearDown(relay.dispose);
        final host = _Host();
        await host.pump(tester, [
          copy('e-1', 'Switch', isDirty: true),
          copy('e-2', 'Steam'),
        ], relay: relay);
        await host.open(tester);

        final stuck = tester.getSemantics(_tile('e-1'));
        expect(stuck.label, contains('Switch'));
        expect(stuck.label, contains(couldNotSync));
        expect(stuck, isSemantics(isButton: true, hasTapAction: true));
        // One node: the drawn badge is not a second one.
        expect(stuck.childrenCount, 0);
        expect(find.bySemanticsLabel(couldNotSync), findsNothing);
        // A copy the server has is named by its platform alone.
        expect(tester.getSemantics(_tile('e-2')).label, 'Steam');
      } finally {
        handle.dispose();
      }
    });

    for (final (name, theme, floor) in [
      ('light', BgeTheme.light(), Wcag.aaNormalText),
      ('dark', BgeTheme.dark(), Wcag.aaNormalText),
      ('high-contrast light', BgeTheme.highContrastLight(), Wcag.aaaNormalText),
      ('high-contrast dark', BgeTheme.highContrastDark(), Wcag.aaaNormalText),
    ]) {
      // A compact window opens a sheet, on `surfaceContainerLow`, and a wide
      // one a dialog, on `surfaceContainerHigh`.
      for (final (form, size) in [
        ('sheet', const Size(320, 640)),
        ('dialog', const Size(800, 600)),
      ]) {
        testWidgets('meets contrast and tap targets at 2.0 text in a $form, '
            'in $name', (tester) async {
          final handle = tester.ensureSemantics();
          try {
            final relay = ValueNotifier(
              const BgeSyncStatusData(
                waiting: 1,
                stuck: 1,
                stuckRecordIds: {'e-1'},
              ),
            );
            addTearDown(relay.dispose);
            final host = _Host();
            await host.pump(
              tester,
              [
                copy('e-1', 'Switch', isDirty: true),
                copy('e-2', 'Steam', isDirty: true),
              ],
              size: size,
              textScale: 2,
              theme: theme,
              relay: relay,
            );
            await host.open(tester);

            expect(tester.takeException(), isNull);
            expect(
              BgePopupForm.maybeOf(tester.element(_tile('e-1'))),
              form == 'sheet' ? BgePopupForm.sheet : BgePopupForm.dialog,
            );
            // The badge's words are drawn text with no node of their own, so
            // the guideline, which reads nodes whose label is one Text, can't
            // see them: measure the words, and the icon beside them, on the
            // pop-up's ground directly.
            final ground = tester
                .widget<Material>(
                  find
                      .ancestor(
                        of: _tile('e-1'),
                        matching: find.byType(Material),
                      )
                      .first,
                )
                .color!;
            for (final (id, words, status) in [
              ('e-1', couldNotSync, BgeStatus.conflict),
              ('e-2', notSynced, BgeStatus.pending),
            ]) {
              final text = badgeIn(id, words);
              expect(text, findsOneWidget, reason: id);
              expect(
                Wcag.contrastRatio(
                  tester.widget<Text>(text).style!.color!,
                  ground,
                ),
                greaterThanOrEqualTo(floor),
                reason: '$id words',
              );
              // The icon is a mark beside words that say the same: 3:1.
              final icon = find.descendant(
                of: _tile(id),
                matching: find.byIcon(BgeStatusColors.iconFor(status)),
              );
              expect(
                Wcag.contrastRatio(tester.widget<Icon>(icon).color!, ground),
                greaterThanOrEqualTo(Wcag.aaNonText),
                reason: '$id icon',
              );
            }
            await expectLater(tester, meetsGuideline(textContrastGuideline));
            await expectLater(
              tester,
              meetsGuideline(androidTapTargetGuideline),
            );
            await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          } finally {
            handle.dispose();
          }
        });
      }
    }
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
      final opened = await pumpOpener(tester, [_switchPhysical, _steam]);

      expect(_tile('e-1'), findsOneWidget);
      expect(_tile('e-3'), findsOneWidget);
      expect(opened, isEmpty);

      await tester.tap(_tile('e-3'));
      await tester.pumpAndSettle();
      expect(opened, ['e-3']);
    });
  });
}
