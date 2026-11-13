import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/list_items.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

typedef _Updated = ({
  GameCollection entry,
  String syncQueueId,
  UpdateCollectionOperation operation,
});

const _updateOp = UpdateCollectionOperation(collectionId: 'gc_1', quantity: 3);
const _removeOp = RemoveFromCollectionOperation(collectionId: 'gc_1');

const _openKey = Key('test.open_entry');
const _listCopy = 'The list beneath';

const _thumbnailUrl = 'https://images.example.com/wingspan.jpg';
const _savedCopy = 'Saved';
const _savedQueuedCopy = 'Saved on this device. It will sync when it can.';
const _refusedCopy =
    "The server didn't accept this change. See changes that couldn't sync.";
const _saveFailedCopy = "Couldn't save your changes";
const _removedCopy = 'Removed Wingspan';
const _removedQueuedCopy =
    'Removed Wingspan on this device. It will sync when it can.';
const _removeFailedCopy = "Couldn't remove Wingspan.";
const _saveFailedGoneCopy =
    "It's no longer in your collection, perhaps removed on another device.";
const _coveringCopy = 'A page over the entry';

/// Pins the #46 detail: the summary and every field with its empty value,
/// the gone, error and loading states, the game details link, and the edit
/// and removal outcomes the screen reports itself.
void main() {
  late _MockGameCollectionRepository repository;
  late _MockSyncOperationSender sender;
  late FakeSessionLease lease;
  late StreamController<GameCollectionListItem?> watch;

  setUpAll(() {
    registerFallbackValue(_updateOp);
  });

  setUp(() {
    repository = _MockGameCollectionRepository();
    sender = _MockSyncOperationSender();
    lease = FakeSessionLease();
    watch = StreamController<GameCollectionListItem?>();
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
    // As the real one does, the removal takes the row out of the watch
    // before it returns.
    when(() => repository.removeFromCollection('gc_1')).thenAnswer((_) async {
      watch.add(null);
      return (syncQueueId: 'sq_2', operation: _removeOp);
    });
  });

  tearDown(() => unawaited(watch.close()));

  Future<_Updated> callUpdate() => repository.updateCollectionEntry(
    id: any(named: 'id'),
    quantity: any(named: 'quantity'),
    rating: any(named: 'rating'),
    playAgain: any(named: 'playAgain'),
    favorite: any(named: 'favorite'),
    comment: any(named: 'comment'),
  );

  /// Wingspan with every field set.
  GameCollectionListItem fullRow({String comment = 'Best with five.'}) {
    final base = listItem('gc_1');
    return GameCollectionListItem(
      entry: base.entry.copyWith(
        quantity: 2,
        rating: 7,
        favorite: true,
        playAgain: true,
        playCount: 12,
        // Midday, so the local date is the 14th in any test time zone.
        lastPlayed: DateTime.utc(2026, 3, 14, 12),
        comment: comment,
      ),
      gameId: 'g-wingspan',
      title: 'Wingspan',
      subtitle: 'Asia',
      platformName: 'Board game',
      thumbnail: _thumbnailUrl,
    );
  }

  /// Wingspan with only what an entry must have: one digital copy, and no
  /// rating, favorite, play again, plays, last played or comment.
  GameCollectionListItem bareRow() => listItem(
    'gc_1',
    gameId: 'g-wingspan',
    title: 'Wingspan',
    medium: GameMedium.digital,
  );

  /// [home] in [theme], light by default. [textScaler] overrides the
  /// device's text scale only when set.
  Widget app(Widget home, {TextScaler? textScaler, ThemeData? theme}) =>
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        localizationsDelegates:
            GameCollectionLocalizations.localizationsDelegates,
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
        home: home,
      );

  Widget screen({void Function(BuildContext, String)? onOpenGame}) =>
      CollectionEntryScreen(
        repository: repository,
        sender: sender,
        session: lease,
        entryId: 'gc_1',
        onOpenGame: onOpenGame,
      );

  /// The screen as the app's home, over [item] (Wingspan, fully set, by
  /// default).
  Future<void> show(
    WidgetTester tester, {
    GameCollectionListItem? item,
    void Function(BuildContext, String)? onOpenGame,
  }) async {
    watch.add(item ?? fullRow());
    await tester.pumpWidget(app(screen(onOpenGame: onOpenGame)));
    await tester.pumpAndSettle();
  }

  /// A page whose one button pushes the screen, as the list opens it.
  Widget opener({void Function(BuildContext, String)? onOpenGame}) => Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        key: _openKey,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => screen(onOpenGame: onOpenGame),
          ),
        ),
        child: const Text(_listCopy),
      ),
    ),
  );

  /// The screen pushed over a page, as the list opens it, so that its pop
  /// and a SnackBar over the page beneath are real.
  Future<void> showPushed(
    WidgetTester tester, {
    GameCollectionListItem? item,
    void Function(BuildContext, String)? onOpenGame,
    TextScaler? textScaler,
    ThemeData? theme,
  }) async {
    watch.add(item ?? fullRow());
    await tester.pumpWidget(
      app(
        opener(onOpenGame: onOpenGame),
        textScaler: textScaler,
        theme: theme,
      ),
    );
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
  }

  CollectionEntryBloc blocOf(WidgetTester tester) =>
      BlocProvider.of<CollectionEntryBloc>(
        tester.element(find.byType(CollectionEntryDetail)),
      );

  GameCollectionLocalizations l10nOf(WidgetTester tester) =>
      GameCollectionLocalizations.of(
        tester.element(find.byType(CollectionEntryDetail)),
      );

  /// Whether [bloc] is closed, once a close begun on the test's clock has
  /// had real time to take. Measured: on fake time alone `Bloc.close` never
  /// gets as far as closing, so `isClosed` would read false either way.
  Future<bool> closed(WidgetTester tester, CollectionEntryBloc bloc) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    return bloc.isClosed;
  }

  /// The focus node of the button keyed [key]: the one its label sits under.
  FocusNode focusOf(WidgetTester tester, Key key, String label) => Focus.of(
    tester.element(
      find.descendant(of: find.byKey(key), matching: find.text(label)),
    ),
  );

  /// Holds the removal open until the returned completer completes.
  Completer<({String syncQueueId, RemoveFromCollectionOperation operation})?>
  holdRemoval() {
    final held =
        Completer<
          ({String syncQueueId, RemoveFromCollectionOperation operation})?
        >();
    when(() => repository.removeFromCollection('gc_1'))
        .thenAnswer((_) => held.future);
    return held;
  }

  Future<void> tapInView(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, Key field, String text) async {
    await tester.ensureVisible(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(field), text);
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(CollectionEntryScreen.editKey));
    await tester.pumpAndSettle();
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsOneWidget);
  }

  Future<void> submit(WidgetTester tester) =>
      tapInView(tester, find.byKey(EditCollectionEntrySheet.submitKey));

  /// Opens the sheet and submits a change to the copies, with the update held
  /// open until the returned completer completes. Pumps rather than settles:
  /// the submit spins while the save is out.
  Future<Completer<_Updated>> submitHeld(WidgetTester tester) async {
    final held = Completer<_Updated>();
    when(callUpdate).thenAnswer((_) => held.future);
    await openSheet(tester);
    await type(tester, EditCollectionEntrySheet.quantityKey, '3');
    await tester.ensureVisible(find.byKey(EditCollectionEntrySheet.submitKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EditCollectionEntrySheet.submitKey));
    await tester.pump();
    await tester.pump();
    expect(blocOf(tester).state.action, CollectionEntryAction.saving);
    return held;
  }

  /// Submits a change to the copies from the open sheet, with the update
  /// held open, and dismisses the sheet by its barrier.
  Future<Completer<_Updated>> submitHeldThenDismiss(WidgetTester tester) async {
    final held = await submitHeld(tester);

    // Dismissed by its barrier while the save is still out.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
    return held;
  }

  Future<void> confirmRemove(WidgetTester tester) async {
    await tester.tap(find.byKey(CollectionEntryScreen.removeKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(RemoveFromCollectionDialog.confirmKey));
    await tester.pumpAndSettle();
  }

  Finder snackBarText(String text) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(text));

  group('the entry', () {
    testWidgets('shows the summary and every field', (tester) async {
      await show(tester);

      expect(find.text('Wingspan'), findsOneWidget);
      expect(find.text('Asia'), findsOneWidget);
      expect(find.text('Board game'), findsOneWidget);
      expect(
        tester.widget<BgeThumbnail>(find.byType(BgeThumbnail)).url,
        _thumbnailUrl,
      );
      expect(find.text('Physical'), findsOneWidget);
      expect(find.text('2 copies'), findsOneWidget);
      expect(find.text('7/10'), findsOneWidget);
      expect(find.text('Favorite'), findsOneWidget);
      expect(find.text('Would play again'), findsOneWidget);
      expect(find.text('12 plays'), findsOneWidget);
      expect(find.text('Last played Mar 14, 2026'), findsOneWidget);
      expect(find.text('Best with five.'), findsOneWidget);
    });

    testWidgets("shows each field's empty value", (tester) async {
      await show(tester, item: bareRow());

      expect(find.text('Wingspan'), findsOneWidget);
      expect(find.text('Digital'), findsOneWidget);
      expect(find.text('1 copy'), findsOneWidget);
      expect(find.text('No rating'), findsOneWidget);
      // Said only when true: an entry that isn't a favorite says nothing
      // about it, as the list's row doesn't.
      expect(find.text('Favorite'), findsNothing);
      expect(find.text('Would play again'), findsNothing);
      expect(find.text('No plays recorded'), findsOneWidget);
      expect(find.text('Not played yet'), findsOneWidget);
      expect(find.text('No comment'), findsOneWidget);
    });

    testWidgets('shows a spinner, named for a screen reader, until the entry '
        'is read', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app(screen()));

      expect(find.byKey(CollectionEntryScreen.loadingKey), findsOneWidget);
      expect(
        find.semantics.byLabel(l10nOf(tester).collectionEntryLoading),
        findsOne,
      );
      expect(find.byKey(CollectionEntryScreen.editKey), findsNothing);
      expect(find.byKey(CollectionEntryScreen.removeKey), findsNothing);
      semantics.dispose();
    });

    testWidgets('"Game details" calls onOpenGame with the item\'s gameId', (
      tester,
    ) async {
      final opened = <String>[];
      await show(tester, onOpenGame: (_, gameId) => opened.add(gameId));

      await tapInView(tester, find.byKey(CollectionEntryScreen.gameDetailsKey));

      expect(opened, ['g-wingspan']);
      expect(find.text('Game details'), findsOneWidget);
    });

    testWidgets('"Game details" is absent without onOpenGame', (tester) async {
      await show(tester);

      expect(find.byKey(CollectionEntryScreen.gameDetailsKey), findsNothing);
    });

    testWidgets('gone shows the gone state with no Edit or Remove', (
      tester,
    ) async {
      await showPushed(tester);
      expect(find.byKey(CollectionEntryScreen.editKey), findsOneWidget);

      // Removed on another device: the row watch answers null.
      watch.add(null);
      await tester.pumpAndSettle();

      expect(find.byKey(CollectionEntryScreen.goneKey), findsOneWidget);
      // Named, from the row the bloc keeps, so the user knows what went.
      expect(find.text('Wingspan'), findsOneWidget);
      expect(find.text('No longer in your collection'), findsOneWidget);
      expect(
        find.text('It was removed, perhaps on another device.'),
        findsOneWidget,
      );
      expect(find.byKey(CollectionEntryScreen.editKey), findsNothing);
      expect(find.byKey(CollectionEntryScreen.removeKey), findsNothing);
      expect(find.byKey(CollectionEntryScreen.loadingKey), findsNothing);
      // Not popped: the user reads why it went.
      expect(find.byType(CollectionEntryScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('not in the cache yet is loading while the hydrate runs, and '
        'gone once it lands without it', (tester) async {
      final hydration = StreamController<Hydration>();
      addTearDown(hydration.close);
      hydration.add(const Hydration(state: HydrationState.running));
      watch.add(null);
      await tester.pumpWidget(
        app(
          CollectionEntryScreen(
            repository: repository,
            sender: sender,
            session: lease,
            entryId: 'gc_1',
            hydration: hydration.stream,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(CollectionEntryScreen.loadingKey), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.goneKey), findsNothing);

      hydration.add(
        const Hydration(state: HydrationState.refreshed, everRefreshed: true),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(CollectionEntryScreen.goneKey), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.loadingKey), findsNothing);
    });

    testWidgets('removed elsewhere with the sheet open, a save fails in the '
        'sheet rather than throwing', (tester) async {
      when(callUpdate).thenThrow(StateError('not in the collection'));
      await show(tester);
      await openSheet(tester);

      watch.add(null);
      await tester.pumpAndSettle();
      await type(tester, EditCollectionEntrySheet.quantityKey, '3');
      await submit(tester);

      expect(tester.takeException(), isNull);
      expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsOneWidget);
      expect(find.text(_saveFailedCopy), findsOneWidget);
      // Why, rather than to try again: a retry can't succeed.
      expect(find.text(_saveFailedGoneCopy), findsOneWidget);
      expect(find.text('Nothing was changed. Try again.'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(CollectionEntryScreen.goneKey), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.editKey), findsNothing);
    });

    // The failure is the screen (STYLE_GUIDE §4, "Error and outcome
    // surfaces"): `BgeErrorState`, with a retry.
    testWidgets('error is the error state, whose retry watches the entry '
        'again', (tester) async {
      final again = StreamController<GameCollectionListItem?>();
      addTearDown(() => unawaited(again.close()));
      final watches = [watch, again];
      when(() => repository.watchCollectionListItem('gc_1'))
          .thenAnswer((_) => watches.removeAt(0).stream);
      watch.addError(StateError('the read failed'));
      await tester.pumpWidget(app(screen()));
      await tester.pumpAndSettle();

      final error = find.byKey(CollectionEntryScreen.errorKey);
      expect(error, findsOneWidget);
      expect(tester.widget(error), isA<BgeErrorState>());
      expect(find.text("Couldn't load this entry."), findsOneWidget);
      expect(
        find.text('Try again, or go back to your collection.'),
        findsOneWidget,
      );
      expect(find.byKey(CollectionEntryScreen.editKey), findsNothing);
      expect(find.byKey(CollectionEntryScreen.removeKey), findsNothing);

      await tester.tap(find.byKey(CollectionEntryScreen.retryKey));
      await tester.pump();
      expect(find.byKey(CollectionEntryScreen.loadingKey), findsOneWidget);

      again.add(fullRow());
      await tester.pumpAndSettle();

      verify(() => repository.watchCollectionListItem('gc_1')).called(2);
      expect(error, findsNothing);
      expect(find.text('12 plays'), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.editKey), findsOneWidget);
    });
  });

  group('an edit', () {
    testWidgets('Edit opens the sheet, and a synced save says "Saved"', (
      tester,
    ) async {
      await show(tester);
      await openSheet(tester);

      await type(tester, EditCollectionEntrySheet.quantityKey, '3');
      await submit(tester);

      verify(() => repository.updateCollectionEntry(id: 'gc_1', quantity: 3))
          .called(1);
      expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
      expect(snackBarText(_savedCopy), findsOneWidget);
      expect(blocOf(tester).state.action, CollectionEntryAction.idle);
    });

    for (final (name, delivery, copy) in [
      (
        'a queued save says it will sync',
        const SyncNotClaimed(),
        _savedQueuedCopy,
      ),
      (
        'a refused save says the server refused it',
        SyncParked(Exception('rejected')),
        _refusedCopy,
      ),
    ]) {
      testWidgets(name, (tester) async {
        when(() => sender.deliver(any(), any()))
            .thenAnswer((_) async => delivery);
        await show(tester);
        await openSheet(tester);

        await type(tester, EditCollectionEntrySheet.quantityKey, '3');
        await submit(tester);

        expect(snackBarText(copy), findsOneWidget);
        expect(blocOf(tester).state.action, CollectionEntryAction.idle);
      });
    }

    testWidgets('a save with nothing changed says nothing', (tester) async {
      await show(tester);
      await openSheet(tester);

      await submit(tester);

      verifyNever(callUpdate);
      expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(blocOf(tester).state.action, CollectionEntryAction.idle);
    });

    testWidgets("a save that fails with the sheet open is the sheet's to "
        'show', (tester) async {
      when(callUpdate).thenThrow(StateError('disposed'));
      await show(tester);
      await openSheet(tester);

      await type(tester, EditCollectionEntrySheet.quantityKey, '3');
      await submit(tester);

      expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsOneWidget);
      expect(find.text(_saveFailedCopy), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('the sheet dismissed mid-save, then the save fails, shows the '
        'failure SnackBar', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester);
      final l10n = l10nOf(tester);
      final held = await submitHeldThenDismiss(tester);

      // Edit and Remove wait for the save: a second sheet would not be the
      // one that submitted. They stay, held, and Edit says what is under
      // way (STYLE_GUIDE §5, "Disable, don't hide").
      expect(find.byKey(CollectionEntryScreen.editKey), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.removeKey), findsOneWidget);
      expect(
        find.semantics.byLabel(l10n.editCollectionInProgress).evaluate().single,
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isLiveRegion: true,
          isFocusable: true,
          hasTapAction: false,
        ),
      );
      expect(
        find.semantics.byLabel(l10n.collectionEntryRemove).evaluate().single,
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: true,
          hasTapAction: false,
        ),
      );
      await tester.tap(find.byKey(CollectionEntryScreen.editKey));
      await tester.tap(find.byKey(CollectionEntryScreen.removeKey));
      await tester.pumpAndSettle();
      expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
      expect(find.byType(RemoveFromCollectionDialog), findsNothing);

      held.completeError(StateError('disposed'));
      await tester.pumpAndSettle();

      expect(snackBarText(_saveFailedCopy), findsOneWidget);
      expect(blocOf(tester).state.action, CollectionEntryAction.idle);
      expect(
        find.semantics.byLabel(l10n.collectionEntryEdit).evaluate().single,
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.byKey(CollectionEntryScreen.editKey));
      await tester.pumpAndSettle();
      expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsOneWidget);
      semantics.dispose();
    });

    // As #45's dismissed add is: the outcome outlives the screen.
    testWidgets('left mid-save, a save that then fails is said over the page '
        'beneath', (tester) async {
      await showPushed(tester);
      final held = await submitHeldThenDismiss(tester);
      final bloc = blocOf(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CollectionEntryScreen), findsNothing);
      // Kept for the save still under way.
      expect(await closed(tester, bloc), isFalse);

      held.completeError(StateError('disposed'));
      await tester.pumpAndSettle();

      expect(find.text(_listCopy), findsOneWidget);
      expect(snackBarText(_saveFailedCopy), findsOneWidget);
      expect(await closed(tester, bloc), isTrue);
    });

    testWidgets('left mid-save, a save that then lands is said too', (
      tester,
    ) async {
      await showPushed(tester);
      final held = await submitHeldThenDismiss(tester);
      final bloc = blocOf(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();

      held.complete((
        entry: listItem('gc_1').entry,
        syncQueueId: 'sq_1',
        operation: _updateOp,
      ));
      await tester.pumpAndSettle();

      expect(find.text(_listCopy), findsOneWidget);
      expect(snackBarText(_savedCopy), findsOneWidget);
      expect(await closed(tester, bloc), isTrue);
    });

    testWidgets('left with nothing under way, the bloc closes with the '
        'screen', (tester) async {
      await showPushed(tester);
      final bloc = blocOf(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(await closed(tester, bloc), isTrue);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('a removal', () {
    testWidgets('Remove asks, and cancel does nothing', (tester) async {
      await show(tester);

      await tester.tap(find.byKey(CollectionEntryScreen.removeKey));
      await tester.pumpAndSettle();
      expect(find.text('Remove Wingspan?'), findsOneWidget);

      await tester.tap(find.byKey(RemoveFromCollectionDialog.cancelKey));
      await tester.pumpAndSettle();

      verifyNever(() => repository.removeFromCollection(any()));
      expect(find.byType(RemoveFromCollectionDialog), findsNothing);
      expect(find.text('Wingspan'), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.removeKey), findsOneWidget);
    });

    testWidgets('confirm removes, pops the route and shows "Removed {title}"', (
      tester,
    ) async {
      await showPushed(tester);

      await confirmRemove(tester);

      verify(() => repository.removeFromCollection('gc_1')).called(1);
      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(find.text(_listCopy), findsOneWidget);
      expect(snackBarText(_removedCopy), findsOneWidget);
    });

    testWidgets('while it is under way, Edit and Remove are held, Remove says '
        "it is removing, and the removal's own vanishing row isn't shown as "
        'gone', (tester) async {
      final semantics = tester.ensureSemantics();
      final held = holdRemoval();
      await showPushed(tester);
      final l10n = l10nOf(tester);

      await confirmRemove(tester);
      expect(blocOf(tester).state.action, CollectionEntryAction.removing);
      watch.add(null);
      await tester.pumpAndSettle();

      // In place, read as disabled, and doing nothing (STYLE_GUIDE §5,
      // "Disable, don't hide").
      expect(
        find.descendant(
          of: find.byKey(CollectionEntryScreen.removeKey),
          matching: find.text(l10n.collectionEntryRemoving),
        ),
        findsOneWidget,
      );
      expect(
        find.semantics.byLabel(l10n.collectionEntryRemoving).evaluate().single,
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isLiveRegion: true,
          isFocusable: true,
          hasTapAction: false,
        ),
      );
      expect(
        find.semantics.byLabel(l10n.collectionEntryEdit).evaluate().single,
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: true,
          hasTapAction: false,
        ),
      );
      await tester.tap(find.byKey(CollectionEntryScreen.editKey));
      await tester.tap(find.byKey(CollectionEntryScreen.removeKey));
      await tester.pumpAndSettle();
      expect(find.byKey(EditCollectionEntrySheet.sheetKey), findsNothing);
      expect(find.byType(RemoveFromCollectionDialog), findsNothing);
      verify(() => repository.removeFromCollection('gc_1')).called(1);

      expect(find.byKey(CollectionEntryScreen.goneKey), findsNothing);
      expect(find.text('Wingspan'), findsOneWidget);

      held.complete((syncQueueId: 'sq_2', operation: _removeOp));
      await tester.pumpAndSettle();

      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(snackBarText(_removedCopy), findsOneWidget);
      semantics.dispose();
    });

    // Measured: the dialog hands the focus back to Remove when it closes,
    // and Remove, held rather than disabled, keeps it.
    testWidgets('keyboard focus on Remove stays on it through the confirm '
        'and the removal', (tester) async {
      final semantics = tester.ensureSemantics();
      final held = holdRemoval();
      await showPushed(tester);
      final l10n = l10nOf(tester);
      final remove = focusOf(
        tester,
        CollectionEntryScreen.removeKey,
        l10n.collectionEntryRemove,
      )..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(RemoveFromCollectionDialog), findsOneWidget);
      await tester.tap(find.byKey(RemoveFromCollectionDialog.confirmKey));
      await tester.pumpAndSettle();

      expect(blocOf(tester).state.action, CollectionEntryAction.removing);
      expect(remove.hasPrimaryFocus, isTrue);
      expect(
        find.semantics.byLabel(l10n.collectionEntryRemoving).evaluate().single,
        isSemantics(isButton: true, isEnabled: false, isFocused: true),
      );

      held.complete((syncQueueId: 'sq_2', operation: _removeOp));
      await tester.pumpAndSettle();
      expect(find.byType(CollectionEntryScreen), findsNothing);
      semantics.dispose();
    });

    // A page opened over the detail mid-removal would keep the removal from
    // closing it, and leave it showing the removed entry as live.
    testWidgets('"Game details" is held while it is under way, so the '
        'removal still closes the screen', (tester) async {
      final semantics = tester.ensureSemantics();
      final held = holdRemoval();
      final opened = <String>[];
      await showPushed(tester, onOpenGame: (_, gameId) => opened.add(gameId));
      final l10n = l10nOf(tester);

      await confirmRemove(tester);
      await tapInView(tester, find.byKey(CollectionEntryScreen.gameDetailsKey));

      expect(opened, isEmpty);
      expect(
        find.semantics
            .byLabel(l10n.collectionEntryGameDetails)
            .evaluate()
            .single,
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: true,
          hasTapAction: false,
        ),
      );

      held.complete((syncQueueId: 'sq_2', operation: _removeOp));
      await tester.pumpAndSettle();

      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(snackBarText(_removedCopy), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('one that lands while another route covers the screen is '
        'said there, and the screen stays, gone, with nothing held', (
      tester,
    ) async {
      final held = holdRemoval();
      await showPushed(tester);
      await confirmRemove(tester);
      expect(blocOf(tester).state.action, CollectionEntryAction.removing);

      // Pushed from outside the screen, which holds its own ways out.
      Navigator.of(tester.element(find.byType(CollectionEntryDetail))).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              Scaffold(appBar: AppBar(), body: const Text(_coveringCopy)),
        ),
      );
      await tester.pumpAndSettle();

      watch.add(null);
      held.complete((syncQueueId: 'sq_2', operation: _removeOp));
      await tester.pumpAndSettle();

      // Nothing was popped: the covering page is still on top.
      expect(find.text(_coveringCopy), findsOneWidget);
      expect(snackBarText(_removedCopy), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(CollectionEntryScreen), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.goneKey), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.editKey), findsNothing);

      // Added again elsewhere: the same row comes back, and nothing is held.
      watch.add(fullRow());
      await tester.pumpAndSettle();
      expect(blocOf(tester).state.action, CollectionEntryAction.idle);
      await openSheet(tester);
    });

    // As #45's dismissed add is: the outcome outlives the screen.
    testWidgets('left mid-removal, the removal is still said over the page '
        'beneath, which stays', (tester) async {
      final held = holdRemoval();
      await showPushed(tester);
      await confirmRemove(tester);
      final bloc = blocOf(tester);
      expect(bloc.state.action, CollectionEntryAction.removing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(await closed(tester, bloc), isFalse);

      held.complete((syncQueueId: 'sq_2', operation: _removeOp));
      await tester.pumpAndSettle();

      // Nothing more was popped.
      expect(find.text(_listCopy), findsOneWidget);
      expect(snackBarText(_removedCopy), findsOneWidget);
      expect(await closed(tester, bloc), isTrue);
    });

    testWidgets('a removal left mid-flight says nothing once the session has '
        'ended', (tester) async {
      final held = holdRemoval();
      await showPushed(tester);
      await confirmRemove(tester);
      final bloc = blocOf(tester);
      expect(bloc.state.action, CollectionEntryAction.removing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      lease.isLive = false;

      held.complete((syncQueueId: 'sq_2', operation: _removeOp));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      // Still closed: ending the session skips the message, not the close.
      expect(await closed(tester, bloc), isTrue);
    });

    for (final (name, answer, copy) in [
      (
        'a queued removal says it will sync',
        () async => (syncQueueId: 'sq_2', operation: _removeOp),
        _removedQueuedCopy,
      ),
      (
        'an entry already removed says it was removed',
        () async => null,
        _removedCopy,
      ),
    ]) {
      testWidgets(name, (tester) async {
        when(() => sender.deliver(any(), any()))
            .thenAnswer((_) async => const SyncNotClaimed());
        when(() => repository.removeFromCollection('gc_1'))
            .thenAnswer((_) => answer());
        await showPushed(tester);

        await confirmRemove(tester);

        expect(find.byType(CollectionEntryScreen), findsNothing);
        expect(snackBarText(copy), findsOneWidget);
      });
    }

    testWidgets('a refused removal says the server refused it', (tester) async {
      when(() => sender.deliver(any(), any()))
          .thenAnswer((_) async => SyncParked(Exception('rejected')));
      await showPushed(tester);

      await confirmRemove(tester);

      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(snackBarText(_refusedCopy), findsOneWidget);
    });

    testWidgets('a failed removal stays and shows the failure', (tester) async {
      when(() => repository.removeFromCollection('gc_1'))
          .thenThrow(StateError('disposed'));
      await showPushed(tester);

      await confirmRemove(tester);

      expect(find.byType(CollectionEntryScreen), findsOneWidget);
      expect(snackBarText(_removeFailedCopy), findsOneWidget);
      expect(find.text('Wingspan'), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.editKey), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.removeKey), findsOneWidget);
      expect(blocOf(tester).state.action, CollectionEntryAction.idle);
    });
  });

  // The shell ends a session in the same turn it routes away (sign-out, a
  // user switched in place), and a popped route stays mounted through its
  // exit. What settles there asks the screen's lease (#694), and is said as
  // it would be once the screen had gone (#464).
  group('an outcome that settles while the route is on its way out', () {
    /// Pops the screen and, in the same turn when [endSession], ends the
    /// session, then pumps 50 ms into the exit.
    Future<void> leave(WidgetTester tester, {bool endSession = false}) async {
      Navigator.of(tester.element(find.byType(CollectionEntryDetail))).pop();
      if (endSession) lease.isLive = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(CollectionEntryScreen), findsOneWidget);
    }

    /// The keys of the bars showing: a bar said again is a new key.
    Set<Key?> barKeys(WidgetTester tester) => {
      for (final bar in tester.widgetList<SnackBar>(find.byType(SnackBar)))
        bar.key,
    };

    /// Lets an answer just given reach the screen, still inside the exit.
    Future<void> answerInExit(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(CollectionEntryScreen), findsOneWidget);
    }

    /// Starts a removal, held until the returned function answers it.
    Future<void Function({required bool fails})> startRemoval(
      WidgetTester tester,
    ) async {
      final held = holdRemoval();
      await confirmRemove(tester);
      void answer({required bool fails}) => fails
          ? held.completeError(StateError('repository disposed'))
          : held.complete((syncQueueId: 'sq_2', operation: _removeOp));
      return answer;
    }

    /// Starts a save from the sheet and dismisses the sheet, held until the
    /// returned function answers it.
    Future<void Function({required bool fails})> startSave(
      WidgetTester tester,
    ) async {
      final held = await submitHeldThenDismiss(tester);
      void answer({required bool fails}) => fails
          ? held.completeError(StateError('repository disposed'))
          : held.complete((
              entry: listItem('gc_1').entry,
              syncQueueId: 'sq_1',
              operation: _updateOp,
            ));
      return answer;
    }

    for (final (name, start, fails) in [
      ('a removal that fails', startRemoval, true),
      ('a removal that lands', startRemoval, false),
      ('a save that fails', startSave, true),
      ('a save that lands', startSave, false),
    ]) {
      testWidgets('$name after the session ended there says nothing, and the '
          'bloc still closes', (tester) async {
        await showPushed(tester);
        final answer = await start(tester);
        final bloc = blocOf(tester);

        await leave(tester, endSession: true);
        answer(fails: fails);
        await answerInExit(tester);

        expect(find.byType(SnackBar), findsNothing);
        await tester.pumpAndSettle();
        expect(find.byType(CollectionEntryScreen), findsNothing);
        expect(find.text(_listCopy), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(await closed(tester, bloc), isTrue);
      });
    }

    for (final (name, start, copy) in [
      ('a removal that fails', startRemoval, _removeFailedCopy),
      ('a save that fails', startSave, _saveFailedCopy),
    ]) {
      testWidgets('$name there is said once, over the page beneath, which '
          'stays', (tester) async {
        await showPushed(tester);
        final answer = await start(tester);
        final bloc = blocOf(tester);

        await leave(tester);
        answer(fails: true);
        await answerInExit(tester);

        // One bar, drawn in both pages' scaffolds while the exit runs.
        expect(snackBarText(copy), findsWidgets);
        final said = barKeys(tester);
        expect(said, hasLength(1));
        await tester.pumpAndSettle();
        // Nothing more was popped, and the bar is the one said in the exit:
        // the screen's dispose said nothing more.
        expect(find.byType(CollectionEntryScreen), findsNothing);
        expect(find.text(_listCopy), findsOneWidget);
        expect(snackBarText(copy), findsOneWidget);
        expect(barKeys(tester), said);
        expect(await closed(tester, bloc), isTrue);
      });
    }
  });

  testWidgets('lays out at 320dp and 2x text', (tester) async {
    useViewSize(tester, const Size(320, 640));
    const comment =
        'Best with five, and better with the Oceania expansion on the '
        'table beside it.';
    // Pushed, as the list opens it, so the app bar has its back button.
    await showPushed(
      tester,
      item: fullRow(comment: comment),
      onOpenGame: (_, _) {},
      textScaler: const TextScaler.linear(2),
    );

    expect(tester.takeException(), isNull);
    for (final text in [
      'Wingspan',
      'Asia',
      'Board game',
      'Physical',
      '2 copies',
      '7/10',
      'Favorite',
      'Would play again',
      '12 plays',
      'Last played Mar 14, 2026',
      comment,
      'Game details',
    ]) {
      final finder = find.text(text);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: text);
      // Inside the screen.
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0), reason: text);
      expect(rect.right, lessThanOrEqualTo(320), reason: text);
    }
    // Wrapped, not cut short: the comment takes more than one line.
    final commentStyle = tester.widget<Text>(find.text(comment));
    expect(commentStyle.maxLines, isNull);
    expect(
      tester.getSize(find.text(comment)).height,
      greaterThan(tester.getSize(find.text('2 copies')).height),
    );

    // The app bar names no section, which was cut to "C…" here. Its
    // actions are wholly on screen, beside the back button rather than over
    // it, and each one's label inside its button. (This test's font draws
    // every glyph an em wide, so here a label can be ellipsized where a
    // device's font fits it whole; its node keeps the whole label.)
    expect(find.text('Collection'), findsNothing);
    final back = tester.getRect(find.byType(BackButton));
    void expectActionsOnScreen(String state) {
      for (final key in [
        CollectionEntryScreen.editKey,
        CollectionEntryScreen.removeKey,
      ]) {
        final reason = '$key, $state';
        final button = tester.getRect(find.byKey(key));
        expect(button.left, greaterThanOrEqualTo(back.right), reason: reason);
        expect(button.right, lessThanOrEqualTo(320), reason: reason);
        expect(button.top, greaterThanOrEqualTo(0), reason: reason);
        expect(button.bottom, lessThanOrEqualTo(back.bottom), reason: reason);
        final label = tester.getRect(
          find.descendant(of: find.byKey(key), matching: find.byType(Text)),
        );
        expect(label.left, greaterThanOrEqualTo(button.left), reason: reason);
        expect(label.right, lessThanOrEqualTo(button.right), reason: reason);
      }
    }

    expectActionsOnScreen('at rest');

    // And with the longer label a removal shows.
    holdRemoval();
    await tester.tap(find.byKey(CollectionEntryScreen.removeKey));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(RemoveFromCollectionDialog.confirmKey),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(RemoveFromCollectionDialog.confirmKey));
    await tester.pumpAndSettle();
    expect(blocOf(tester).state.action, CollectionEntryAction.removing);
    expect(tester.takeException(), isNull);
    expectActionsOnScreen('removing');
  });

  testWidgets('the title is a header, and Edit and Remove are named buttons', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(tester);

    expect(
      find.semantics.byLabel('Wingspan').evaluate().single,
      isSemantics(isHeader: true),
    );
    // Named by their label, not a tooltip, which VoiceOver doesn't read as a
    // name.
    for (final label in ['Edit', 'Remove']) {
      expect(
        find.semantics.byLabel(label).evaluate().single,
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
        reason: label,
      );
    }
    // The rating is read as words, not "seven slash ten".
    expect(find.semantics.byLabel('Rated 7 out of 10'), findsOne);
    // A line whose text alone doesn't say what it is says so aloud.
    for (final spoken in [
      'Platform: Board game',
      'Format: Physical',
      'Your comment: Best with five.',
    ]) {
      expect(find.semantics.byLabel(spoken), findsOne, reason: spoken);
    }
    semantics.dispose();
  });

  // With no app bar title, the game's heading is the one header, and nothing
  // empty stands in for the title.
  testWidgets("the game's title is the screen's only heading", (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester);

    final headers = find.semantics.byFlag(SemanticsFlag.isHeader).evaluate();
    expect(headers.map((node) => node.getSemanticsData().label), ['Wingspan']);
    semantics.dispose();
  });

  group('accessibility audit', () {
    /// Pushes the screen in [theme] over a page, as the list opens it, so
    /// its app bar has the back button, with whatever the watch has been
    /// given. Pumps through the push rather than settling: a read that
    /// never answers spins.
    Future<void> push(WidgetTester tester, ThemeData theme) async {
      await tester.pumpWidget(app(opener(), theme: theme));
      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    /// [showPushed] in [theme], over [item] (Wingspan, fully set, by
    /// default), with "Game details" when [gameDetails].
    Future<void> Function(WidgetTester, ThemeData) pushed({
      GameCollectionListItem? item,
      bool gameDetails = false,
    }) =>
        (tester, theme) => showPushed(
          tester,
          theme: theme,
          item: item,
          onOpenGame: gameDetails ? (_, _) {} : null,
        );

    final sheet = find.byKey(EditCollectionEntrySheet.sheetKey);
    final dialog = find.byType(RemoveFromCollectionDialog);

    /// The view made tall enough to hold the page whole, then [open], whose
    /// pop-up [of] no longer scrolls either (#50).
    Future<void> openWhole(
      WidgetTester tester,
      Finder of,
      Future<void> Function(WidgetTester tester) open,
    ) async {
      await useWholePage(tester);
      expectWholePage(tester);
      await open(tester);
      expectWholePage(tester, within: of);
    }

    /// Opens the sheet, changes the copies and submits a save that fails.
    Future<void> submitFailing(WidgetTester tester) async {
      when(callUpdate).thenThrow(StateError('disposed'));
      await openSheet(tester);
      await type(tester, EditCollectionEntrySheet.quantityKey, '3');
      await submit(tester);
      expect(find.text(_saveFailedCopy), findsOneWidget);
    }

    /// Opens the sheet, empties the copies and submits: the form refuses it.
    Future<void> submitInvalid(WidgetTester tester) async {
      await openSheet(tester);
      await type(tester, EditCollectionEntrySheet.quantityKey, '');
      await submit(tester);
      verifyNever(callUpdate);
      expect(find.text('Enter a whole number, 1 or more.'), findsOneWidget);
    }

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.byKey(CollectionEntryScreen.removeKey));
      await tester.pumpAndSettle();
      expect(find.text('Remove Wingspan?'), findsOneWidget);
    }

    // The watch never answers, so the spinner never settles.
    auditScreen(
      'loading',
      pump: push,
      settle: false,
      arrange: (tester) async {
        expect(find.byKey(CollectionEntryScreen.loadingKey), findsOneWidget);
        expect(find.byKey(CollectionEntryScreen.editKey), findsNothing);
      },
    );

    // Removed on another device: named, from the row the bloc keeps.
    auditScreen(
      'gone',
      pump: pushed(),
      arrange: (tester) async {
        watch.add(null);
        await tester.pumpAndSettle();
        expect(find.byKey(CollectionEntryScreen.goneKey), findsOneWidget);
        expect(find.text('Wingspan'), findsOneWidget);
        expect(find.byKey(CollectionEntryScreen.editKey), findsNothing);
      },
    );

    /// The first read fails, and the screen pushes over it.
    Future<void> pushFailing(WidgetTester tester, ThemeData theme) {
      watch.addError(StateError('the read failed'));
      return push(tester, theme);
    }

    Future<void> expectError(WidgetTester tester) async {
      await tester.pumpAndSettle();
      expect(find.byKey(CollectionEntryScreen.errorKey), findsOneWidget);
      expect(find.byKey(CollectionEntryScreen.retryKey), findsOneWidget);
    }

    auditScreen('error, with retry', pump: pushFailing, arrange: expectError);

    // At 320dp × 2.0 Try again sits on the view's bottom edge, where the
    // tap-target check skips it (#50).
    auditScreen(
      'error, with retry, scrolled to the end',
      pump: pushFailing,
      arrange: (tester) async {
        await expectError(tester);
        await scrollPageToEnd(tester);
      },
    );

    // Each field's empty value, quiet, and the way to the game's page.
    void expectEveryFieldEmpty() {
      expect(find.byKey(CollectionEntryScreen.gameDetailsKey), findsOneWidget);
      expect(find.text('No rating'), findsOneWidget);
      expect(find.text('No comment'), findsOneWidget);
    }

    void expectEveryFieldSet() {
      expect(find.text('Would play again'), findsOneWidget);
      expect(find.text('Best with five.'), findsOneWidget);
    }

    auditScreen(
      'ready, every field empty, with Game details',
      pump: pushed(item: bareRow(), gameDetails: true),
      arrange: (tester) async => expectEveryFieldEmpty(),
    );

    // At 320dp × 2.0 the page runs 436dp past its view. Audited in a view
    // tall enough to hold it: scrolled to the end, the app bar fails
    // #802 (below).
    auditScreen(
      'ready, every field empty, whole page',
      pump: pushed(item: bareRow(), gameDetails: true),
      arrange: (tester) async {
        expectEveryFieldEmpty();
        await useWholePage(tester);
        expectWholePage(tester);
      },
    );

    // Every field set, where the composition has no catalog to open.
    auditScreen(
      'ready, every field set',
      pump: pushed(),
      arrange: (tester) async {
        expectEveryFieldSet();
        expect(find.byKey(CollectionEntryScreen.gameDetailsKey), findsNothing);
      },
    );

    // Content scrolled under the app bar tints it, and in the light theme
    // Edit and Remove fall below 4.5:1 on the tint.
    auditScreen(
      'ready, scrolled to the end',
      pump: pushed(gameDetails: true),
      skip: 'see #802',
      arrange: (tester) async {
        expectEveryFieldSet();
        await scrollPageToEnd(tester);
        expect(find.text('Best with five.').hitTestable(), findsOneWidget);
      },
    );

    // Until then what runs below the fold at 320dp × 2.0 (689dp) is audited
    // in a view tall enough to hold it, with nothing under the app bar.
    auditScreen(
      'ready, every field set, whole page',
      pump: pushed(gameDetails: true),
      arrange: (tester) async {
        expectEveryFieldSet();
        expect(
          find.byKey(CollectionEntryScreen.gameDetailsKey),
          findsOneWidget,
        );
        await useWholePage(tester);
        expectWholePage(tester);
      },
    );

    // The sheet dismissed by the system's back with its save still out:
    // Edit says so, and both wait.
    auditScreen(
      'saving',
      pump: pushed(),
      arrange: (tester) async {
        await submitHeld(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(sheet, findsNothing);
        expect(
          find.descendant(
            of: find.byKey(CollectionEntryScreen.editKey),
            matching: find.text('Saving…'),
          ),
          findsOneWidget,
        );
      },
    );

    // Remove says so, and Edit and "Game details" wait.
    auditScreen(
      'removing',
      pump: pushed(gameDetails: true),
      arrange: (tester) async {
        holdRemoval();
        await confirmRemove(tester);
        expect(
          find.descendant(
            of: find.byKey(CollectionEntryScreen.removeKey),
            matching: find.text('Removing…'),
          ),
          findsOneWidget,
        );
        expect(blocOf(tester).state.action, CollectionEntryAction.removing);
      },
    );

    // The removal failed: said in a SnackBar, and the screen stays.
    auditScreen(
      'a failed removal',
      pump: pushed(),
      arrange: (tester) async {
        when(() => repository.removeFromCollection('gc_1'))
            .thenThrow(StateError('disposed'));
        await confirmRemove(tester);
        expect(snackBarText(_removeFailedCopy), findsOneWidget);
        expect(find.byKey(CollectionEntryScreen.removeKey), findsOneWidget);
      },
    );

    auditScreen('edit sheet open', pump: pushed(), arrange: openSheet);

    auditScreen(
      'edit sheet open, whole page',
      pump: pushed(),
      arrange: (tester) => openWhole(tester, sheet, openSheet),
    );

    auditScreen(
      'edit sheet, a rejected submit, whole page',
      pump: pushed(),
      arrange: (tester) => openWhole(tester, sheet, submitInvalid),
    );

    auditScreen(
      'edit sheet, save failed, whole page',
      pump: pushed(),
      arrange: (tester) => openWhole(tester, sheet, submitFailing),
    );

    final ratingItem = find.widgetWithText(MenuItemButton, '1 out of 10');

    /// Opens the sheet and its rating menu. Over [bareRow], unrated, the
    /// menu offers "No rating" beside 1 to 10.
    Future<void> openRatingMenu(WidgetTester tester) async {
      await openSheet(tester);
      await tapInView(tester, find.byKey(EditCollectionEntrySheet.ratingKey));
      expect(find.widgetWithText(MenuItemButton, 'No rating'), findsOneWidget);
      expect(ratingItem, findsOneWidget);
    }

    auditScreen(
      'edit sheet, rating menu open',
      pump: pushed(item: bareRow()),
      arrange: openRatingMenu,
    );

    // At 320dp × 2.0 the menu runs 68dp past its own fold, so "10 out of 10"
    // is in no view. Scrolled to its end, "No rating" is left a sliver high
    // under the menu's top edge, where the tap-target check measures it at
    // its clipped size, so the menu is audited whole instead (#50).
    auditScreen(
      'edit sheet, rating menu open, whole page',
      pump: pushed(item: bareRow()),
      arrange: (tester) async {
        await useWholePage(tester);
        expectWholePage(tester);
        await openRatingMenu(tester);
        // The menu's own scroll, round its items.
        expectWholePage(
          tester,
          within: find
              .ancestor(of: ratingItem, matching: find.byType(Scrollable))
              .first,
        );
        expect(find.text('10 out of 10').hitTestable(), findsOneWidget);
      },
    );

    // The submit spins while the save is out.
    auditScreen(
      'edit sheet, saving, whole page',
      pump: pushed(),
      settle: false,
      arrange: (tester) async {
        await useWholePage(tester);
        expectWholePage(tester);
        await submitHeld(tester);
        expectWholePage(tester, within: sheet);
      },
    );

    auditScreen('remove dialog open', pump: pushed(), arrange: openDialog);

    auditScreen(
      'remove dialog open, whole page',
      pump: pushed(),
      arrange: (tester) => openWhole(tester, dialog, openDialog),
    );
  });
}
