import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/list_items.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

class _MockLogger extends Mock implements BgeLogger {}

const _updateOp = UpdateCollectionOperation(collectionId: 'gc_1', quantity: 3);

const _openKey = Key('test.open_sheet');
const _quantityInvalid = 'Enter a whole number, 1 or more.';
const _quantityTooMany = "That's more copies than can be stored.";
const _cantClear = "A comment can't be removed yet. Change it instead.";
const _failedTitle = "Couldn't save your changes";

/// The largest quantity the server's `Int` column holds.
const _storedMax = 2147483647;

void main() {
  late _MockGameCollectionRepository repository;
  late _MockSyncOperationSender sender;
  late StreamController<GameCollectionListItem?> watch;
  late CollectionEntryBloc bloc;

  setUpAll(() {
    registerFallbackValue(_updateOp);
    registerFallbackValue(StackTrace.empty);
  });

  setUp(() {
    repository = _MockGameCollectionRepository();
    sender = _MockSyncOperationSender();
    watch = StreamController<GameCollectionListItem?>();
    addTearDown(watch.close);
    when(() => repository.watchCollectionListItem('gc_1'))
        .thenAnswer((_) => watch.stream);
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncDelivered());
    when(
      () => repository.updateCollectionEntry(
        id: any(named: 'id'),
        quantity: any(named: 'quantity'),
        rating: any(named: 'rating'),
        playAgain: any(named: 'playAgain'),
        favorite: any(named: 'favorite'),
        comment: any(named: 'comment'),
      ),
    ).thenAnswer(
      (_) async => (
        entry: listItem('gc_1').entry,
        syncQueueId: 'sq_1',
        operation: _updateOp,
      ),
    );
  });

  /// The entry the sheet starts from: quantity 2, rating 7, comment 'ok',
  /// favorite off, play again on. [rating] and [comment] can be unset.
  GameCollectionListItem row({
    int? rating = 7,
    String? comment = 'ok',
    int quantity = 2,
  }) {
    final base = listItem('gc_1', quantity: quantity);
    return GameCollectionListItem(
      entry: GameCollection(
        id: base.entry.id,
        userId: base.entry.userId,
        platformGameId: base.entry.platformGameId,
        medium: base.entry.medium,
        quantity: quantity,
        rating: rating,
        comment: comment,
        playAgain: true,
        createdAt: base.entry.createdAt,
        updatedAt: base.entry.updatedAt,
      ),
      gameId: base.gameId,
      title: 'Wingspan',
      subtitle: base.subtitle,
      platformName: base.platformName,
      thumbnail: base.thumbnail,
    );
  }

  void verifyNoUpdate() => verifyNever(
    () => repository.updateCollectionEntry(
      id: any(named: 'id'),
      quantity: any(named: 'quantity'),
      rating: any(named: 'rating'),
      playAgain: any(named: 'playAgain'),
      favorite: any(named: 'favorite'),
      comment: any(named: 'comment'),
    ),
  );

  /// A screen with a button that opens the sheet, over a bloc whose row is
  /// already in.
  ///
  /// With [nested], that screen is on a navigator nested in the root one,
  /// as a page under the navigation shell is (#414).
  Future<void> open(
    WidgetTester tester, {
    GameCollectionListItem? item,
    TextScaler textScaler = TextScaler.noScaling,
    bool reopen = false,
    bool nested = false,
  }) async {
    if (!reopen) {
      bloc = CollectionEntryBloc(
        repository: repository,
        sender: sender,
        entryId: 'gc_1',
        logger: _MockLogger(),
      );
      addTearDown(bloc.close);
      watch.add(item ?? row());
      await tester.pump();
      await tester.pump();
    }
    final opener = Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: _openKey,
          onPressed: () => showEditCollectionEntrySheet(context, bloc: bloc),
          child: const Text('Open'),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates:
            GameCollectionLocalizations.localizationsDelegates,
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: nested
            ? Navigator(
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => opener),
              )
            : opener,
      ),
    );
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
  }

  Future<void> tapInView(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, Key field, String label) async {
    await tapInView(tester, find.byKey(field));
    await tapInView(
      tester,
      find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text(label),
      ),
    );
  }

  Future<void> type(WidgetTester tester, Key field, String text) async {
    await tester.ensureVisible(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(field), text);
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) =>
      tapInView(tester, find.byKey(EditCollectionEntrySheet.submitKey));

  Finder within(Key key, Finder matching) =>
      find.descendant(of: find.byKey(key), matching: matching);

  Finder switchOf(Key key) =>
      find.descendant(of: find.byKey(key), matching: find.byType(Switch));

  /// The node a screen reader lands on for [label]: the one the labelled
  /// node is merged into, when it is.
  SemanticsNode nodeFor(String label) {
    var node = find.semantics.byLabel(label).evaluate().single;
    while (node.isMergedIntoParent) {
      node = node.parent!;
    }
    return node;
  }

  testWidgets("starts from the entry's values", (tester) async {
    await open(tester);

    expect(find.text('Edit Wingspan'), findsOneWidget);
    expect(
      within(EditCollectionEntrySheet.quantityKey, find.text('2')),
      findsOneWidget,
    );
    expect(
      within(EditCollectionEntrySheet.ratingKey, find.text('7 out of 10')),
      findsOneWidget,
    );
    expect(
      within(EditCollectionEntrySheet.commentKey, find.text('ok')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Switch>(switchOf(EditCollectionEntrySheet.favoriteKey))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<Switch>(switchOf(EditCollectionEntrySheet.playAgainKey))
          .value,
      isTrue,
    );
  });

  testWidgets('a rated entry offers no "No rating"', (tester) async {
    await open(tester);

    await tapInView(tester, find.byKey(EditCollectionEntrySheet.ratingKey));

    expect(
      find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text('No rating'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text('1 out of 10'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an unrated entry starts at and offers "No rating"', (
    tester,
  ) async {
    await open(tester, item: row(rating: null));

    expect(
      within(EditCollectionEntrySheet.ratingKey, find.text('No rating')),
      findsOneWidget,
    );
    await tapInView(tester, find.byKey(EditCollectionEntrySheet.ratingKey));
    expect(
      find.descendant(
        of: find.byType(MenuItemButton),
        matching: find.text('No rating'),
      ),
      findsOneWidget,
    );
  });

  testWidgets("emptying a set comment is refused with the can't-clear "
      'message, and nothing is sent', (tester) async {
    await open(tester);

    await type(tester, EditCollectionEntrySheet.commentKey, '   ');
    await submit(tester);

    expect(find.text(_cantClear), findsOneWidget);
    verifyNoUpdate();
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsOneWidget);
  });

  testWidgets('a blank comment on an entry with none is fine', (tester) async {
    await open(tester, item: row(comment: null));

    await type(tester, EditCollectionEntrySheet.commentKey, '  ');
    await submit(tester);

    expect(find.text(_cantClear), findsNothing);
    verifyNoUpdate();
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
  });

  testWidgets('the quantity stops at maxQuantity', (tester) async {
    await open(tester);

    await type(
      tester,
      EditCollectionEntrySheet.quantityKey,
      '${_storedMax + 1}',
    );
    await submit(tester);
    expect(find.text(_quantityTooMany), findsOneWidget);
    verifyNoUpdate();

    await type(tester, EditCollectionEntrySheet.quantityKey, '0');
    await submit(tester);
    expect(find.text(_quantityInvalid), findsOneWidget);
    verifyNoUpdate();

    await type(tester, EditCollectionEntrySheet.quantityKey, '$_storedMax');
    await submit(tester);
    expect(find.text(_quantityTooMany), findsNothing);
    expect(find.text(_quantityInvalid), findsNothing);
    verify(
      () => repository.updateCollectionEntry(id: 'gc_1', quantity: _storedMax),
    ).called(1);
  });

  testWidgets('save submits the whole form and closes on saved', (
    tester,
  ) async {
    await open(tester);

    await type(tester, EditCollectionEntrySheet.quantityKey, '3');
    await submit(tester);

    verify(() => repository.updateCollectionEntry(id: 'gc_1', quantity: 3))
        .called(1);
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
  });

  // #414: a page under the navigation shell is on a nested navigator. The
  // sheet goes on the root one, so its barrier covers the shell's bar too.
  testWidgets('opened from a nested navigator, it goes on the root one and '
      'still saves through the bloc it was given', (tester) async {
    await open(tester, nested: true);

    final sheet = tester.element(find.byKey(EditCollectionEntrySheet.sheetKey));
    final opener = tester.element(find.byKey(_openKey));
    expect(
      Navigator.of(sheet),
      same(Navigator.of(opener, rootNavigator: true)),
    );
    expect(Navigator.of(sheet), isNot(same(Navigator.of(opener))));

    await type(tester, EditCollectionEntrySheet.quantityKey, '3');
    await submit(tester);

    verify(() => repository.updateCollectionEntry(id: 'gc_1', quantity: 3))
        .called(1);
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
    expect(find.byKey(_openKey), findsOneWidget);
  });

  testWidgets('save with nothing changed calls no update and closes', (
    tester,
  ) async {
    await open(tester);

    await submit(tester);

    verifyNoUpdate();
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
  });

  testWidgets('a failed save keeps the sheet open with the failure and the '
      'input', (tester) async {
    when(
      () => repository.updateCollectionEntry(
        id: any(named: 'id'),
        quantity: any(named: 'quantity'),
        rating: any(named: 'rating'),
        playAgain: any(named: 'playAgain'),
        favorite: any(named: 'favorite'),
        comment: any(named: 'comment'),
      ),
    ).thenThrow(StateError('disposed'));
    await open(tester);

    await type(tester, EditCollectionEntrySheet.quantityKey, '3');
    await submit(tester);

    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsOneWidget);
    expect(find.text(_failedTitle), findsOneWidget);
    expect(
      within(EditCollectionEntrySheet.quantityKey, find.text('3')),
      findsOneWidget,
    );

    // Editing retires the failure: it was about what was there before.
    await type(tester, EditCollectionEntrySheet.quantityKey, '4');
    expect(find.text(_failedTitle), findsNothing);
  });

  testWidgets('a sheet re-opened after a failed save does not open on the '
      'old failure', (tester) async {
    when(
      () => repository.updateCollectionEntry(
        id: any(named: 'id'),
        quantity: any(named: 'quantity'),
        rating: any(named: 'rating'),
        playAgain: any(named: 'playAgain'),
        favorite: any(named: 'favorite'),
        comment: any(named: 'comment'),
      ),
    ).thenThrow(StateError('disposed'));
    await open(tester);
    await type(tester, EditCollectionEntrySheet.quantityKey, '3');
    await submit(tester);
    expect(find.text(_failedTitle), findsOneWidget);
    expect(bloc.state.action, CollectionEntryAction.saveFailed);

    // Dismiss it by tapping the barrier, then open it again.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
    expect(bloc.state.action, CollectionEntryAction.saveFailed);
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();

    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsOneWidget);
    expect(find.text(_failedTitle), findsNothing);
  });

  testWidgets('one save carries a changed rating, favorite and play again', (
    tester,
  ) async {
    await open(tester);

    await pick(tester, EditCollectionEntrySheet.ratingKey, '9 out of 10');
    await tapInView(tester, find.byKey(EditCollectionEntrySheet.favoriteKey));
    await tapInView(tester, find.byKey(EditCollectionEntrySheet.playAgainKey));
    await submit(tester);

    verify(
      () => repository.updateCollectionEntry(
        id: 'gc_1',
        rating: 9,
        favorite: true,
        playAgain: false,
      ),
    ).called(1);
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
  });

  // In-flight forms go read-only, never disabled (STYLE_GUIDE \u00a74): a switch
  // keeps its place in the focus order and its value, as the rating's
  // read-only dropdown does, and reads to assistive tech as that dropdown
  // does: enabled and read-only, with no tap to offer.
  testWidgets('a save held open leaves the switches read-only, not disabled, '
      'and a failed one frees them again', (tester) async {
    final semantics = tester.ensureSemantics();
    final held =
        Completer<
          ({
            GameCollection entry,
            String syncQueueId,
            UpdateCollectionOperation operation,
          })
        >();
    when(
      () => repository.updateCollectionEntry(
        id: any(named: 'id'),
        quantity: any(named: 'quantity'),
        rating: any(named: 'rating'),
        playAgain: any(named: 'playAgain'),
        favorite: any(named: 'favorite'),
        comment: any(named: 'comment'),
      ),
    ).thenAnswer((_) => held.future);
    await open(tester);
    final l10n = GameCollectionLocalizations.of(
      tester.element(find.byKey(EditCollectionEntrySheet.sheetKey)),
    );
    bool favorite() => tester
        .widget<Switch>(switchOf(EditCollectionEntrySheet.favoriteKey))
        .value;
    // The tile's own focus, which a keyboard user lands on.
    final favoriteFocus = Focus.of(
      tester.element(
        within(EditCollectionEntrySheet.favoriteKey, find.text('Favorite')),
      ),
    );

    await tapInView(tester, find.byKey(EditCollectionEntrySheet.playAgainKey));
    await tester.ensureVisible(find.byKey(EditCollectionEntrySheet.submitKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EditCollectionEntrySheet.submitKey));
    await tester.pump();
    await tester.pump();

    expect(bloc.state.action, CollectionEntryAction.saving);
    // The rating's read-only dropdown, which the switches follow.
    expect(
      find.semantics
          .byLabel(RegExp(RegExp.escape(l10n.addToCollectionRatingLabel)))
          .evaluate()
          .single,
      isSemantics(
        hasEnabledState: true,
        isEnabled: true,
        isReadOnly: true,
        isFocusable: true,
        hasFocusAction: true,
        hasTapAction: false,
      ),
    );
    for (final (label, on) in [
      (l10n.editCollectionFavorite, false),
      (l10n.editCollectionPlayAgain, false),
    ]) {
      expect(
        nodeFor(label),
        isSemantics(
          hasEnabledState: true,
          isEnabled: true,
          isReadOnly: true,
          isFocusable: true,
          hasFocusAction: true,
          hasToggledState: true,
          isToggled: on,
          hasTapAction: false,
        ),
        reason: label,
      );
    }
    expect(
      find.semantics.byLabel(l10n.editCollectionInProgress).evaluate().single,
      isSemantics(hasEnabledState: true, isEnabled: false),
    );

    // Neither a tap nor the keyboard toggles it, and it keeps the focus.
    await tester.tap(
      find.byKey(EditCollectionEntrySheet.favoriteKey),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(favorite(), isFalse);
    favoriteFocus.requestFocus();
    await tester.pump();
    expect(favoriteFocus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(favorite(), isFalse);
    expect(favoriteFocus.hasPrimaryFocus, isTrue);

    held.completeError(StateError('disposed'));
    await tester.pumpAndSettle();

    expect(find.text(_failedTitle), findsOneWidget);
    expect(favoriteFocus.hasPrimaryFocus, isTrue);
    expect(
      nodeFor(l10n.editCollectionFavorite),
      isSemantics(
        hasEnabledState: true,
        isEnabled: true,
        isReadOnly: false,
        hasTapAction: true,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(favorite(), isTrue);
    await tapInView(tester, find.byKey(EditCollectionEntrySheet.favoriteKey));
    expect(favorite(), isFalse);
    semantics.dispose();
  });

  testWidgets('a no-change save over an outcome nobody cleared still closes', (
    tester,
  ) async {
    await open(tester);
    await submit(tester);
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
    expect(bloc.state.action, CollectionEntryAction.saved);
    expect(bloc.state.changed, isFalse);

    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsOneWidget);
    await submit(tester);

    verifyNoUpdate();
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
  });

  testWidgets('the comment field stays above the keyboard', (tester) async {
    useViewSize(tester, const Size(400, 800));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await open(tester);

    final comment = find.byKey(EditCollectionEntrySheet.commentKey);
    await tester.showKeyboard(comment);
    await tester.pumpAndSettle();

    expect(tester.getRect(comment).bottom, lessThanOrEqualTo(800 - 300));
  });

  testWidgets('lays out at 320dp and 2x text', (tester) async {
    useViewSize(tester, const Size(320, 640));
    await open(tester, textScaler: const TextScaler.linear(2));

    await pick(tester, EditCollectionEntrySheet.ratingKey, '10 out of 10');

    expect(tester.takeException(), isNull);
    expect(find.text('Edit Wingspan'), findsOneWidget);
    expect(find.text('10 out of 10'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(EditCollectionEntrySheet.playAgainKey),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens nothing when the bloc has no item', (tester) async {
    bloc = CollectionEntryBloc(
      repository: repository,
      sender: sender,
      entryId: 'gc_1',
      logger: _MockLogger(),
    );
    addTearDown(bloc.close);
    await open(tester, reopen: true);

    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
  });
}
