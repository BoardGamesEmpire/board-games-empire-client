import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

const _queuedOp = AddToCollectionOperation(
  localId: 'gc_1',
  platformGameId: 'pg_1',
  medium: 'Physical',
  quantity: 1,
);

const _openKey = Key('test.open_sheet');
const _homeKey = Key('test.home');
const _heading = 'Add Wingspan';
const _mediumRequired = 'Choose physical or digital.';
const _platformRequired = 'Choose a platform.';
const Set<GameMedium> _both = {GameMedium.physical, GameMedium.digital};
const _quantityInvalid = 'Enter a whole number, 1 or more.';
const _quantityTooMany = "That's more copies than can be stored.";
const _failedTitle = "Couldn't add the game";

/// The largest quantity the server's `Int` column holds.
const _storedMax = 2147483647;

void main() {
  late _MockGameCollectionRepository repository;
  late _MockSyncOperationSender sender;

  /// What the sheet resolved to, once it has.
  late CollectionSync? result;
  late bool resolved;

  final wingspan = Game(
    id: 'g_wingspan',
    title: 'Wingspan',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  PlatformGame platformGame(String id, String name, PlatformType? type) =>
      PlatformGame(
        id: id,
        gameId: 'g_wingspan',
        platformId: 'plat_$id',
        platformName: name,
        platformType: type,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

  // No type stored, so the medium starts on nothing and the user picks.
  final onSwitch = platformGame('pg_1', 'Switch', null);
  final onTabletop = platformGame(
    'pg_tabletop',
    'Tabletop',
    PlatformType.tabletop,
  );
  final onSteam = platformGame('pg_steam', 'Steam', PlatformType.pc);

  CollectionAddOption option(
    PlatformGame platformGame, [
    Set<GameMedium> free = _both,
  ]) => CollectionAddOption(platformGame: platformGame, freeMediums: free);

  GameCollection entry({
    String platformGameId = 'pg_1',
    GameMedium medium = GameMedium.physical,
    int quantity = 1,
  }) => GameCollection(
    id: 'gc_1',
    userId: 'user-a',
    platformGameId: platformGameId,
    medium: medium,
    quantity: quantity,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  setUpAll(() {
    registerFallbackValue(GameMedium.physical);
    registerFallbackValue(_queuedOp);
  });

  setUp(() {
    repository = _MockGameCollectionRepository();
    sender = _MockSyncOperationSender();
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncDelivered());
    result = null;
    resolved = false;
    when(
      () => repository.getCollectionEntry(
        platformGameId: any(named: 'platformGameId'),
        medium: any(named: 'medium'),
      ),
    ).thenAnswer((_) async => null);
    when(
      () => repository.addToCollection(
        platformGameId: any(named: 'platformGameId'),
        medium: any(named: 'medium'),
        quantity: any(named: 'quantity'),
        rating: any(named: 'rating'),
        comment: any(named: 'comment'),
      ),
    ).thenAnswer(
      (_) async => (entry: entry(), syncQueueId: 'sq_1', operation: _queuedOp),
    );
  });

  void owning(
    GameMedium medium,
    int quantity, {
    String platformGameId = 'pg_1',
  }) =>
      when(
        () => repository.getCollectionEntry(
          platformGameId: platformGameId,
          medium: medium,
        ),
      ).thenAnswer(
        (_) async => entry(
          platformGameId: platformGameId,
          medium: medium,
          quantity: quantity,
        ),
      );

  void verifyNoAdd() => verifyNever(
    () => repository.addToCollection(
      platformGameId: any(named: 'platformGameId'),
      medium: any(named: 'medium'),
      quantity: any(named: 'quantity'),
      rating: any(named: 'rating'),
      comment: any(named: 'comment'),
    ),
  );

  /// A screen with a button that opens the sheet on [options], Switch alone
  /// unless given, with [platformGameId] chosen.
  ///
  /// With [pushed], that screen is pushed over a home screen, so a pop the
  /// sheet doesn't own shows as that screen gone.
  Future<void> open(
    WidgetTester tester, {
    List<CollectionAddOption>? options,
    String? platformGameId,
    TextScaler textScaler = TextScaler.noScaling,
    bool pushed = false,
  }) async {
    final opener = Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: _openKey,
          onPressed: () async {
            result = await showAddToCollectionSheet(
              context,
              repository: repository,
              sender: sender,
              game: wingspan,
              options: options ?? [option(onSwitch)],
              platformGameId: platformGameId,
            );
            resolved = true;
          },
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
        home: pushed
            ? Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    key: _homeKey,
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => opener)),
                    child: const Text('Home'),
                  ),
                ),
              )
            : opener,
      ),
    );
    if (pushed) {
      await tester.tap(find.byKey(_homeKey));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
  }

  /// Brings [finder] into view, then taps it.
  Future<void> tapInView(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Opens the dropdown under [field] and picks [label] from its menu.
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
      tapInView(tester, find.byKey(AddToCollectionSheet.submitKey));

  /// [text] drawn in the closed field keyed [field].
  Finder shows(Key field, String text) =>
      find.descendant(of: find.byKey(field), matching: find.text(text));

  /// [label] offered in the open menu.
  Finder offered(String label) => find.descendant(
    of: find.byType(MenuItemButton),
    matching: find.text(label),
  );

  Future<void> dismiss(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  void verifyAdded(String platformGameId, GameMedium medium) => verify(
    () => repository.addToCollection(
      platformGameId: platformGameId,
      medium: medium,
    ),
  ).called(1);

  testWidgets('the field reads Medium and the title names the game only', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester);

    expect(find.text(_heading), findsOneWidget);
    expect(find.text('Add Wingspan (Switch)'), findsNothing);
    expect(
      find.semantics.byLabel(_heading).evaluate().single,
      isSemantics(isHeader: true),
    );
    expect(shows(AddToCollectionSheet.platformKey, 'Platform'), findsOneWidget);
    expect(shows(AddToCollectionSheet.mediumKey, 'Medium'), findsOneWidget);
    expect(find.text('Physical or digital'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the platform field lists the options; one option is '
      'preselected', (tester) async {
    await open(tester, options: [option(onTabletop), option(onSteam)]);

    // Two to choose from, and neither chosen for the user: the field reads
    // as an empty medium field does.
    expect(
      shows(AddToCollectionSheet.platformKey, 'Choose one'),
      findsOneWidget,
    );
    expect(shows(AddToCollectionSheet.platformKey, 'Tabletop'), findsNothing);
    expect(shows(AddToCollectionSheet.platformKey, 'Steam'), findsNothing);
    await tapInView(tester, find.byKey(AddToCollectionSheet.platformKey));
    expect(offered('Tabletop'), findsOneWidget);
    expect(offered('Steam'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await dismiss(tester);

    await open(tester, options: [option(onSteam)]);

    expect(shows(AddToCollectionSheet.platformKey, 'Steam'), findsOneWidget);
    await submit(tester);
    verifyAdded('pg_steam', GameMedium.digital);
  });

  testWidgets('submitting with no platform chosen adds nothing and says why', (
    tester,
  ) async {
    await open(tester, options: [option(onTabletop), option(onSteam)]);

    // With no platform there are no mediums to offer yet.
    await tapInView(tester, find.byKey(AddToCollectionSheet.mediumKey));
    expect(find.byType(MenuItemButton), findsNothing);

    await submit(tester);

    expect(find.text(_platformRequired), findsOneWidget);
    expect(find.text(_mediumRequired), findsOneWidget);
    verifyNoAdd();
  });

  // Read-only, never disabled or hidden (STYLE_GUIDE §4): a keyboard or
  // screen-reader user finds the field in its place before it has anything
  // to offer, and no menu opens empty.
  testWidgets('before a platform is chosen, the medium field shows, '
      'read-only and focusable, and opens no menu', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester, options: [option(onTabletop), option(onSteam)]);

    final field = find.byKey(AddToCollectionSheet.mediumKey);
    expect(shows(AddToCollectionSheet.mediumKey, 'Choose one'), findsOneWidget);
    expect(
      tester
          .widget<InputDecorator>(
            find.descendant(of: field, matching: find.byType(InputDecorator)),
          )
          .decoration
          .enabled,
      isTrue,
    );
    expect(
      find.semantics.byLabel(RegExp('^Medium')).evaluate().single,
      isSemantics(
        isButton: true,
        isReadOnly: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: false,
      ),
    );

    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field, warnIfMissed: false);
    await tester.pumpAndSettle();

    final menu = tester.widget<MenuAnchor>(
      find.descendant(of: field, matching: find.byType(MenuAnchor)),
    );
    expect(menu.controller!.isOpen, isFalse);
    expect(
      find.descendant(of: field, matching: find.byIcon(Icons.arrow_drop_up)),
      findsNothing,
    );
    semantics.dispose();
  });

  testWidgets('a preselected platform from a chip is chosen', (tester) async {
    await open(
      tester,
      options: [option(onTabletop), option(onSteam)],
      platformGameId: 'pg_steam',
    );

    expect(shows(AddToCollectionSheet.platformKey, 'Steam'), findsOneWidget);
    expect(shows(AddToCollectionSheet.mediumKey, 'Digital'), findsOneWidget);
    await submit(tester);
    verifyAdded('pg_steam', GameMedium.digital);
  });

  testWidgets('the medium field lists only the free mediums', (tester) async {
    await open(
      tester,
      options: [
        option(onTabletop, {GameMedium.digital}),
      ],
    );

    // Tabletop would start on Physical, which is owned already.
    expect(shows(AddToCollectionSheet.mediumKey, 'Digital'), findsOneWidget);
    await tapInView(tester, find.byKey(AddToCollectionSheet.mediumKey));
    expect(offered('Digital'), findsOneWidget);
    expect(offered('Physical'), findsNothing);
  });

  testWidgets('Tabletop starts on Physical, Steam on Digital, an untyped '
      'platform on nothing', (tester) async {
    for (final (platform, start) in [
      (onTabletop, 'Physical'),
      (onSteam, 'Digital'),
      (onSwitch, 'Choose one'),
    ]) {
      await open(tester, options: [option(platform)]);
      expect(
        shows(AddToCollectionSheet.mediumKey, start),
        findsOneWidget,
        reason: platform.platformName,
      );
      await dismiss(tester);
    }

    // The bloc is told each start, so a note can follow it.
    verify(
      () => repository.getCollectionEntry(
        platformGameId: 'pg_tabletop',
        medium: GameMedium.physical,
      ),
    ).called(1);
    verify(
      () => repository.getCollectionEntry(
        platformGameId: 'pg_steam',
        medium: GameMedium.digital,
      ),
    ).called(1);
    verifyNever(
      () => repository.getCollectionEntry(
        platformGameId: 'pg_1',
        medium: any(named: 'medium'),
      ),
    );
  });

  testWidgets('the user can change the starting medium', (tester) async {
    await open(tester, options: [option(onTabletop)]);
    expect(shows(AddToCollectionSheet.mediumKey, 'Physical'), findsOneWidget);

    // A board game bought as an app.
    await pick(tester, AddToCollectionSheet.mediumKey, 'Digital');

    expect(shows(AddToCollectionSheet.mediumKey, 'Digital'), findsOneWidget);
    await submit(tester);
    verifyAdded('pg_tabletop', GameMedium.digital);
  });

  testWidgets('platform change re-applies the start unless the user picked a '
      'medium', (tester) async {
    await open(
      tester,
      options: [option(onTabletop), option(onSteam), option(onSwitch)],
    );

    await pick(tester, AddToCollectionSheet.platformKey, 'Tabletop');
    expect(shows(AddToCollectionSheet.mediumKey, 'Physical'), findsOneWidget);
    // The sheet chose Physical, not the user, so Steam's start applies.
    await pick(tester, AddToCollectionSheet.platformKey, 'Steam');
    expect(shows(AddToCollectionSheet.mediumKey, 'Digital'), findsOneWidget);

    // A Steam game bought on a disc.
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    // Switch would start on nothing and Steam on Digital: the pick stands.
    await pick(tester, AddToCollectionSheet.platformKey, 'Switch');
    expect(shows(AddToCollectionSheet.mediumKey, 'Physical'), findsOneWidget);
    await pick(tester, AddToCollectionSheet.platformKey, 'Steam');
    expect(shows(AddToCollectionSheet.mediumKey, 'Physical'), findsOneWidget);

    await submit(tester);
    verifyAdded('pg_steam', GameMedium.physical);
  });

  testWidgets('platform change drops a medium the new platform has no room '
      'for', (tester) async {
    await open(
      tester,
      options: [
        option(onTabletop),
        option(onSteam, {GameMedium.digital}),
      ],
      platformGameId: 'pg_tabletop',
    );
    // Picked by the user, not left at the start.
    await pick(tester, AddToCollectionSheet.mediumKey, 'Digital');
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');

    await pick(tester, AddToCollectionSheet.platformKey, 'Steam');

    expect(shows(AddToCollectionSheet.mediumKey, 'Digital'), findsOneWidget);
    expect(shows(AddToCollectionSheet.mediumKey, 'Choose one'), findsNothing);
    // What the field shows is what is sent.
    await submit(tester);
    verifyAdded('pg_steam', GameMedium.digital);
  });

  testWidgets('a medium the sheet had to change is no longer kept as the '
      "user's pick", (tester) async {
    await open(
      tester,
      options: [
        option(onTabletop),
        option(onSteam, {GameMedium.digital}),
      ],
      platformGameId: 'pg_tabletop',
    );
    await pick(tester, AddToCollectionSheet.mediumKey, 'Digital');
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await pick(tester, AddToCollectionSheet.platformKey, 'Steam');

    // Digital was Steam's only room, not the user's choice, so Tabletop
    // starts again.
    await pick(tester, AddToCollectionSheet.platformKey, 'Tabletop');

    expect(shows(AddToCollectionSheet.mediumKey, 'Physical'), findsOneWidget);
  });

  testWidgets('a medium owned after opening shows the existing note', (
    tester,
  ) async {
    // Free when the detail page looked, owned by the time the sheet asks.
    owning(GameMedium.physical, 1, platformGameId: 'pg_tabletop');
    await open(tester, options: [option(onTabletop)]);

    expect(find.byKey(AddToCollectionSheet.existingKey), findsOneWidget);
    expect(
      find.text('You have 1 physical copy. Adding 1 makes 2.'),
      findsOneWidget,
    );
  });

  testWidgets('submitting with no medium chosen adds nothing and says why', (
    tester,
  ) async {
    await open(tester);

    await submit(tester);

    expect(find.text(_mediumRequired), findsOneWidget);
    verifyNoAdd();
    expect(find.byKey(AddToCollectionSheet.sheetKey), findsOneWidget);
  });

  testWidgets('adds one physical copy, closes, and says so', (tester) async {
    await open(tester);

    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await submit(tester);

    verify(
      () => repository.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
      ),
    ).called(1);
    expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
    expect(find.text('Added Wingspan to your collection.'), findsOneWidget);
    expect(resolved, isTrue);
    expect(result, CollectionSync.synced);
  });

  for (final (outcome, answer, said, sync)
      in <(String, SyncDelivery, String, CollectionSync)>[
        (
          'not sent yet',
          const SyncFailed(SyncFailure.unreachable, 'offline'),
          "Added Wingspan to your collection on this device. It hasn't "
              'reached the server yet.',
          CollectionSync.queued,
        ),
        (
          'refused by the server',
          const SyncParked('400'),
          "The server didn't accept Wingspan. It's saved on this device: "
              'review it from the home screen to try again or discard it.',
          CollectionSync.refused,
        ),
      ]) {
    testWidgets('an add $outcome still closes, and says so', (tester) async {
      when(() => sender.deliver(any(), any())).thenAnswer((_) async => answer);
      await open(tester);

      await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
      await submit(tester);

      verify(() => sender.deliver('sq_1', _queuedOp)).called(1);
      expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
      expect(find.text(said), findsOneWidget);
      expect(result, sync);
    });
  }

  testWidgets('a sheet dismissed while its add is sent still says what became '
      'of it', (tester) async {
    final send = Completer<SyncDelivery>();
    when(() => sender.deliver(any(), any())).thenAnswer((_) => send.future);
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    // The submit button's progress indicator never settles while it sends.
    await tester.ensureVisible(find.byKey(AddToCollectionSheet.submitKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(AddToCollectionSheet.submitKey));
    await tester.pump();
    verify(() => sender.deliver('sq_1', _queuedOp)).called(1);
    expect(find.byKey(AddToCollectionSheet.sheetKey), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
    expect(resolved, isFalse);

    send.complete(const SyncFailed(SyncFailure.unreachable, 'timed out'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Added Wingspan to your collection on this device. It hasn't reached "
        'the server yet.',
      ),
      findsOneWidget,
    );
    expect(resolved, isTrue);
    expect(result, CollectionSync.queued);
  });

  testWidgets('an add that lands while a dismissed sheet is still leaving '
      'pops nothing else', (tester) async {
    final send = Completer<SyncDelivery>();
    when(() => sender.deliver(any(), any())).thenAnswer((_) => send.future);
    await open(tester, pushed: true);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await tester.ensureVisible(find.byKey(AddToCollectionSheet.submitKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(AddToCollectionSheet.submitKey));
    await tester.pump();
    verify(() => sender.deliver('sq_1', _queuedOp)).called(1);

    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // Still on its way out, and still listening.
    expect(find.byKey(AddToCollectionSheet.sheetKey), findsOneWidget);

    send.complete(const SyncDelivered());
    await tester.pumpAndSettle();

    expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
    expect(find.byKey(_openKey), findsOneWidget);
    expect(find.text('Added Wingspan to your collection.'), findsOneWidget);
    expect(result, CollectionSync.synced);
  });

  testWidgets('a sheet dismissed while its add is written says so when the '
      'write fails', (tester) async {
    final write =
        Completer<
          ({
            GameCollection entry,
            String syncQueueId,
            AddToCollectionOperation operation,
          })
        >();
    when(
      () => repository.addToCollection(
        platformGameId: any(named: 'platformGameId'),
        medium: any(named: 'medium'),
        quantity: any(named: 'quantity'),
        rating: any(named: 'rating'),
        comment: any(named: 'comment'),
      ),
    ).thenAnswer((_) => write.future);
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await tester.ensureVisible(find.byKey(AddToCollectionSheet.submitKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(AddToCollectionSheet.submitKey));
    await tester.pump();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
    expect(resolved, isFalse);

    write.completeError(StateError('disposed'));
    await tester.pumpAndSettle();

    expect(
      find.text("Couldn't add Wingspan to your collection."),
      findsOneWidget,
    );
    expect(resolved, isTrue);
    expect(result, isNull);
    verifyNever(() => sender.deliver(any(), any()));
  });

  testWidgets('a sheet dismissed after its failure was shown says nothing '
      'more', (tester) async {
    when(
      () => repository.addToCollection(
        platformGameId: any(named: 'platformGameId'),
        medium: any(named: 'medium'),
        quantity: any(named: 'quantity'),
        rating: any(named: 'rating'),
        comment: any(named: 'comment'),
      ),
    ).thenAnswer((_) async => throw StateError('disposed'));
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await submit(tester);
    expect(find.text(_failedTitle), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(resolved, isTrue);
    expect(result, isNull);
  });

  testWidgets('closed without an add resolves to nothing', (tester) async {
    await open(tester);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
    expect(resolved, isTrue);
    expect(result, isNull);
    verifyNoAdd();
  });

  for (final (typed, ok) in [
    ('0', false),
    ('-1', false),
    ('1.5', false),
    ('abc', false),
    ('', false),
    (' 2 ', true),
    ('2147483648', false),
  ]) {
    testWidgets('copies "$typed" ${ok ? 'adds' : 'is refused'}', (
      tester,
    ) async {
      await open(tester);
      await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');

      await type(tester, AddToCollectionSheet.quantityKey, typed);
      await submit(tester);

      if (ok) {
        verify(
          () => repository.addToCollection(
            platformGameId: 'pg_1',
            medium: GameMedium.physical,
            quantity: 2,
          ),
        ).called(1);
      } else {
        verifyNoAdd();
        expect(
          find.text(
            typed == '2147483648' ? _quantityTooMany : _quantityInvalid,
          ),
          findsOneWidget,
        );
        expect(find.byKey(AddToCollectionSheet.sheetKey), findsOneWidget);
      }
    });
  }

  testWidgets('copies over the stored limit with what is already there are '
      'refused', (tester) async {
    owning(GameMedium.physical, _storedMax - 7);
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');

    await type(tester, AddToCollectionSheet.quantityKey, '10');
    await submit(tester);

    expect(find.text(_quantityTooMany), findsOneWidget);
    verifyNoAdd();

    await type(tester, AddToCollectionSheet.quantityKey, '7');
    await submit(tester);

    verify(
      () => repository.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        quantity: 7,
      ),
    ).called(1);
  });

  testWidgets('copies typed before the medium is chosen are checked against '
      'what is already there once it is found', (tester) async {
    owning(GameMedium.physical, _storedMax - 7);
    await open(tester);
    await type(tester, AddToCollectionSheet.quantityKey, '10');

    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await submit(tester);

    expect(find.text(_quantityTooMany), findsOneWidget);
    verifyNoAdd();
  });

  /// What the copies field holds.
  String copiesText(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byKey(AddToCollectionSheet.quantityKey),
          matching: find.byType(TextField),
        ),
      )
      .controller!
      .text;

  Future<void> decrease(WidgetTester tester) =>
      tapInView(tester, find.byKey(AddToCollectionSheet.quantityDecreaseKey));

  Future<void> increase(WidgetTester tester) =>
      tapInView(tester, find.byKey(AddToCollectionSheet.quantityIncreaseKey));

  testWidgets('plus and minus step the copies, which start at 1', (
    tester,
  ) async {
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    expect(copiesText(tester), '1');

    await increase(tester);
    await increase(tester);
    await increase(tester);
    expect(copiesText(tester), '4');

    await decrease(tester);
    expect(copiesText(tester), '3');

    await submit(tester);
    verify(
      () => repository.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        quantity: 3,
      ),
    ).called(1);
  });

  testWidgets('minus stops at 1', (tester) async {
    await open(tester);

    await decrease(tester);
    expect(copiesText(tester), '1');

    await type(tester, AddToCollectionSheet.quantityKey, '2');
    await decrease(tester);
    await decrease(tester);
    expect(copiesText(tester), '1');
  });

  testWidgets('minus does nothing to copies that are not a number, and plus '
      'makes them 1', (tester) async {
    await open(tester);
    await type(tester, AddToCollectionSheet.quantityKey, '-4');

    await decrease(tester);
    expect(copiesText(tester), '-4');

    await increase(tester);
    expect(copiesText(tester), '1');
    expect(find.text(_quantityInvalid), findsNothing);
  });

  testWidgets('plus stops where the total reaches what can be stored', (
    tester,
  ) async {
    owning(GameMedium.physical, _storedMax - 2);
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');

    await increase(tester);
    await increase(tester);
    expect(copiesText(tester), '2');
    expect(find.text(_quantityTooMany), findsNothing);
  });

  testWidgets('plus does nothing to copies that are not a number when no '
      'more can be stored', (tester) async {
    owning(GameMedium.physical, _storedMax);
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await type(tester, AddToCollectionSheet.quantityKey, '');

    await increase(tester);

    expect(copiesText(tester), '');
    expect(find.text(_quantityTooMany), findsNothing);
  });

  testWidgets('a step button at its limit keeps the focus and reads as '
      'disabled', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    await type(tester, AddToCollectionSheet.quantityKey, '2');

    final minus = find.byKey(AddToCollectionSheet.quantityDecreaseKey);
    final button = find.descendant(
      of: minus,
      matching: find.byType(IconButton),
    );
    expect(
      tester.getSemantics(minus),
      isSemantics(
        label: 'One fewer copy',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    Focus.of(tester.element(find.byIcon(Icons.remove))).requestFocus();
    await tester.pump();
    await decrease(tester);
    expect(copiesText(tester), '1');

    expect(
      Focus.of(tester.element(find.byIcon(Icons.remove))).hasFocus,
      isTrue,
    );
    expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    expect(
      tester.getSemantics(minus),
      isSemantics(
        label: 'One fewer copy',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(AddToCollectionSheet.quantityIncreaseKey)),
      isSemantics(label: 'One more copy', isEnabled: true, hasTapAction: true),
    );
    semantics.dispose();
  });

  testWidgets('a step tells a screen reader the copies now in the field', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester);

    await increase(tester);
    expect(
      find.semantics.byLabel('2 copies').evaluate().single,
      isSemantics(isLiveRegion: true),
    );

    await decrease(tester);
    expect(
      find.semantics.byLabel('1 copy').evaluate().single,
      isSemantics(isLiveRegion: true),
    );

    // Typed copies are the field's to read, not the region's.
    await type(tester, AddToCollectionSheet.quantityKey, '5');
    expect(find.semantics.byLabel('5 copies'), findsNothing);
    expect(find.semantics.byLabel('1 copy'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a medium already owned says what the add makes', (tester) async {
    final semantics = tester.ensureSemantics();
    owning(GameMedium.physical, 2);
    await open(tester);

    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    expect(
      find.text('You have 2 physical copies. Adding 1 makes 3.'),
      findsOneWidget,
    );

    await type(tester, AddToCollectionSheet.quantityKey, '3');
    const note = 'You have 2 physical copies. Adding 3 makes 5.';
    expect(find.text(note), findsOneWidget);
    expect(
      find.semantics.byLabel(note).evaluate().single,
      isSemantics(isLiveRegion: true),
    );

    // What the add makes needs a number to add.
    await type(tester, AddToCollectionSheet.quantityKey, 'abc');
    expect(find.text('You have 2 physical copies.'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a medium not owned says nothing, and switching to it drops '
      'the note', (tester) async {
    owning(GameMedium.physical, 1);
    await open(tester);

    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    expect(find.byKey(AddToCollectionSheet.existingKey), findsOneWidget);
    expect(
      find.text('You have 1 physical copy. Adding 1 makes 2.'),
      findsOneWidget,
    );

    await pick(tester, AddToCollectionSheet.mediumKey, 'Digital');
    expect(find.byKey(AddToCollectionSheet.existingKey), findsNothing);
  });

  testWidgets('a rating and a trimmed comment are sent', (tester) async {
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');

    await pick(tester, AddToCollectionSheet.ratingKey, '7 out of 10');
    await type(tester, AddToCollectionSheet.commentKey, ' Great ');
    await submit(tester);

    verify(
      () => repository.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        rating: 7,
        comment: 'Great',
      ),
    ).called(1);
  });

  testWidgets('No rating and a comment of only spaces are left out, so an '
      'entry added again keeps its old ones', (tester) async {
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');

    await pick(tester, AddToCollectionSheet.ratingKey, '7 out of 10');
    await pick(tester, AddToCollectionSheet.ratingKey, 'No rating');
    await type(tester, AddToCollectionSheet.commentKey, '   ');
    await submit(tester);

    // Omitted named arguments are verified as null.
    verify(
      () => repository.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
      ),
    ).called(1);
  });

  testWidgets('a failed add keeps the sheet and what was typed', (
    tester,
  ) async {
    when(
      () => repository.addToCollection(
        platformGameId: any(named: 'platformGameId'),
        medium: any(named: 'medium'),
        quantity: any(named: 'quantity'),
        rating: any(named: 'rating'),
        comment: any(named: 'comment'),
      ),
    ).thenAnswer((_) async => throw StateError('disposed'));
    await open(tester);
    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await type(tester, AddToCollectionSheet.commentKey, 'Great');

    await submit(tester);

    expect(find.text(_failedTitle), findsOneWidget);
    expect(find.byKey(AddToCollectionSheet.sheetKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(AddToCollectionSheet.commentKey),
        matching: find.text('Great'),
      ),
      findsOneWidget,
    );
    expect(resolved, isFalse);

    // Editing retires the failure: it was about what was there before.
    await type(tester, AddToCollectionSheet.commentKey, 'Great game');
    expect(find.text(_failedTitle), findsNothing);
  });

  testWidgets('the comment field ends above the keyboard', (tester) async {
    useViewSize(tester, const Size(400, 800));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await open(tester);

    final comment = find.byKey(AddToCollectionSheet.commentKey);
    await tester.showKeyboard(comment);
    await tester.pumpAndSettle();

    expect(tester.getRect(comment).bottom, lessThanOrEqualTo(800 - 300));
  });

  testWidgets('lays out at 320dp and 2x text', (tester) async {
    useViewSize(tester, const Size(320, 640));
    owning(GameMedium.physical, 2);
    await open(tester, textScaler: const TextScaler.linear(2));

    await pick(tester, AddToCollectionSheet.mediumKey, 'Physical');
    await pick(tester, AddToCollectionSheet.ratingKey, '10 out of 10');

    expect(tester.takeException(), isNull);
    expect(find.text(_heading), findsOneWidget);
    expect(
      find.text('You have 2 physical copies. Adding 1 makes 3.'),
      findsOneWidget,
    );
    expect(find.text('10 out of 10'), findsOneWidget);
  });
}
