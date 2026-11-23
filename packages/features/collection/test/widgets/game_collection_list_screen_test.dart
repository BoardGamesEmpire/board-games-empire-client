import 'dart:async';
import 'dart:io';

import 'package:bge_test_support/images.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_bloc/flutter_bloc.dart';
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

/// An image host that has not answered yet: no headers, no bytes.
class _UnansweredHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      Completer<HttpClientRequest>().future;
}

const _emptyTitleCopy = 'No games yet';
const _refreshFailedCopy =
    "This list may be out of date — we couldn't refresh it.";
const _errorCopy = "We couldn't open your collection.";
const _retryCopy = 'Try again';
const _refreshingCopy = 'Refreshing…';
const _refreshCopy = 'Refresh';

/// The surfaces the list can show (#44, #715), each of which can be
/// refreshed by hand (#717).
enum _Surface { loading, error, empty, noMatches, rows }

/// Pins the #44 list against a mocked repository and a hand-driven
/// hydration stream: the four surfaces, the row, the inert-row
/// rule and the hostable body, the stale-rows banner and its retry,
/// and the entry trigger.
void main() {
  late _MockGameCollectionRepository repository;
  late StreamController<List<GameCollectionListItem>> items;
  late GameCollectionHydrationStatus status;

  setUp(() {
    repository = _MockGameCollectionRepository();
    items = StreamController<List<GameCollectionListItem>>.broadcast();
    status = GameCollectionHydrationStatus();
    when(repository.watchCollectionListItems).thenAnswer((_) => items.stream);
  });

  tearDown(() {
    unawaited(items.close());
    unawaited(status.close());
  });

  /// [home] in [theme], light by default. [textScaler] overrides the
  /// device's text scale only when set.
  Widget app(Widget home, {TextScaler? textScaler, ThemeData? theme}) =>
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        localizationsDelegates: const [
          ...GameCollectionLocalizations.localizationsDelegates,
          GameFiltersLocalizations.delegate,
        ],
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
        home: home,
      );

  Widget harness({
    void Function(BuildContext context, String entryId)? onOpen,
    void Function(BuildContext context)? onBrowse,
    Future<void> Function()? onRetry,
    VoidCallback? onEnter,
    ListLayoutRepository? layouts,
    TextScaler? textScaler,
    ThemeData? theme,
  }) => app(
    GameCollectionListScreen(
      repository: repository,
      hydration: status.watch(),
      onOpen: onOpen,
      onBrowse: onBrowse,
      onRetry: onRetry,
      onEnter: onEnter,
      layouts: layouts,
    ),
    textScaler: textScaler,
    theme: theme,
  );

  /// Shows [rows] with the hydrate settled.
  Future<void> show(
    WidgetTester tester,
    List<GameCollectionListItem> rows, {
    void Function(BuildContext context, String entryId)? onOpen,
    void Function(BuildContext context)? onBrowse,
    ListLayoutRepository? layouts,
  }) async {
    await tester.pumpWidget(
      harness(onOpen: onOpen, onBrowse: onBrowse, layouts: layouts),
    );
    status.finished(CollectionHydrateOutcome.complete);
    items.add(rows);
    await tester.pumpAndSettle();
  }

  /// The merged node of the row [row] finds: the `MergeSemantics` sits inside
  /// the row's outline (#647), below the key.
  SemanticsNode mergedNode(WidgetTester tester, Finder row) =>
      tester.getSemantics(
        find.descendant(of: row, matching: find.byType(MergeSemantics)).first,
      );

  SemanticsNode rowSemantics(WidgetTester tester, String id) => mergedNode(
    tester,
    find.byKey(GameCollectionListScreen.rowKey(id)),
  );

  /// The control at the end of the base game's row [row] finds, which folds
  /// and unfolds its expansions (#1048).
  Finder controlOf(Finder row) => find.descendant(
    of: row,
    matching: find.byType(BgeRowExpansionsControl),
    skipOffstage: false,
  );

  /// Shows the expansions of the base game whose row [row] finds, from its
  /// control: every base game starts folded (#1048).
  Future<void> unfold(WidgetTester tester, Finder row) async {
    await tester.ensureVisible(controlOf(row));
    await tester.pumpAndSettle();
    await tester.tap(controlOf(row));
    await tester.pumpAndSettle();
  }

  group('while the cache is filling', () {
    testWidgets('shows a spinner rather than an empty state', (tester) async {
      await tester.pumpWidget(harness());
      status.started();
      items.add(const []);
      await tester.pump();

      expect(find.byKey(GameCollectionListScreen.loadingKey), findsOneWidget);
      expect(find.text(_emptyTitleCopy), findsNothing);
    });

    testWidgets('shows rows the cache already has', (tester) async {
      await tester.pumpWidget(harness());
      status.started();
      items.add([listItem('e-1')]);
      await tester.pump();

      expect(find.byKey(GameCollectionListScreen.loadingKey), findsNothing);
      expect(find.text('Catan'), findsOneWidget);
    });

    testWidgets('opened mid-pass, an emptiness already confirmed is empty', (
      tester,
    ) async {
      // A pass started elsewhere is running when the list opens. The one
      // before it confirmed there are no games, so this is not a first fill.
      status
        ..started()
        ..finished(CollectionHydrateOutcome.complete)
        ..started();
      await tester.pumpWidget(harness());
      items.add(const []);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(GameCollectionListScreen.emptyKey), findsOneWidget);
      expect(find.byKey(GameCollectionListScreen.loadingKey), findsNothing);
    });
  });

  group('when the collection is empty', () {
    testWidgets('says so once the hydrate settles', (tester) async {
      await show(tester, const []);

      expect(find.byKey(GameCollectionListScreen.emptyKey), findsOneWidget);
      expect(find.text(_emptyTitleCopy), findsOneWidget);
    });

    testWidgets('the empty state is announced', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, const []);

      final title = tester.getSemantics(find.text(_emptyTitleCopy));
      expect(title, isSemantics(isLiveRegion: true));
      expect(title.label, contains(_emptyTitleCopy));
      expect(
        title.label,
        contains('Games you add from the catalog will appear here.'),
      );
      handle.dispose();
    });

    testWidgets('offers browsing, which calls onBrowse', (tester) async {
      var browsed = 0;
      await show(tester, const [], onBrowse: (_) => browsed++);

      expect(
        find.text('Games you add from the catalog will appear here.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(GameCollectionListScreen.browseKey));
      await tester.pump();

      expect(find.text('Browse games'), findsOneWidget);
      expect(browsed, 1);
    });

    testWidgets('with no onBrowse offers nothing to press', (tester) async {
      await show(tester, const []);

      expect(find.byKey(GameCollectionListScreen.browseKey), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(GameCollectionListScreen.emptyKey),
          matching: find.byType(ButtonStyleButton),
        ),
        findsNothing,
      );
      expect(find.byType(FloatingActionButton), findsNothing);
    });
  });

  group('with games', () {
    testWidgets('renders one row per entry, in the order given', (
      tester,
    ) async {
      // The repository orders. A screen that re-sorted would be a second,
      // invisible ordering rule.
      await show(tester, [
        listItem('e-1', title: 'Azul'),
        listItem('e-2', title: 'zendo'),
      ]);

      expect(
        find.byKey(GameCollectionListScreen.rowKey('e-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(GameCollectionListScreen.rowKey('e-2')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('Azul')).dy,
        lessThan(tester.getTopLeft(find.text('zendo')).dy),
      );
    });

    testWidgets('tells a screen reader how many rows there are', (
      tester,
    ) async {
      // CustomScrollView does not assert this, so nothing else would catch
      // it going missing (#210).
      await show(tester, [listItem('e-1'), listItem('e-2'), listItem('e-3')]);

      final scrollable = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(scrollable.semanticChildCount, 3);
    });

    testWidgets('follows the cache as it changes', (tester) async {
      // A hydrate page, an add on another device, a removal: each arrives
      // as a new list on the same stream, with no pass to wait for.
      await show(tester, [listItem('e-1', title: 'Azul')]);

      items.add([
        listItem('e-1', title: 'Azul'),
        listItem('e-2', title: 'Brass'),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.text('Brass'), findsOneWidget);

      items.add([listItem('e-2', title: 'Brass')]);
      await tester.pump();
      await tester.pump();
      expect(find.text('Azul'), findsNothing);
      expect(find.text('Brass'), findsOneWidget);
    });

    testWidgets('a row keeps its focus when a row above it leaves', (
      tester,
    ) async {
      // A hydrate removes an entry deleted elsewhere, or a discard on the
      // stuck-changes screen deletes a local-only one (#549). Only a row
      // that opens somewhere is a focus stop, so this one is given somewhere
      // to go.
      await show(tester, [
        listItem('e-1', title: 'Azul'),
        listItem('e-2', title: 'Brass'),
      ], onOpen: (_, _) {});
      FocusNode focusOf(String entryId, String title) => Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(GameCollectionListScreen.rowKey(entryId)),
            matching: find.text(title),
          ),
        ),
      );
      focusOf('e-2', 'Brass').requestFocus();
      await tester.pump();
      expect(focusOf('e-2', 'Brass').hasPrimaryFocus, isTrue);

      items.add([listItem('e-2', title: 'Brass')]);
      await tester.pumpAndSettle();

      expect(find.text('Azul'), findsNothing);
      expect(focusOf('e-2', 'Brass').hasPrimaryFocus, isTrue);
    });

    testWidgets('surfaces a failed cache read as an error', (tester) async {
      await tester.pumpWidget(harness());
      items.addError(StateError('no authenticated user'));
      await tester.pump();

      expect(find.byKey(GameCollectionListScreen.errorKey), findsOneWidget);
      expect(find.text(_errorCopy), findsOneWidget);
    });
  });

  testWidgets('every game row is outlined (#647)', (tester) async {
    await show(tester, [
      listItem('e-1', title: 'Azul'),
      listItem('e-2', title: 'Zendo'),
    ]);

    expect(find.byType(BgeOutlinedRow), findsNWidgets(2));
    for (final id in ['e-1', 'e-2']) {
      expect(
        find.descendant(
          of: find.byKey(GameCollectionListScreen.rowKey(id)),
          matching: find.byType(BgeOutlinedRow),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('a row sets its thumbnail by text scale (#647)', (tester) async {
    Future<ListTileTitleAlignment?> alignmentAt(double scale) async {
      await tester.pumpWidget(harness(textScaler: TextScaler.linear(scale)));
      status.finished(CollectionHydrateOutcome.complete);
      items.add([listItem('e-1', title: 'Azul')]);
      await tester.pumpAndSettle();
      return tester
          .widget<ListTile>(
            find.descendant(
              of: find.byKey(GameCollectionListScreen.rowKey('e-1')),
              matching: find.byType(ListTile),
            ),
          )
          .titleAlignment;
    }

    expect(await alignmentAt(1), ListTileTitleAlignment.top);
    expect(await alignmentAt(2), ListTileTitleAlignment.titleHeight);
  });

  group('a row (#44)', () {
    testWidgets('shows the title alone when there is no subtitle', (
      tester,
    ) async {
      await show(tester, [listItem('e-1')]);

      expect(find.text('Catan'), findsOneWidget);
    });

    testWidgets('joins the subtitle onto the title line', (tester) async {
      // Rows sort by title alone, so the subtitle is what tells two
      // editions of one game apart.
      await show(tester, [
        listItem('e-1', subtitle: 'Seafarers'),
      ]);

      expect(find.text('Catan: Seafarers'), findsOneWidget);
    });

    testWidgets('always names the platform and the medium', (tester) async {
      // The same game owned in two media is two rows with one title, and
      // these are what tell them apart.
      await show(tester, [
        listItem('e-1', platformName: 'PC', medium: GameMedium.digital),
        listItem('e-2'),
      ]);

      expect(find.textContaining('PC · Digital'), findsOneWidget);
      expect(find.textContaining('Board game · Physical'), findsOneWidget);
    });

    testWidgets('shows the quantity only above one', (tester) async {
      await show(tester, [listItem('e-1', quantity: 3), listItem('e-2')]);

      expect(find.textContaining('3 copies'), findsOneWidget);
      expect(find.textContaining('1 copy'), findsNothing);
    });

    testWidgets('shows a rating out of ten when there is one', (tester) async {
      await show(tester, [listItem('e-1', rating: 7), listItem('e-2')]);

      expect(find.textContaining('7/10'), findsOneWidget);
      expect(find.textContaining('/10'), findsOneWidget);
    });

    testWidgets('reads the rating out in words', (tester) async {
      // "7/10" spoken is "seven slash ten", or a date.
      await show(tester, [listItem('e-1', rating: 7)]);

      expect(rowSemantics(tester, 'e-1').label, contains('Rated 7 out of 10'));
      expect(rowSemantics(tester, 'e-1').label, isNot(contains('7/10')));
    });

    testWidgets('shows when it was last played, when it has been', (
      tester,
    ) async {
      await show(tester, [
        listItem('e-1', lastPlayed: DateTime(2026, 10, 3)),
        listItem('e-2'),
      ]);

      expect(find.textContaining('Last played Oct 3, 2026'), findsOneWidget);
      expect(find.textContaining('Last played'), findsOneWidget);
    });

    testWidgets('marks a favorite with an icon that has a name', (
      tester,
    ) async {
      await show(tester, [
        listItem('e-1', favorite: true),
        listItem('e-2', favorite: false),
        listItem('e-3'),
      ]);

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(rowSemantics(tester, 'e-1').label, contains('Favorite'));
      expect(rowSemantics(tester, 'e-2').label, isNot(contains('Favorite')));
    });

    testWidgets('is one node for a screen reader', (tester) async {
      await show(tester, [
        listItem(
          'e-1',
          quantity: 2,
          favorite: true,
        ),
      ]);

      final label = rowSemantics(tester, 'e-1').label;
      for (final part in [
        'Catan',
        'Board game',
        'Physical',
        '2 copies',
        'Favorite',
      ]) {
        expect(label, contains(part));
      }
    });
  });

  group('a row without somewhere to go (#44)', () {
    testWidgets('is inert content, not a control', (tester) async {
      // A tap that leads nowhere is worse than no tap (#269).
      await show(tester, [listItem('e-1')]);

      expect(
        rowSemantics(tester, 'e-1'),
        isSemantics(isButton: false, hasTapAction: false, isFocusable: false),
      );
    });

    testWidgets('becomes a control once there is somewhere to go', (
      tester,
    ) async {
      final opened = <String>[];
      await show(tester, [
        listItem('e-1'),
        listItem('e-2'),
      ], onOpen: (_, id) => opened.add(id));

      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e-2')));
      await tester.pump();

      expect(opened, ['e-2']);
      expect(rowSemantics(tester, 'e-2'), isSemantics(isButton: true));
    });
  });

  group('the thumbnail (#44)', () {
    Image thumbnailImage(WidgetTester tester, String id) =>
        tester.widget<Image>(
          find.descendant(
            of: find.byKey(GameCollectionListScreen.thumbnailKey(id)),
            matching: find.byType(Image),
          ),
        );

    testWidgets('loads the URL, falling back to an HTML element on web', (
      tester,
    ) async {
      // Measured in a browser for #44: a BoardGameGeek thumbnail sends no
      // CORS header, so the default byte fetch fails on web. The fallback is
      // the narrowest strategy that renders it.
      await show(tester, [
        listItem('e-1', thumbnail: 'https://images.example.com/catan.jpg'),
      ]);

      // Inside the decode-size bound BgeThumbnail puts around it.
      final provider =
          (thumbnailImage(tester, 'e-1').image as ResizeImage).imageProvider
              as NetworkImage;
      expect(provider.url, 'https://images.example.com/catan.jpg');
      expect(provider.webHtmlElementStrategy, WebHtmlElementStrategy.fallback);
    });

    testWidgets('shows a placeholder where there is no thumbnail', (
      tester,
    ) async {
      await show(tester, [listItem('e-1')]);

      expect(
        find.descendant(
          of: find.byKey(GameCollectionListScreen.thumbnailKey('e-1')),
          matching: find.byKey(
            GameCollectionListScreen.thumbnailPlaceholderKey,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the placeholder before the first byte arrives', (
      tester,
    ) async {
      // A request with no response yet has no progress to report, so a
      // placeholder keyed on progress would leave the square blank here.
      debugNetworkImageHttpClientProvider = _UnansweredHttpClient.new;
      try {
        await show(tester, [
          listItem('e-1', thumbnail: 'https://images.example.com/slow.jpg'),
        ]);

        expect(
          find.descendant(
            of: find.byKey(GameCollectionListScreen.thumbnailKey('e-1')),
            matching: find.byKey(
              GameCollectionListScreen.thumbnailPlaceholderKey,
            ),
          ),
          findsOneWidget,
        );
      } finally {
        debugNetworkImageHttpClientProvider = null;
        imageCache.clear();
      }
    });

    testWidgets('shows the image in place of the placeholder once it has one', (
      tester,
    ) async {
      final png = (await tester.runAsync(() => solidPng(1, 1)))!;
      final thumbnail = find.byKey(
        GameCollectionListScreen.thumbnailKey('e-1'),
      );

      await servingImages(png, () async {
        await show(tester, [
          listItem('e-1', thumbnail: 'https://images.example.com/loaded.jpg'),
        ]);
        await pumpUntilDecoded(tester, thumbnail);
      });

      expect(
        find.descendant(
          of: thumbnail,
          matching: find.byKey(
            GameCollectionListScreen.thumbnailPlaceholderKey,
          ),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<RawImage>(
              find.descendant(of: thumbnail, matching: find.byType(RawImage)),
            )
            .image,
        isNotNull,
      );
    });

    testWidgets('shows the placeholder when the image fails to load', (
      tester,
    ) async {
      // The test binding answers every HTTP request with a 400.
      await show(tester, [
        listItem('e-1', thumbnail: 'https://images.example.com/catan.jpg'),
      ]);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(GameCollectionListScreen.thumbnailKey('e-1')),
          matching: find.byKey(
            GameCollectionListScreen.thumbnailPlaceholderKey,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('keeps one size whether or not there is an image', (
      tester,
    ) async {
      await show(tester, [
        listItem('e-1', thumbnail: 'https://images.example.com/catan.jpg'),
        listItem('e-2'),
      ]);

      expect(
        tester.getSize(
          find.byKey(GameCollectionListScreen.thumbnailKey('e-1')),
        ),
        tester.getSize(
          find.byKey(GameCollectionListScreen.thumbnailKey('e-2')),
        ),
      );
    });

    testWidgets('says nothing to a screen reader', (tester) async {
      // Decorative: the title beside it already names the game.
      await show(tester, [
        listItem(
          'e-1',
          thumbnail: 'https://images.example.com/catan.jpg',
        ),
      ]);

      expect(thumbnailImage(tester, 'e-1').excludeFromSemantics, isTrue);
    });
  });

  group('at the largest text scale the app honors', () {
    for (final width in <double>[320, 360, 412]) {
      testWidgets('a full row lays out on a ${width.toInt()}dp window', (
        tester,
      ) async {
        useViewSize(tester, Size(width, 800));
        await tester.pumpWidget(
          harness(
            textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
          ),
        );
        status.finished(CollectionHydrateOutcome.complete);
        items.add([
          listItem(
            'e-1',
            title: 'Twilight Imperium',
            subtitle: 'Fourth Edition',
            quantity: 2,
            rating: 9,
            favorite: true,
            lastPlayed: DateTime(2026, 10, 3),
          ),
        ]);
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.textContaining('Last played'), findsOneWidget);
      });

      // The control takes its room from the row's end (#1048).
      testWidgets("a full base game's row and its control lay out on a "
          '${width.toInt()}dp window, folded and open', (tester) async {
        useViewSize(tester, Size(width, 800));
        await tester.pumpWidget(
          harness(
            onOpen: (_, _) {},
            textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
          ),
        );
        status.finished(CollectionHydrateOutcome.complete);
        items.add([
          listItem(
            'e-1',
            gameId: 'g-ti',
            title: 'Twilight Imperium',
            subtitle: 'Fourth Edition',
            quantity: 2,
            rating: 9,
            favorite: true,
            lastPlayed: DateTime(2026, 10, 3),
            isDirty: true,
          ),
          listItem(
            'x-1',
            gameId: 'g-pok',
            title: 'Prophecy of Kings',
            contentType: ContentType.expansion,
            baseGames: const [
              ExpansionLink(gameId: 'g-ti', isStandalone: false),
            ],
          ),
        ]);
        await tester.pumpAndSettle();
        final base = find.byKey(GameCollectionListScreen.rowKey('e-1'));

        expect(tester.takeException(), isNull);
        expect(controlOf(base), findsOneWidget);
        await unfold(tester, base);
        expect(tester.takeException(), isNull);
        // In the test's square font the base row runs to thousands of dp at
        // 200% text, so its nested row is built only once scrolled to.
        await scrollListToEnd(
          tester,
          find.byKey(GameCollectionListScreen.nestedRowKey('g-ti', 'x-1')),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('thumbnails (#710)', () {
    final thumbs = _FakeLayouts()..stored = ListLayout.thumbnails;

    testWidgets('the toggle switches to thumbnails and writes the choice', (
      tester,
    ) async {
      final layouts = _FakeLayouts();
      await show(tester, [listItem('e-1')], layouts: layouts);
      expect(
        find.byKey(GameCollectionListScreen.rowKey('e-1')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Thumbnails'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(GameCollectionListScreen.tileKey('e-1')),
        findsOneWidget,
      );
      expect(find.byKey(GameCollectionListScreen.rowKey('e-1')), findsNothing);
      expect(layouts.writes, [
        (ListLayoutScreen.collection, ListLayout.thumbnails),
      ]);
    });

    // Logged, not reported as a framework error, which the app takes for a
    // crash and offers to send.
    testWidgets('a store that fails shows the list and keeps a change for '
        'the visit, with no framework error', (tester) async {
      await show(tester, [
        listItem('e-1'),
      ], layouts: _FakeLayouts()..failing = true);

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(GameCollectionListScreen.rowKey('e-1')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Thumbnails'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(GameCollectionListScreen.tileKey('e-1')),
        findsOneWidget,
      );
    });

    testWidgets('a stored thumbnails choice opens in thumbnails', (
      tester,
    ) async {
      await show(tester, [listItem('e-1')], layouts: thumbs);

      expect(
        find.byKey(GameCollectionListScreen.tileKey('e-1')),
        findsOneWidget,
      );
      expect(find.byKey(GameCollectionListScreen.rowKey('e-1')), findsNothing);
    });

    testWidgets('until the choice is read, the loading state shows', (
      tester,
    ) async {
      final layouts = _FakeLayouts()..hold = Completer<ListLayout?>();
      await tester.pumpWidget(harness(layouts: layouts));
      status.finished(CollectionHydrateOutcome.complete);
      items.add([listItem('e-1')]);
      await tester.pump();

      expect(find.byKey(GameCollectionListScreen.loadingKey), findsOneWidget);
      expect(find.byKey(GameCollectionListScreen.rowKey('e-1')), findsNothing);
      // No count of rows that aren't built.
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .semanticChildCount,
        isNull,
      );

      layouts.hold!.complete(ListLayout.thumbnails);
      await tester.pumpAndSettle();

      expect(
        find.byKey(GameCollectionListScreen.tileKey('e-1')),
        findsOneWidget,
      );
    });

    testWidgets('a failed read shows before the choice is read', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(layouts: _FakeLayouts()..hold = Completer<ListLayout?>()),
      );
      items.addError(StateError('no authenticated user'));
      await tester.pump();

      expect(find.byKey(GameCollectionListScreen.errorKey), findsOneWidget);
      expect(find.byKey(GameCollectionListScreen.loadingKey), findsNothing);
    });

    testWidgets('an empty collection shows before the choice is read', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(layouts: _FakeLayouts()..hold = Completer<ListLayout?>()),
      );
      status.finished(CollectionHydrateOutcome.complete);
      items.add(const []);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(GameCollectionListScreen.emptyKey), findsOneWidget);
      expect(find.byKey(GameCollectionListScreen.loadingKey), findsNothing);
    });

    testWidgets('a first fill under the choice read is one loading state, '
        'so a screen reader hears "Loading" once', (tester) async {
      final handle = tester.ensureSemantics();
      final layouts = _FakeLayouts()..hold = Completer<ListLayout?>();
      await tester.pumpWidget(harness(layouts: layouts));
      status.started();
      items.add(const []);
      await tester.pump();
      final loading = find.byKey(GameCollectionListScreen.loadingKey);
      expect(loading, findsOneWidget);
      final element = tester.element(loading);
      final node = tester.getSemantics(loading).id;

      // The choice lands while the cache is still filling.
      layouts.hold!.complete(ListLayout.list);
      await tester.pump();
      await tester.pump();

      expect(loading, findsOneWidget);
      expect(
        tester.element(loading),
        same(element),
        reason: 'a new live region would announce the loading again',
      );
      expect(tester.getSemantics(loading).id, node);
      handle.dispose();
    });

    testWidgets("a tile's name is the title and the row's spoken details", (
      tester,
    ) async {
      await show(tester, [
        listItem(
          'e-1',
          subtitle: 'Seafarers',
          medium: GameMedium.digital,
          quantity: 2,
          rating: 7,
          favorite: true,
        ),
      ], layouts: thumbs);

      expect(
        find.bySemanticsLabel(
          'Catan: Seafarers, Board game, Digital, 2 copies, '
          'Rated 7 out of 10, Favorite',
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping a tile opens its entry', (tester) async {
      final opened = <String>[];
      await show(
        tester,
        [listItem('e-1')],
        layouts: thumbs,
        onOpen: (_, id) => opened.add(id),
      );

      await tester.tap(find.byKey(GameCollectionListScreen.tileKey('e-1')));
      await tester.pumpAndSettle();

      expect(opened, ['e-1']);
    });

    testWidgets('without onOpen a tile is inert', (tester) async {
      await show(tester, [listItem('e-1')], layouts: thumbs);

      final node = tester.getSemantics(
        find.byKey(GameCollectionListScreen.tileKey('e-1')),
      );
      expect(node, isSemantics(isButton: false, hasTapAction: false));
    });

    testWidgets('the refresh banner stays above the grid', (tester) async {
      await tester.pumpWidget(harness(layouts: thumbs));
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pumpAndSettle();

      final banner = find.byKey(GameCollectionListScreen.refreshBannerKey);
      expect(banner, findsOneWidget);
      expect(
        tester.getBottomLeft(banner).dy,
        lessThanOrEqualTo(
          tester
              .getTopLeft(find.byKey(GameCollectionListScreen.tileKey('e-1')))
              .dy,
        ),
      );
    });
  });

  group('when the refresh failed', () {
    testWidgets('says so above the rows it is still showing', (tester) async {
      await tester.pumpWidget(harness());
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(
        find.byKey(GameCollectionListScreen.rowKey('e-1')),
        findsOneWidget,
      );
    });

    testWidgets('qualifies an empty list rather than replacing it', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      items.add(const []);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(GameCollectionListScreen.emptyKey), findsOneWidget);
    });

    testWidgets('offers a retry where the composition can run one', (
      tester,
    ) async {
      await tester.pumpWidget(harness(onRetry: () async {}));
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pump();

      expect(
        find.byKey(GameCollectionListScreen.refreshRetryKey),
        findsOneWidget,
      );
      expect(find.text(_retryCopy), findsOneWidget);
    });

    testWidgets('offers none where it cannot', (tester) async {
      await tester.pumpWidget(harness());
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(
        find.byKey(GameCollectionListScreen.refreshRetryKey),
        findsNothing,
      );
    });

    testWidgets('pressing it runs a pass and says so', (tester) async {
      final pass = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        harness(
          onRetry: () {
            calls++;
            return pass.future;
          },
        ),
      );
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pump();

      await tester.tap(find.byKey(GameCollectionListScreen.refreshRetryKey));
      await tester.pump();
      status.started();
      await tester.pump();

      expect(calls, 1);
      // The banner's message, and the busy button's own label: it keeps a
      // name rather than becoming a bare spinner.
      expect(find.text(_refreshingCopy), findsNWidgets(2));
      expect(
        tester
            .widget<TextButton>(
              find.byKey(GameCollectionListScreen.refreshRetryKey),
            )
            .onPressed,
        // Enabled and inert, so it keeps focus (#607).
        isNotNull,
      );

      pass.complete();
      status.finished(CollectionHydrateOutcome.complete);
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsNothing);
    });

    testWidgets('a pass nobody asked for leaves it up, without narrating', (
      tester,
    ) async {
      await tester.pumpWidget(harness(onRetry: () async {}));
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pump();

      status.started();
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(GameCollectionListScreen.refreshRetryKey),
            )
            .onPressed,
        isNotNull,
      );

      status.finished(CollectionHydrateOutcome.complete);
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsNothing);
    });

    testWidgets('a pass nobody asked for does not take focus off the retry', (
      tester,
    ) async {
      FocusNode retryFocus() => Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(GameCollectionListScreen.refreshRetryKey),
            matching: find.text(_retryCopy),
          ),
        ),
      );

      await tester.pumpWidget(harness(onRetry: () async {}));
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pump();
      retryFocus().requestFocus();
      await tester.pump();

      status.started();
      await tester.pump();
      await tester.pump();

      expect(retryFocus().hasPrimaryFocus, isTrue);
    });
  });

  group('refreshing by hand (#717)', () {
    GameCollectionListBloc listBloc(WidgetTester tester) =>
        BlocProvider.of<GameCollectionListBloc>(
          tester.element(find.byType(GameCollectionListSliver)),
        );

    /// Pumps the screen on [surface], reached the way the groups above reach
    /// it, and checks it is the one showing.
    Future<void> pumpOn(
      WidgetTester tester,
      _Surface surface, {
      Future<void> Function()? onRetry,
      void Function(BuildContext context, String entryId)? onOpen,
      ListLayoutRepository? layouts,
    }) async {
      await tester.pumpWidget(
        harness(onRetry: onRetry, onOpen: onOpen, layouts: layouts),
      );
      switch (surface) {
        case _Surface.loading:
          status.started();
          items.add(const []);
        case _Surface.error:
          items.addError(StateError('no authenticated user'));
        case _Surface.empty:
          status.finished(CollectionHydrateOutcome.complete);
          items.add(const []);
        case _Surface.noMatches || _Surface.rows:
          status.finished(CollectionHydrateOutcome.complete);
          items.add([
            listItem('e-1', title: 'Azul'),
            listItem('e-2', title: 'Brass'),
          ]);
      }
      await tester.pump();
      if (surface == _Surface.noMatches) {
        listBloc(tester).add(
          const GameCollectionListFilterChanged(
            CollectionFilter(query: 'nothing has this name'),
          ),
        );
        await tester.pump();
      }
      expect(
        find.byKey(switch (surface) {
          _Surface.loading => GameCollectionListScreen.loadingKey,
          _Surface.error => GameCollectionListScreen.errorKey,
          _Surface.empty => GameCollectionListScreen.emptyKey,
          _Surface.noMatches => GameCollectionListScreen.noMatchesKey,
          _Surface.rows => GameCollectionListScreen.rowKey('e-1'),
        }),
        findsOneWidget,
      );
    }

    /// A touch pull down the list, held for the indicator to snap into place
    /// and call for the refresh.
    Future<void> pull(WidgetTester tester) async {
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    Finder button() => find.byKey(GameCollectionListScreen.refreshButtonKey);

    FocusNode buttonFocus(WidgetTester tester) =>
        tester.widget<IconButton>(button()).focusNode!;

    final banner = find.byKey(GameCollectionListScreen.refreshBannerKey);

    for (final surface in _Surface.values) {
      testWidgets('the app bar has a refresh button: ${surface.name}', (
        tester,
      ) async {
        await pumpOn(tester, surface, onRetry: () async {});

        expect(
          find.descendant(of: find.byType(AppBar), matching: button()),
          findsOneWidget,
        );
        expect(find.byTooltip(_refreshCopy), findsOneWidget);
      });

      testWidgets('the button sends the retry: ${surface.name}', (
        tester,
      ) async {
        var calls = 0;
        await pumpOn(tester, surface, onRetry: () async => calls++);

        await tester.tap(button());
        await tester.pump();

        expect(calls, 1);
      });

      testWidgets('no seam, no gesture and no button: ${surface.name}', (
        tester,
      ) async {
        await pumpOn(tester, surface);

        expect(button(), findsNothing);
        expect(find.byType(RefreshIndicator), findsNothing);
      });
    }

    testWidgets('a pull sends the retry and the spinner holds until the pass '
        'ends', (tester) async {
      final pass = Completer<void>();
      var calls = 0;
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () {
          calls++;
          return pass.future;
        },
      );

      await pull(tester);

      expect(calls, 1);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      // The banner narrates the same pass.
      expect(banner, findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);

      pass.complete();
      await tester.pumpAndSettle();

      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(banner, findsNothing);
    });

    for (final surface in [
      _Surface.loading,
      _Surface.empty,
      _Surface.error,
      _Surface.noMatches,
    ]) {
      testWidgets('a pull from the ${surface.name} state refreshes', (
        tester,
      ) async {
        var calls = 0;
        await pumpOn(tester, surface, onRetry: () async => calls++);

        await pull(tester);

        expect(calls, 1);
      });
    }

    // No banner over these, so the button alone says its pass is running.
    for (final surface in [_Surface.loading, _Surface.error]) {
      testWidgets('on the ${surface.name} surface the button says its pass '
          'is running, then that it ended', (tester) async {
        final handle = tester.ensureSemantics();
        final pass = Completer<void>();
        var calls = 0;
        await pumpOn(
          tester,
          surface,
          onRetry: () {
            calls++;
            return pass.future;
          },
        );
        String label() =>
            tester.getSemantics(find.byType(BgeRefreshButton)).label;
        expect(label(), _refreshCopy);

        await tester.tap(button());
        await tester.pump();
        await tester.pump();

        expect(calls, 1);
        expect(label(), _refreshingCopy);
        expect(find.byTooltip(_refreshingCopy), findsOneWidget);
        expect(banner, findsNothing);

        pass.complete();
        await tester.pump();
        await tester.pump();

        expect(label(), _refreshCopy);
        expect(find.byTooltip(_refreshCopy), findsOneWidget);
        handle.dispose();
      });
    }

    testWidgets("a pull during the button's pass joins it, and its spinner "
        'ends with it', (tester) async {
      final pass = Completer<void>();
      var calls = 0;
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () {
          calls++;
          return pass.future;
        },
      );
      await tester.tap(button());
      await tester.pump();
      await tester.pump();
      expect(calls, 1);

      await pull(tester);

      expect(calls, 1);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);

      pass.complete();
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(banner, findsNothing);
    });

    testWidgets('in thumbnails layout a pull refreshes', (tester) async {
      var calls = 0;
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () async => calls++,
        layouts: _FakeLayouts(),
      );
      await tester.tap(find.byTooltip('Thumbnails'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(GameCollectionListScreen.tileKey('e-1')),
        findsOneWidget,
      );

      await pull(tester);

      expect(calls, 1);
      await tester.pumpAndSettle();
    });

    testWidgets('the button keeps focus through its own pass', (tester) async {
      final handle = tester.ensureSemantics();
      final pass = Completer<void>();
      var calls = 0;
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () {
          calls++;
          return pass.future;
        },
      );
      buttonFocus(tester).requestFocus();
      await tester.pump();
      final node = FocusManager.instance.primaryFocus;
      expect(node, same(buttonFocus(tester)));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(calls, 1);
      expect(
        tester.getSemantics(find.byType(BgeRefreshButton)).label,
        _refreshingCopy,
      );
      expect(FocusManager.instance.primaryFocus, same(node));
      expect(buttonFocus(tester), same(node));

      // A press while it runs starts nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 1);

      pass.complete();
      await tester.pump();
      await tester.pump();

      expect(
        tester.getSemantics(find.byType(BgeRefreshButton)).label,
        _refreshCopy,
      );
      expect(FocusManager.instance.primaryFocus, same(node));
      handle.dispose();
    });

    testWidgets('a row keeps focus while the banner comes and goes', (
      tester,
    ) async {
      final pass = Completer<void>();
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () => pass.future,
        onOpen: (_, _) {},
      );
      FocusNode rowFocus() => Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(GameCollectionListScreen.rowKey('e-1')),
            matching: find.text('Azul'),
          ),
        ),
      );
      rowFocus().requestFocus();
      await tester.pump();
      final row = rowFocus();
      expect(row.hasPrimaryFocus, isTrue);

      await tester.tap(button());
      await tester.pump();
      await tester.pump();

      // The banner arrives above the rows, moving them one place down.
      expect(banner, findsOneWidget);
      expect(rowFocus(), same(row));
      expect(row.hasPrimaryFocus, isTrue);

      pass.complete();
      await tester.pump();
      await tester.pump();

      expect(banner, findsNothing);
      expect(rowFocus(), same(row));
      expect(row.hasPrimaryFocus, isTrue);
    });

    testWidgets("the header controls keep focus when a pull's banner "
        'arrives', (tester) async {
      // The banner comes in below the header, which keeps its place (#607).
      final pass = Completer<void>();
      final search = find.byKey(GameCollectionListScreen.searchKey);
      FocusNode searchFocus() => tester.widget<TextField>(search).focusNode!;
      await pumpOn(tester, _Surface.rows, onRetry: () => pass.future);
      searchFocus().requestFocus();
      await tester.pump();
      final node = searchFocus();
      expect(node.hasPrimaryFocus, isTrue);

      await pull(tester);

      expect(banner, findsOneWidget);
      expect(
        tester.getTopLeft(banner).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(search).dy),
      );
      expect(searchFocus(), same(node));
      expect(node.hasPrimaryFocus, isTrue);

      pass.complete();
      await tester.pumpAndSettle();

      expect(banner, findsNothing);
      expect(node.hasPrimaryFocus, isTrue);
    });
  });

  group('the entry trigger (#44)', () {
    testWidgets('asks for a pass once, on entry', (tester) async {
      var entries = 0;
      await tester.pumpWidget(harness(onEnter: () => entries++));
      await tester.pump();

      expect(entries, 1);
    });

    testWidgets('a rebuild does not ask again', (tester) async {
      // `BlocProvider.create` runs once per insertion, which is what "on
      // entry" means; a route builder runs on every router rebuild.
      var entries = 0;
      await tester.pumpWidget(harness(onEnter: () => entries++));
      items.add([listItem('e-1')]);
      status.finished(CollectionHydrateOutcome.complete);
      await tester.pump();
      await tester.pumpWidget(harness(onEnter: () => entries++));
      await tester.pump();

      expect(entries, 1);
    });
  });

  testWidgets('the list body can be hosted without the page (#44)', (
    tester,
  ) async {
    // #46's two-pane form puts the list beside the detail, under its own app
    // bar, so the body cannot bring one. The host owns the open set, as it
    // owns the count it is read for (#1048).
    final open = BgeOpenRows();
    addTearDown(open.dispose);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: BlocProvider(
            create: (_) => GameCollectionListBloc(
              repository: repository,
              hydration: status.watch(),
            ),
            child: CustomScrollView(
              slivers: [GameCollectionListSliver(openRows: open)],
            ),
          ),
        ),
      ),
    );
    status.finished(CollectionHydrateOutcome.complete);
    items.add([listItem('e-1')]);
    await tester.pump();

    expect(find.text('Catan'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
  });

  group('the layout toggle (#710)', () {
    final toggle = find.byKey(GameCollectionListScreen.layoutToggleKey);

    /// The toggle heads the content, end-aligned, above [content], and is not
    /// in the app bar, where it left the title cut at 320dp.
    void expectAtTheHead(WidgetTester tester, Finder content) {
      expect(toggle, findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: toggle),
        findsNothing,
      );
      expect(content, findsOneWidget);
      expect(
        tester.getBottomLeft(toggle).dy,
        lessThanOrEqualTo(tester.getTopLeft(content).dy),
      );
    }

    final states = <String, Future<Finder> Function(WidgetTester)>{
      'while the choice is read': (tester) async {
        await tester.pumpWidget(
          harness(layouts: _FakeLayouts()..hold = Completer<ListLayout?>()),
        );
        status.finished(CollectionHydrateOutcome.complete);
        items.add([listItem('e-1')]);
        await tester.pump();
        return find.byKey(GameCollectionListScreen.loadingKey);
      },
      'while the cache fills': (tester) async {
        await tester.pumpWidget(harness());
        status.started();
        items.add(const []);
        await tester.pump();
        return find.byKey(GameCollectionListScreen.loadingKey);
      },
      'over a failed read': (tester) async {
        await tester.pumpWidget(harness());
        items.addError(StateError('no authenticated user'));
        await tester.pump();
        return find.byKey(GameCollectionListScreen.errorKey);
      },
      'over an empty collection': (tester) async {
        await show(tester, const []);
        return find.byKey(GameCollectionListScreen.emptyKey);
      },
      'over the refresh banner': (tester) async {
        await tester.pumpWidget(harness());
        items.add([listItem('e-1')]);
        status.finished(CollectionHydrateOutcome.failed);
        await tester.pumpAndSettle();
        return find.byKey(GameCollectionListScreen.refreshBannerKey);
      },
    };
    for (final MapEntry(key: state, value: build) in states.entries) {
      testWidgets('heads the content $state', (tester) async {
        expectAtTheHead(tester, await build(tester));
      });
    }

    testWidgets('heads the rows, at their end edge', (tester) async {
      await show(tester, [listItem('e-1')], layouts: _FakeLayouts());

      final row = find.byKey(GameCollectionListScreen.rowKey('e-1'));
      expectAtTheHead(tester, row);
      expect(
        tester.getTopRight(toggle).dx,
        moreOrLessEquals(tester.getTopRight(row).dx, epsilon: 0.5),
      );
    });

    testWidgets('a screen reader meets it after the title and before the '
        'rows', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, [listItem('e-1')], layouts: _FakeLayouts());
      final row = rowSemantics(tester, 'e-1').label;

      expect(
        tester.semantics.simulatedAccessibilityTraversal(),
        containsAllInOrder(<Matcher>[
          isSemantics(label: 'Collection'),
          isSemantics(label: 'List'),
          isSemantics(label: 'Thumbnails'),
          isSemantics(label: row),
        ]),
      );
      handle.dispose();
    });

    testWidgets('keeps its focus as a refresh banner comes and goes', (
      tester,
    ) async {
      await show(tester, [listItem('e-1')], layouts: _FakeLayouts());
      final segment = Focus.of(
        tester.element(
          find.descendant(
            of: toggle,
            matching: find.byIcon(Icons.view_list_outlined),
          ),
        ),
      )..requestFocus();
      await tester.pump();

      status
        ..started()
        ..finished(CollectionHydrateOutcome.failed);
      await tester.pumpAndSettle();
      expect(
        find.byKey(GameCollectionListScreen.refreshBannerKey),
        findsOneWidget,
      );
      expect(segment.hasPrimaryFocus, isTrue);

      status
        ..started()
        ..finished(CollectionHydrateOutcome.complete);
      await tester.pumpAndSettle();
      expect(
        find.byKey(GameCollectionListScreen.refreshBannerKey),
        findsNothing,
      );
      expect(segment.hasPrimaryFocus, isTrue);
    });
  });

  group('search, filters and sort (#715)', () {
    final search = find.byKey(GameCollectionListScreen.searchKey);
    final sortButton = find.byKey(GameCollectionListScreen.sortButtonKey);
    final count = find.byKey(GameCollectionListScreen.resultCountKey);
    final noMatches = find.byKey(GameCollectionListScreen.noMatchesKey);
    final clearFilters = find.byKey(GameCollectionListScreen.clearFiltersKey);
    Finder row(String id) => find.byKey(GameCollectionListScreen.rowKey(id));

    /// Three games: two on a tabletop, one on a PC, each rated.
    List<GameCollectionListItem> three() => [
      listItem(
        'e-1',
        title: 'Azul',
        platformType: PlatformType.tabletop,
        rating: 5,
      ),
      listItem(
        'e-2',
        title: 'Brass',
        platformType: PlatformType.pc,
        rating: 9,
      ),
      // Catan, the default title.
      listItem(
        'e-3',
        platformType: PlatformType.tabletop,
        rating: 7,
      ),
    ];

    GameCollectionListBloc listBloc(WidgetTester tester) =>
        BlocProvider.of<GameCollectionListBloc>(
          tester.element(find.byType(GameCollectionListSliver)),
        );

    String? countText(WidgetTester tester) => tester.widget<Text>(count).data;

    /// The search field's own focus node, which [BgeSearchField] gives its
    /// text field.
    FocusNode searchFocus(WidgetTester tester) =>
        tester.widget<TextField>(search).focusNode!;

    String searchText(WidgetTester tester) =>
        tester.widget<TextField>(search).controller!.text;

    Future<void> openFilters(WidgetTester tester) async {
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

    /// The titles of the rows shown, top to bottom.
    List<String> shownTitles(WidgetTester tester, List<String> titles) {
      final shown = [
        for (final title in titles)
          if (find.text(title).evaluate().isNotEmpty) title,
      ];
      return shown..sort(
        (a, b) => tester
            .getTopLeft(find.text(a))
            .dy
            .compareTo(tester.getTopLeft(find.text(b)).dy),
      );
    }

    testWidgets('typing in the search narrows the list and the count says '
        'so', (tester) async {
      await show(tester, three());
      expect(count, findsNothing);

      await tester.enterText(search, 'bra');
      await tester.pumpAndSettle();

      expect(row('e-2'), findsOneWidget);
      expect(row('e-1'), findsNothing);
      expect(row('e-3'), findsNothing);
      expect(countText(tester), '1 game of 3');
      expect(listBloc(tester).state, isA<GameCollectionListReady>());
    });

    testWidgets('the count counts games, not entries', (tester) async {
      // Wingspan owned twice is one game, as its stack is one row.
      await show(tester, [
        listItem('w-1', gameId: 'g-wingspan', title: 'Wingspan'),
        listItem(
          'w-2',
          gameId: 'g-wingspan',
          title: 'Wingspan',
          medium: GameMedium.digital,
        ),
        listItem('e-1', title: 'Azul'),
        listItem('e-2', title: 'Brass'),
      ]);

      await tester.enterText(search, 'wing');
      await tester.pumpAndSettle();

      expect(countText(tester), '1 game of 3');
    });

    testWidgets('the count is a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, three());

      await tester.enterText(search, 'a');
      await tester.pumpAndSettle();

      expect(countText(tester), '3 games of 3');
      expect(
        tester.getSemantics(count),
        isSemantics(label: '3 games of 3', isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('typing never builds the field afresh, so it keeps its '
        'focus', (tester) async {
      await show(tester, three());
      await tester.tap(search);
      await tester.pump();
      final field = tester.state(find.byType(BgeSearchField));
      final focus = searchFocus(tester);
      expect(focus.hasPrimaryFocus, isTrue);

      for (final text in ['c', 'ca', 'cat', 'zzz', '']) {
        await tester.enterText(search, text);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(BgeSearchField)), same(field));
        expect(focus.hasPrimaryFocus, isTrue, reason: 'after "$text"');
      }
    });

    testWidgets('the sheet offers the medium, the missing base game and '
        'the flips', (tester) async {
      await show(tester, three());
      await openFilters(tester);

      expect(
        find.byKey(GameFilterKeys.medium(GameMedium.digital)),
        findsOneWidget,
      );
      expect(find.byKey(GameFilterKeys.missingBaseGame), findsOneWidget);
      expect(
        find.byKey(GameFilterKeys.exclude(CollectionFacet.platformType)),
        findsOneWidget,
      );
    });

    testWidgets('a platform filter from the sheet narrows the list, and its '
        'chip removes it', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, three());
      await openFilters(tester);
      await tapInSheet(
        tester,
        find.byKey(GameFilterKeys.platformType(PlatformType.pc)),
      );
      await closeFilters(tester);

      expect(row('e-2'), findsOneWidget);
      expect(row('e-1'), findsNothing);
      expect(countText(tester), '1 game of 3');
      expect(find.text('Filters (1)'), findsOneWidget);
      // No other Filters button is on this screen, so it keeps its own text
      // for its name (#919).
      expect(
        tester.getSemantics(find.byKey(GameFilterKeys.button)).label,
        'Filters (1)',
      );
      final chip = find.byKey(GameFilterKeys.inUse('platform_pc'));
      expect(chip, findsOneWidget);

      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(chip, findsNothing);
      expect(row('e-1'), findsOneWidget);
      expect(row('e-2'), findsOneWidget);
      expect(row('e-3'), findsOneWidget);
      expect(count, findsNothing);
      expect(listBloc(tester).filter, const CollectionFilter());
      handle.dispose();
    });

    // A range field commits what it holds as the sheet closes, from its
    // dispose when it doesn't hold focus, while the tree is locked.
    for (final focused in [true, false]) {
      testWidgets('a bound typed in the sheet narrows the list once the '
          'sheet closes unsubmitted, the field '
          '${focused ? 'focused' : 'filled with no focus'}', (tester) async {
        await show(tester, [
          listItem('e-1', title: 'Azul', publishYear: 2017),
          listItem('e-2', title: 'Brass', publishYear: 2007),
          listItem('e-3', publishYear: 1995),
        ]);
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
        expect(row('e-1'), findsOneWidget);
        expect(row('e-2'), findsOneWidget);
        expect(row('e-3'), findsNothing);
        expect(countText(tester), '2 games of 3');
        expect(find.text('Filters (1)'), findsOneWidget);
      });
    }

    testWidgets('a flipped filter leaves its games out', (tester) async {
      await show(tester, three());
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

      expect(row('e-2'), findsOneWidget);
      expect(row('e-1'), findsNothing);
      expect(row('e-3'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(GameFilterKeys.inUse('platform_tabletop')),
          matching: find.text('Not Tabletop'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a stack whose one entry matched is a single row', (
      tester,
    ) async {
      await show(tester, [
        listItem('w-1', gameId: 'g-wingspan', title: 'Wingspan'),
        listItem(
          'w-2',
          gameId: 'g-wingspan',
          title: 'Wingspan',
          medium: GameMedium.digital,
        ),
        listItem('e-1', title: 'Azul'),
      ]);
      expect(
        find.byKey(GameCollectionListScreen.stackKey('g-wingspan')),
        findsOneWidget,
      );

      await openFilters(tester);
      await tapInSheet(
        tester,
        find.byKey(GameFilterKeys.medium(GameMedium.digital)),
      );
      await closeFilters(tester);

      expect(
        find.byKey(GameCollectionListScreen.stackKey('g-wingspan')),
        findsNothing,
      );
      expect(row('w-2'), findsOneWidget);
      expect(row('w-1'), findsNothing);
      expect(row('e-1'), findsNothing);
    });

    group('while the list is loading or failed', () {
      // No state is emitted for a change then, so the header draws what it
      // sent.
      final states = <String, Future<void> Function(WidgetTester)>{
        'loading': (tester) async {
          await tester.pumpWidget(harness());
          status.started();
          items.add(const []);
          await tester.pump();
          expect(
            listBloc(tester).state,
            isA<GameCollectionListLoading>(),
          );
        },
        'failed': (tester) async {
          await tester.pumpWidget(harness());
          items.addError(StateError('no authenticated user'));
          await tester.pump();
          expect(listBloc(tester).state, isA<GameCollectionListError>());
        },
      };
      for (final MapEntry(key: name, value: reach) in states.entries) {
        testWidgets('$name, a filter and a sort show as soon as they are '
            'chosen', (tester) async {
          await reach(tester);
          // The loading spinner never settles, so each step waits out its
          // transition instead.
          Future<void> settle() async {
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
          }

          await tester.tap(find.byKey(GameFilterKeys.button));
          await settle();
          final pc = find.byKey(GameFilterKeys.platformType(PlatformType.pc));
          await tester.ensureVisible(pc);
          await settle();
          await tester.tap(pc);
          await settle();
          await tester.tapAt(const Offset(10, 10));
          await settle();

          expect(find.text('Filters (1)'), findsOneWidget);
          expect(
            find.byKey(GameFilterKeys.inUse('platform_pc')),
            findsOneWidget,
          );

          await tester.tap(sortButton);
          await settle();
          await tester.tap(
            find.byKey(GameCollectionListScreen.sortKey(CollectionSort.rating)),
          );
          await settle();

          expect(find.text('Sort: Your rating'), findsOneWidget);
          expect(listBloc(tester).sort, CollectionSort.rating);
          expect(
            listBloc(tester).filter.game.platformTypes,
            {PlatformType.pc},
          );
        });
      }
    });

    group('the sort menu', () {
      MenuItemButton item(WidgetTester tester, CollectionSort sort) =>
          tester.widget<MenuItemButton>(
            find.byKey(GameCollectionListScreen.sortKey(sort)),
          );

      testWidgets('choosing a sort reorders the rows and focus returns to '
          'the sort button', (tester) async {
        await show(tester, three());
        expect(shownTitles(tester, ['Azul', 'Brass', 'Catan']), [
          'Azul',
          'Brass',
          'Catan',
        ]);
        expect(find.text('Sort: Title'), findsOneWidget);

        await tester.tap(sortButton);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(GameCollectionListScreen.sortKey(CollectionSort.rating)),
        );
        await tester.pump();
        await tester.pumpAndSettle();

        expect(shownTitles(tester, ['Azul', 'Brass', 'Catan']), [
          'Brass',
          'Catan',
          'Azul',
        ]);
        expect(find.text('Sort: Your rating'), findsOneWidget);
        expect(
          Focus.of(tester.element(find.text('Sort: Your rating'))),
          isA<FocusNode>().having((n) => n.hasPrimaryFocus, 'focused', true),
        );
      });

      testWidgets('by keyboard, a pick or Escape returns focus to the sort '
          'button', (
        tester,
      ) async {
        await show(tester, three());
        await activateByKeyboard(tester, sortButton);
        expect(
          find.byKey(GameCollectionListScreen.sortKey(CollectionSort.title)),
          findsOneWidget,
        );

        FocusNode itemFocus(CollectionSort sort) => Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(GameCollectionListScreen.sortKey(sort)),
              matching: find.byType(Text),
            ),
          ),
        );
        // Down to Title, the first, then on to Recently added.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(itemFocus(CollectionSort.title).hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
          itemFocus(CollectionSort.recentlyAdded).hasPrimaryFocus,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pumpAndSettle();

        expect(listBloc(tester).sort, CollectionSort.recentlyAdded);
        final button = Focus.of(
          tester.element(find.text('Sort: Recently added')),
        );
        expect(button.hasPrimaryFocus, isTrue);

        // Open again, into the menu, and leave it with Escape.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(itemFocus(CollectionSort.title).hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(
          find.byKey(GameCollectionListScreen.sortKey(CollectionSort.title)),
          findsNothing,
        );
        expect(listBloc(tester).sort, CollectionSort.recentlyAdded);
        expect(button.hasPrimaryFocus, isTrue);
      });

      testWidgets('offers six orders, the current one checked and selected', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await show(tester, three());
        expect(
          tester.getSemantics(sortButton),
          isSemantics(
            label: 'Sort: Title',
            isButton: true,
            hasExpandedState: true,
            isExpanded: false,
          ),
        );

        await tester.tap(sortButton);
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(sortButton),
          isSemantics(hasExpandedState: true, isExpanded: true),
        );
        for (final (sort, label) in [
          (CollectionSort.title, 'Title'),
          (CollectionSort.recentlyAdded, 'Recently added'),
          (CollectionSort.playTime, 'Shortest first'),
          (CollectionSort.minPlayers, 'Fewest players'),
          (CollectionSort.maxPlayers, 'Most players'),
          (CollectionSort.rating, 'Your rating'),
        ]) {
          final current = sort == CollectionSort.title;
          expect(
            tester.getSemantics(
              find.byKey(GameCollectionListScreen.sortKey(sort)),
            ),
            isSemantics(
              label: label,
              hasSelectedState: true,
              isSelected: current,
            ),
            reason: label,
          );
          final leading = item(tester, sort).leadingIcon;
          expect(
            leading is Icon ? leading.icon : null,
            current ? Icons.check : null,
            reason: label,
          );
          // The others keep the check's room, so the labels line up.
          expect(
            tester.getTopLeft(find.text(label).last).dx,
            moreOrLessEquals(
              tester.getTopLeft(find.text('Recently added')).dx,
              epsilon: 0.5,
            ),
            reason: label,
          );
        }
        handle.dispose();
      });
    });

    group('no games match', () {
      testWidgets('a filter that leaves nothing shows No games match, and '
          'Clear filters brings the list back', (tester) async {
        await show(tester, three());
        listBloc(
          tester,
        ).add(const GameCollectionListSortChanged(CollectionSort.rating));
        await tester.pumpAndSettle();

        await tester.enterText(search, 'zzz');
        await tester.pumpAndSettle();

        expect(noMatches, findsOneWidget);
        expect(find.text('No games match'), findsOneWidget);
        expect(
          find.text(
            'Nothing in your collection fits this search and these filters.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(GameCollectionListScreen.emptyKey), findsNothing);
        expect(countText(tester), '0 games of 3');
        // The header stays above it.
        expect(
          tester.getBottomLeft(search).dy,
          lessThan(tester.getTopLeft(noMatches).dy),
        );

        await tester.tap(clearFilters);
        await tester.pumpAndSettle();

        expect(noMatches, findsNothing);
        expect(row('e-1'), findsOneWidget);
        expect(row('e-2'), findsOneWidget);
        expect(row('e-3'), findsOneWidget);
        expect(searchText(tester), isEmpty);
        expect(count, findsNothing);
        expect(listBloc(tester).filter, const CollectionFilter());
        // The sort stays.
        expect(listBloc(tester).sort, CollectionSort.rating);
        expect(find.text('Sort: Your rating'), findsOneWidget);
      });

      testWidgets('Clear filters clears the filters from the sheet too', (
        tester,
      ) async {
        await show(tester, three());
        listBloc(tester).add(
          const GameCollectionListFilterChanged(
            CollectionFilter(
              query: 'brass',
              game: GameSearchFilter(platformTypes: {PlatformType.tabletop}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(noMatches, findsOneWidget);

        await tester.tap(clearFilters);
        await tester.pumpAndSettle();

        expect(listBloc(tester).filter, const CollectionFilter());
        expect(
          find.byKey(GameFilterKeys.inUse('platform_tabletop')),
          findsNothing,
        );
        expect(find.text('Filters'), findsOneWidget);
      });

      // Clear filters hands focus to the Filters button, never to the
      // search field, which would open the on-screen keyboard over the list
      // the user asked to see.
      group('Clear filters hands focus to Filters', () {
        FocusNode filtersFocus(WidgetTester tester) =>
            Focus.of(tester.element(find.text('Filters')));

        /// A filter that leaves nothing, sent as the sheet would, with no
        /// focus moved.
        Future<void> noneMatch(WidgetTester tester) async {
          await show(tester, three());
          listBloc(tester).add(
            const GameCollectionListFilterChanged(
              CollectionFilter(
                game: GameSearchFilter(platformTypes: {PlatformType.mobile}),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(clearFilters, findsOneWidget);
        }

        /// Leaves input focus on no control, as a screen reader's user's is.
        Future<void> focusNothing(WidgetTester tester) async {
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          final focused = FocusManager.instance.primaryFocus;
          expect(focused == null || focused is FocusScopeNode, isTrue);
        }

        testWidgets('from a pointer, with focus on nothing', (tester) async {
          await noneMatch(tester);
          await focusNothing(tester);

          await tester.tap(clearFilters);
          await tester.pumpAndSettle();

          expect(clearFilters, findsNothing);
          expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
        });

        testWidgets('from a pointer, emptying the search field that held '
            'focus, with no keyboard left open', (tester) async {
          await show(tester, three());
          await tester.enterText(search, 'zzz');
          await tester.pumpAndSettle();
          expect(tester.testTextInput.isVisible, isTrue);

          await tester.tap(clearFilters);
          await tester.pumpAndSettle();

          expect(searchText(tester), isEmpty);
          expect(searchFocus(tester).hasFocus, isFalse);
          expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
          expect(tester.testTextInput.isVisible, isFalse);
        });

        testWidgets('from the keyboard', (tester) async {
          await show(tester, three());
          await tester.enterText(search, 'zzz');
          await tester.pumpAndSettle();

          await activateByKeyboard(tester, clearFilters);

          expect(clearFilters, findsNothing);
          expect(searchText(tester), isEmpty);
          expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
        });

        testWidgets("from a screen reader's activation, which moves no "
            'input focus', (tester) async {
          final handle = tester.ensureSemantics();
          await noneMatch(tester);
          await focusNothing(tester);

          tester.semantics.tap(
            find.semantics.byPredicate(
              (node) =>
                  node.label == 'Clear filters' &&
                  node.getSemanticsData().hasAction(SemanticsAction.tap),
              describeMatch: (_) => 'Clear filters',
            ),
          );
          await tester.pumpAndSettle();

          expect(clearFilters, findsNothing);
          expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
          handle.dispose();
        });

        testWidgets('a pointer press while focus sits on another control '
            'moves nothing', (tester) async {
          await noneMatch(tester);
          final sort = Focus.of(tester.element(find.text('Sort: Title')))
            ..requestFocus();
          await tester.pump();
          expect(sort.hasPrimaryFocus, isTrue);

          await tester.tap(clearFilters);
          await tester.pumpAndSettle();

          expect(clearFilters, findsNothing);
          expect(sort.hasPrimaryFocus, isTrue);
          expect(filtersFocus(tester).hasFocus, isFalse);
        });
      });

      testWidgets('an empty collection still shows Browse, not No games '
          'match', (tester) async {
        await show(tester, const [], onBrowse: (_) {});

        expect(find.byKey(GameCollectionListScreen.emptyKey), findsOneWidget);
        expect(find.byKey(GameCollectionListScreen.browseKey), findsOneWidget);
        expect(noMatches, findsNothing);
        // The header stays above it.
        expect(search, findsOneWidget);
        expect(sortButton, findsOneWidget);

        await tester.enterText(search, 'zzz');
        await tester.pumpAndSettle();

        expect(find.byKey(GameCollectionListScreen.emptyKey), findsOneWidget);
        expect(noMatches, findsNothing);
      });
    });

    // The hand-off is the chips' own (game_filters); this is the screen's
    // wiring of it, the last chip landing on Filters.
    group('a focused chip removed', () {
      FocusNode chipFocus(WidgetTester tester, String id) => Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byKey(GameFilterKeys.inUse(id)),
                matching: find.byType(Text),
              )
              .first,
        ),
      );

      Future<void> twoFilters(WidgetTester tester) async {
        await show(tester, three());
        listBloc(tester).add(
          const GameCollectionListFilterChanged(
            CollectionFilter(
              game: GameSearchFilter(
                platformTypes: {PlatformType.tabletop, PlatformType.pc},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('hands focus to the chip after it', (tester) async {
        await twoFilters(tester);
        chipFocus(tester, 'platform_tabletop').requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(
          find.byKey(GameFilterKeys.inUse('platform_tabletop')),
          findsNothing,
        );
        expect(chipFocus(tester, 'platform_pc').hasPrimaryFocus, isTrue);
      });

      testWidgets('hands focus to the Filters button once the last chip has '
          'gone', (tester) async {
        await twoFilters(tester);
        chipFocus(tester, 'platform_pc').requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        // The last chip, now the only one, took focus.
        expect(chipFocus(tester, 'platform_tabletop').hasPrimaryFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(
          Focus.of(tester.element(find.text('Filters'))).hasPrimaryFocus,
          isTrue,
        );
      });
    });
  });

  group('during a first sync, an expansion before its base game (#810)', () {
    final thumbs = _FakeLayouts()..stored = ListLayout.thumbnails;
    const link = [ExpansionLink(gameId: 'g-base', isStandalone: false)];
    final base = listItem('b-1', gameId: 'g-base', title: 'Wingspan');
    final expansion = listItem(
      'x-1',
      gameId: 'g-exp',
      title: 'European Expansion',
      contentType: ContentType.expansion,
      baseGames: link,
    );
    final other = listItem('o-1', gameId: 'g-other', title: 'Azul');
    const marker = 'Base game not in your collection';

    final views = <(String, Key Function(String), ListLayoutRepository?)>[
      ('the list', GameCollectionListScreen.rowKey, null),
      ('thumbnails', GameCollectionListScreen.tileKey, thumbs),
    ];

    for (final (view, topKey, layouts) in views) {
      testWidgets('is held, then appears under its base game, in $view', (
        tester,
      ) async {
        // Covers that open carry a badge; inert ones don't.
        await tester.pumpWidget(harness(layouts: layouts, onOpen: (_, _) {}));
        status.started();
        items.add([expansion, other]);
        await tester.pump();
        await tester.pump();

        expect(find.byKey(topKey('x-1')), findsNothing);
        expect(find.byKey(topKey('o-1')), findsOneWidget);
        expect(find.textContaining(marker), findsNothing);

        // The base game's page lands.
        items.add([expansion, other, base]);
        await tester.pump();
        expect(find.byKey(topKey('x-1')), findsNothing);
        await tester.pump();
        expect(find.byKey(topKey('x-1')), findsNothing);
        expect(find.byKey(topKey('b-1')), findsOneWidget);
        if (layouts == null) {
          // Under its base game, folded: the control counts it, and opens
          // its row (#1048).
          final control = controlOf(find.byKey(topKey('b-1')));
          expect(
            find.descendant(of: control, matching: find.text('1')),
            findsOneWidget,
          );
          await unfold(tester, find.byKey(topKey('b-1')));
          expect(
            find.byKey(GameCollectionListScreen.nestedRowKey('g-base', 'x-1')),
            findsOneWidget,
          );
        } else {
          // Under its base game: the badge counts it, and its strip holds
          // its cover.
          final badge = find.descendant(
            of: find.byKey(topKey('b-1')),
            matching: find.byKey(BgeCoverTile.expansionsBadgeKey),
          );
          expect(
            find.descendant(of: badge, matching: find.text('1')),
            findsOneWidget,
          );
          await tester.tap(badge);
          await tester.pumpAndSettle();
          expect(
            find.byKey(GameCollectionListScreen.nestedTileKey('g-base', 'x-1')),
            findsOneWidget,
          );
        }

        status.finished(CollectionHydrateOutcome.complete);
        await tester.pumpAndSettle();
        expect(find.byKey(topKey('x-1')), findsNothing);
        expect(find.textContaining(marker), findsNothing);
      });

      testWidgets('is released, marked, by a first sync that fails, in '
          '$view', (tester) async {
        await tester.pumpWidget(harness(layouts: layouts));
        status.started();
        items.add([expansion, other]);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(topKey('x-1')), findsNothing);

        status.finished(CollectionHydrateOutcome.failed);
        await tester.pumpAndSettle();

        expect(find.byKey(topKey('x-1')), findsOneWidget);
        if (layouts == null) {
          expect(find.textContaining(marker), findsOneWidget);
        } else {
          // A cover says it in its label, not in text.
          final handle = tester.ensureSemantics();
          expect(
            tester.getSemantics(find.byKey(topKey('x-1'))).label,
            contains(marker),
          );
          handle.dispose();
        }
      });
    }

    for (final (view, topKey, layouts) in views) {
      testWidgets('with every game held, the loading state stands in for '
          'the list, in $view', (tester) async {
        await tester.pumpWidget(harness(layouts: layouts));
        status.started();
        items.add([expansion]);
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(GameCollectionListScreen.loadingKey),
          findsOneWidget,
        );
        expect(find.byKey(topKey('x-1')), findsNothing);
        // No row is drawn, so the page counts none.
        expect(
          tester
              .widget<CustomScrollView>(find.byType(CustomScrollView))
              .semanticChildCount,
          isNull,
        );

        status.finished(CollectionHydrateOutcome.failed);
        await tester.pumpAndSettle();

        expect(find.byKey(GameCollectionListScreen.loadingKey), findsNothing);
        expect(find.byKey(topKey('x-1')), findsOneWidget);
      });
    }

    testWidgets("the page's semanticChildCount counts the rows drawn, in the "
        'list', (tester) async {
      await tester.pumpWidget(harness());
      status.started();
      items.add([expansion, other]);
      await tester.pump();
      await tester.pump();

      int count() => tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount!;
      expect(count(), 1);

      status.finished(CollectionHydrateOutcome.failed);
      await tester.pumpAndSettle();
      expect(count(), 2);
    });

    testWidgets("the page's semanticChildCount counts the covers drawn, in "
        'thumbnails', (tester) async {
      await tester.pumpWidget(harness(layouts: thumbs));
      status.started();
      items.add([expansion, other]);
      await tester.pump();
      await tester.pump();

      int count() => tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount!;
      expect(count(), 1);

      status.finished(CollectionHydrateOutcome.failed);
      await tester.pumpAndSettle();
      expect(count(), 2);
    });
  });

  group('a game owned more than once (#709)', () {
    final thumbs = _FakeLayouts()..stored = ListLayout.thumbnails;

    GameCollectionListItem wingspan(
      String id,
      String platformName, {
      GameMedium medium = GameMedium.physical,
      bool? favorite,
      PlatformType? platformType,
    }) => listItem(
      id,
      gameId: 'g-wingspan',
      title: 'Wingspan',
      platformName: platformName,
      medium: medium,
      favorite: favorite,
      platformType: platformType,
    );

    final twice = [wingspan('e-1', 'Tabletop'), wingspan('e-2', 'Steam')];

    // The two views a stack is drawn in: its key there, and the layout store
    // that opens the screen in it.
    final views = <(String, Key Function(String), ListLayoutRepository?)>[
      ('the list', GameCollectionListScreen.stackKey, null),
      ('thumbnails', GameCollectionListScreen.stackTileKey, thumbs),
    ];

    Finder pickerTile(String entryId) =>
        find.byKey(CollectionEntryPicker.tileKey(entryId));

    for (final (view, stackKey, layouts) in views) {
      final stack = find.byKey(stackKey('g-wingspan'));

      testWidgets('a game with two entries shows once, with the marker and '
          'count, in $view', (tester) async {
        await show(tester, twice, layouts: layouts);

        expect(stack, findsOneWidget);
        final badge = find.descendant(
          of: stack,
          matching: find.byKey(BgeStackMarker.badgeKey),
        );
        expect(badge, findsOneWidget);
        expect(
          find.descendant(of: badge, matching: find.text('2')),
          findsOneWidget,
        );
        for (final id in ['e-1', 'e-2']) {
          expect(find.byKey(GameCollectionListScreen.rowKey(id)), findsNothing);
          expect(
            find.byKey(GameCollectionListScreen.tileKey(id)),
            findsNothing,
          );
        }
      });

      testWidgets('tapping a stack opens the picker; a tile opens that '
          'entry, in $view', (tester) async {
        final opened = <String>[];
        await show(
          tester,
          twice,
          layouts: layouts,
          onOpen: (_, id) => opened.add(id),
        );

        await tester.tap(stack);
        await tester.pumpAndSettle();

        expect(opened, isEmpty);
        expect(pickerTile('e-1'), findsOneWidget);
        expect(pickerTile('e-2'), findsOneWidget);

        await tester.tap(pickerTile('e-2'));
        await tester.pump();

        expect(opened, ['e-2']);
      });

      testWidgets('closing the picker returns focus to the stack, in $view', (
        tester,
      ) async {
        // A touch, which gives a list row no focus of its own: the picker's
        // route would hand focus back to the page, not to the stack.
        await show(tester, twice, layouts: layouts, onOpen: (_, _) {});

        await tester.tap(stack);
        await tester.pumpAndSettle();
        expect(pickerTile('e-1'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(pickerTile('e-1'), findsNothing);
        expect(_focusIsWithin(tester, stack), isTrue);
      });

      testWidgets('without onOpen a stack is inert, in $view', (tester) async {
        await show(tester, twice, layouts: layouts);

        expect(
          tester.getSemantics(stack),
          isSemantics(isButton: false, hasTapAction: false, isFocusable: false),
        );
      });
    }

    testWidgets('a stack is named with its count and what is owned', (
      tester,
    ) async {
      await show(tester, twice, layouts: thumbs);

      expect(
        tester
            .getSemantics(
              find.byKey(GameCollectionListScreen.stackTileKey('g-wingspan')),
            )
            .label,
        contains('Wingspan, 2 copies: Tabletop, Steam'),
      );
    });

    testWidgets("a stack's row is named with its title and its copies", (
      tester,
    ) async {
      await show(tester, twice);

      final label = mergedNode(
        tester,
        find.byKey(GameCollectionListScreen.stackKey('g-wingspan')),
      ).label;
      // The title first, then the copies, as a screen reader meets them.
      expect(
        label,
        matches(RegExp('Wingspan.*2 copies: Tabletop, Steam', dotAll: true)),
      );
      expect(find.text('2 copies: Tabletop, Steam'), findsOneWidget);
    });

    testWidgets('two mediums on one platform are a stack', (tester) async {
      await show(tester, [
        wingspan('e-1', 'Steam'),
        wingspan('e-2', 'Steam', medium: GameMedium.digital),
      ]);

      final stack = find.byKey(GameCollectionListScreen.stackKey('g-wingspan'));
      expect(stack, findsOneWidget);
      expect(
        find.text('2 copies: Steam · Physical, Steam · Digital'),
        findsOneWidget,
      );
      // No comma inside an entry: it would read as a third copy.
      expect(
        mergedNode(tester, stack).label,
        contains('2 copies: Steam Physical, Steam Digital'),
      );
    });

    testWidgets(
      'an existing Tabletop · Digital entry still shows (#797)',
      (tester) async {
        await show(tester, [
          wingspan('e-1', 'Tabletop', platformType: PlatformType.tabletop),
          wingspan(
            'e-2',
            'Tabletop',
            medium: GameMedium.digital,
            platformType: PlatformType.tabletop,
          ),
        ]);

        final stack = find.byKey(
          GameCollectionListScreen.stackKey('g-wingspan'),
        );
        expect(stack, findsOneWidget);
        expect(
          find.text('2 copies: Tabletop · Physical, Tabletop · Digital'),
          findsOneWidget,
        );
        // No comma inside an entry: it would read as a third copy.
        expect(
          mergedNode(tester, stack).label,
          contains('2 copies: Tabletop Physical, Tabletop Digital'),
        );
      },
    );

    final oneFavorite = [
      wingspan('e-1', 'Tabletop'),
      wingspan('e-2', 'Steam', favorite: true),
    ];

    testWidgets("a stack's row is a favorite when any of its entries is", (
      tester,
    ) async {
      await show(tester, oneFavorite);

      final row = find.byKey(GameCollectionListScreen.stackKey('g-wingspan'));
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.favorite)),
        findsOneWidget,
      );
      expect(mergedNode(tester, row).label, contains('Favorite'));
    });

    testWidgets("a stack's cover is a favorite when any of its entries is", (
      tester,
    ) async {
      await show(tester, oneFavorite, layouts: thumbs);

      expect(
        find.bySemanticsLabel('Wingspan, 2 copies: Tabletop, Steam, Favorite'),
        findsOneWidget,
      );
    });

    testWidgets('a game with one entry opens it directly', (tester) async {
      final opened = <String>[];
      await show(
        tester,
        [...twice, listItem('e-3', title: 'Wyrmspan')],
        layouts: thumbs,
        onOpen: (_, id) => opened.add(id),
      );

      await tester.tap(find.byKey(GameCollectionListScreen.tileKey('e-3')));
      await tester.pumpAndSettle();

      expect(opened, ['e-3']);
      expect(pickerTile('e-3'), findsNothing);
    });

    testWidgets('the list counts games, not entries', (tester) async {
      await show(tester, [...twice, listItem('e-3', title: 'Wyrmspan')]);

      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .semanticChildCount,
        2,
      );
    });

    testWidgets('after a mouse click, focus handed back to a row is '
        'untinted, until it comes back from the keyboard', (tester) async {
      // A mouse leaves the highlight mode at the keyboard's on a desktop,
      // so focus the click gave would draw the row's focus tint once the
      // picker closed, as no keyboard user asked for (#707's cover tile).
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: harness(onOpen: (_, _) {}),
        ),
      );
      status.finished(CollectionHydrateOutcome.complete);
      items.add(twice);
      await tester.pumpAndSettle();

      final stack = find.byKey(GameCollectionListScreen.stackKey('g-wingspan'));
      // Inside the row, past its text, where only the row's own tint draws.
      final rect = tester.getRect(stack);
      final blank = Offset(rect.right - 8, rect.center.dy);

      Future<Color> pixel() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = (await image.toByteData())!;
          final at = (blank.dy.floor() * image.width + blank.dx.floor()) * 4;
          return Color.fromARGB(
            bytes.getUint8(at + 3),
            bytes.getUint8(at),
            bytes.getUint8(at + 1),
            bytes.getUint8(at + 2),
          );
        }))!;
      }

      final unfocused = await pixel();
      const away = Offset(4, 590);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: away);
      addTearDown(mouse.removePointer);
      Future<void> click(Offset at) async {
        await mouse.moveTo(at);
        await mouse.down(at);
        await tester.pump(const Duration(milliseconds: 50));
        await mouse.up();
        await mouse.moveTo(away);
        await tester.pumpAndSettle();
      }

      await click(blank);
      expect(pickerTile('e-1'), findsOneWidget);
      // Closed by a click on the barrier, below the dialog.
      await click(away);
      expect(pickerTile('e-1'), findsNothing);

      expect(_focusIsWithin(tester, stack), isTrue);
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      expect(await pixel(), unfocused);

      // The key press ends the pointer's focus. The tint drawn without
      // strength keeps it, so the row's focus shows from its next focus.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_focusIsWithin(tester, stack), isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(_focusIsWithin(tester, stack), isTrue);
      expect(await pixel(), isNot(unfocused));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('accessibility audit', () {
    /// A row with every detail and the favourite, plain ones enough to run
    /// below the fold at both viewports, as rows and as covers, and last a
    /// digital one with a rating alone, which the end's call has on screen.
    List<GameCollectionListItem> rows() => [
      listItem(
        'e-1',
        title: 'Twilight Imperium',
        subtitle: 'Fourth Edition',
        quantity: 2,
        rating: 9,
        favorite: true,
        lastPlayed: DateTime(2026, 10, 3),
      ),
      for (var i = 2; i < 30; i++) listItem('e-$i', title: 'Game $i'),
      listItem(
        'e-30',
        title: 'Azul',
        platformName: 'PC',
        medium: GameMedium.digital,
        rating: 7,
      ),
    ];

    /// Wingspan owned twice, one of the two a favourite, as one stack above
    /// two games owned once.
    List<GameCollectionListItem> stacked() => [
      listItem(
        'w-1',
        gameId: 'g-wingspan',
        title: 'Wingspan',
        platformName: 'Tabletop',
      ),
      listItem(
        'w-2',
        gameId: 'g-wingspan',
        title: 'Wingspan',
        platformName: 'Steam',
        medium: GameMedium.digital,
        favorite: true,
      ),
      listItem('e-1', title: 'Azul'),
      listItem('e-2', title: 'Brass'),
    ];

    ListLayoutRepository thumbnails() =>
        _FakeLayouts()..stored = ListLayout.thumbnails;

    /// The screen in [theme], with a way to open an entry unless [open] is
    /// false: the composition offers one only to a user who may write the
    /// collection. With a retry too, so the app bar's refresh button is held
    /// to the same checks in every state (#717); the shell passes one
    /// wherever it has a collection client.
    ///
    /// [seam] false is the composition with no refresh seam, which has
    /// neither the button nor the gesture.
    Widget Function(ThemeData) screen({
      bool open = true,
      bool seam = true,
      void Function(BuildContext context)? onBrowse,
      Future<void> Function()? onRetry,
      ListLayoutRepository? layouts,
    }) =>
        (theme) => harness(
          theme: theme,
          onOpen: open ? (_, _) {} : null,
          onBrowse: onBrowse,
          onRetry: seam ? onRetry ?? () async {} : null,
          layouts: layouts,
        );

    /// The app bar's refresh button, at rest or busy.
    void expectRefreshButton({bool refreshing = false}) {
      expect(
        find.byKey(GameCollectionListScreen.refreshButtonKey),
        findsOneWidget,
      );
      expect(
        find.byTooltip(refreshing ? _refreshingCopy : _refreshCopy),
        findsOneWidget,
      );
    }

    /// The hydrate settled and the cache answered [cached].
    Future<void> answer(
      WidgetTester tester,
      List<GameCollectionListItem> cached,
    ) async {
      status.finished(CollectionHydrateOutcome.complete);
      items.add(cached);
      await tester.pumpAndSettle();
    }

    final stack = find.byKey(GameCollectionListScreen.stackKey('g-wingspan'));
    final stackTile = find.byKey(
      GameCollectionListScreen.stackTileKey('g-wingspan'),
    );

    GameCollectionListState listState(WidgetTester tester) =>
        BlocProvider.of<GameCollectionListBloc>(
          tester.element(find.byType(GameCollectionListSliver)),
        ).state;

    // A first fill: the spinner never settles.
    auditScreen(
      'loading',
      build: screen(),
      settle: false,
      arrange: (tester) async {
        status.started();
        items.add(const []);
        await tester.pump();
        expect(find.byKey(GameCollectionListScreen.loadingKey), findsOneWidget);
        expect(listState(tester), isA<GameCollectionListLoading>());
        expectRefreshButton();
      },
    );

    // The rows are in, but the remembered layout isn't read yet, so the
    // loading state stands in for them.
    auditScreen(
      'loading, the layout read held',
      build: screen(layouts: _FakeLayouts()..hold = Completer<ListLayout?>()),
      settle: false,
      arrange: (tester) async {
        status.finished(CollectionHydrateOutcome.complete);
        items.add(rows());
        await tester.pump();
        expect(find.byKey(GameCollectionListScreen.loadingKey), findsOneWidget);
        expect(listState(tester), isA<GameCollectionListReady>());
        expect(
          find.byKey(GameCollectionListScreen.rowKey('e-1')),
          findsNothing,
        );
        expectRefreshButton();
      },
    );

    auditScreen(
      'error',
      build: screen(),
      arrange: (tester) async {
        items.addError(StateError('no authenticated user'));
        await tester.pumpAndSettle();
        expect(find.byKey(GameCollectionListScreen.errorKey), findsOneWidget);
        expect(find.text(_errorCopy), findsOneWidget);
        expectRefreshButton();
      },
    );

    auditScreen(
      'empty, with Browse',
      build: screen(onBrowse: (_) {}),
      arrange: (tester) async {
        await answer(tester, const []);
        expect(find.byKey(GameCollectionListScreen.browseKey), findsOneWidget);
        expectRefreshButton();
      },
    );

    auditScreen(
      'ready, list',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, rows());
        expect(
          find.byKey(GameCollectionListScreen.rowKey('e-1')),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.favorite), findsOneWidget);
        expect(
          rowSemantics(tester, 'e-1'),
          isSemantics(isButton: true, hasTapAction: true),
        );
        expectRefreshButton();
      },
    );

    // A composition with no refresh seam: no button in the app bar, and no
    // gesture (#717).
    auditScreen(
      'ready, list, with no refresh seam',
      build: screen(seam: false),
      arrange: (tester) async {
        await answer(tester, rows());
        expect(
          find.byKey(GameCollectionListScreen.rowKey('e-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(GameCollectionListScreen.refreshButtonKey),
          findsNothing,
        );
        expect(find.byType(RefreshIndicator), findsNothing);
      },
    );

    // The rows are built only as the list reaches them (#50).
    auditScreen(
      'ready, list, scrolled to the end',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, rows());
        await scrollListToEnd(
          tester,
          find.byKey(GameCollectionListScreen.rowKey('e-30')),
        );
      },
    );

    // Without a way to open an entry, for a user who may not write the
    // collection: the rows and the stack are content, not controls.
    auditScreen(
      'ready, rows that open nowhere',
      build: screen(open: false),
      arrange: (tester) async {
        await answer(tester, stacked());
        // At 320dp × 2.0 the header (#715) leaves the rows below the fold.
        await useWholePage(tester);
        expect(stack, findsOneWidget);
        expect(
          rowSemantics(tester, 'e-1'),
          isSemantics(isButton: false, hasTapAction: false),
        );
      },
    );

    auditScreen(
      'ready, thumbnails',
      build: screen(layouts: thumbnails()),
      arrange: (tester) async {
        await answer(tester, rows());
        expect(
          find.byKey(GameCollectionListScreen.tileKey('e-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(GameCollectionListScreen.rowKey('e-1')),
          findsNothing,
        );
        expectRefreshButton();
      },
    );

    auditScreen(
      'ready, thumbnails, scrolled to the end',
      build: screen(layouts: thumbnails()),
      arrange: (tester) async {
        await answer(tester, rows());
        await scrollListToEnd(
          tester,
          find.byKey(GameCollectionListScreen.tileKey('e-30')),
        );
      },
    );

    // A game owned twice: one row, its cover marked with the count, and the
    // copies in place of an entry's details.
    auditScreen(
      'ready, a stack row',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, stacked());
        expect(stack, findsOneWidget);
        expect(
          find.descendant(of: stack, matching: find.text('2')),
          findsOneWidget,
        );
        expect(find.text('2 copies: Tabletop, Steam'), findsOneWidget);
      },
    );

    auditScreen(
      'ready, a stack, in thumbnails',
      build: screen(layouts: thumbnails()),
      arrange: (tester) async {
        await answer(tester, stacked());
        expect(stackTile, findsOneWidget);
        expect(
          find.descendant(of: stackTile, matching: find.text('2')),
          findsOneWidget,
        );
      },
    );

    // The stack's picker, a sheet at both viewports.
    auditScreen(
      'entry picker open',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, stacked());
        await tester.tap(stack);
        await tester.pumpAndSettle();
        expect(
          find.byKey(CollectionEntryPicker.tileKey('w-1')),
          findsOneWidget,
        );
        // The last tile is on screen, not only built, and nothing of the
        // picker, which scrolls on its own, is below its fold.
        final last = find.byKey(CollectionEntryPicker.tileKey('w-2'));
        expect(last.hitTestable(), findsOneWidget);
        expectWholePage(
          tester,
          within: find
              .ancestor(of: last, matching: find.byType(Scrollable))
              .first,
        );
      },
    );

    auditScreen(
      'refresh failed, with retry',
      build: screen(onRetry: () async {}),
      arrange: (tester) async {
        items.add(rows());
        status.finished(CollectionHydrateOutcome.failed);
        await tester.pumpAndSettle();
        expect(find.text(_refreshFailedCopy), findsOneWidget);
        expect(
          find.byKey(GameCollectionListScreen.refreshRetryKey),
          findsOneWidget,
        );
        expectRefreshButton();
      },
    );

    /// The banner over an empty collection, which it qualifies rather than
    /// replaces.
    Future<void> failedOverEmpty(WidgetTester tester) async {
      items.add(const []);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pumpAndSettle();
      expect(find.text(_refreshFailedCopy), findsOneWidget);
    }

    auditScreen(
      'refresh failed, over an empty collection',
      build: screen(onBrowse: (_) {}, onRetry: () async {}),
      arrange: failedOverEmpty,
    );

    // At 320dp × 2.0 the banner pushes Browse below the fold (#50).
    auditScreen(
      'refresh failed, over an empty collection, scrolled to the end',
      build: screen(onBrowse: (_) {}, onRetry: () async {}),
      arrange: (tester) async {
        await failedOverEmpty(tester);
        await scrollPageToEnd(tester);
        expect(find.byKey(GameCollectionListScreen.browseKey), findsOneWidget);
      },
    );

    /// Wingspan with [count] owned expansions nested under it (#711): five
    /// overflow its strip, so the shelf shows its buttons, and in the list
    /// more than four are a box of rows once unfolded (#1048). Then an owned
    /// expansion whose base game isn't owned, marked, and two plain games.
    List<GameCollectionListItem> withExpansions([int count = 5]) => [
      listItem('base-1', gameId: 'g-base', title: 'Wingspan'),
      for (var n = 0; n < count; n++)
        listItem(
          'exp-$n',
          gameId: 'g-exp-$n',
          title: 'Wingspan expansion $n',
          contentType: ContentType.expansion,
          baseGames: const [
            ExpansionLink(gameId: 'g-base', isStandalone: false),
          ],
        ),
      listItem(
        'orphan-1',
        gameId: 'g-orphan',
        title: 'Seafarers',
        contentType: ContentType.expansion,
        baseGames: const [
          ExpansionLink(gameId: 'g-catan', isStandalone: false),
        ],
      ),
      listItem('e-1', title: 'Azul'),
      listItem('e-2', title: 'Brass'),
    ];

    final baseTile = find.byKey(GameCollectionListScreen.tileKey('base-1'));
    final badge = find.descendant(
      of: baseTile,
      matching: find.byKey(BgeCoverTile.expansionsBadgeKey),
    );
    final baseRow = find.byKey(GameCollectionListScreen.rowKey('base-1'));
    final nestedBox = find.byType(BgeNestedRowsBox);

    auditScreen(
      'ready, nested expansions and a marked one',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, withExpansions());
        await unfold(tester, baseRow);
        expect(
          find.byKey(GameCollectionListScreen.nestedRowKey('g-base', 'exp-0')),
          findsOneWidget,
        );
      },
    );

    // The marked row is below the fold at 320dp × 2.0, under the nested
    // ones.
    auditScreen(
      'ready, nested expansions and a marked one, scrolled to the end',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, withExpansions());
        await unfold(tester, baseRow);
        await scrollListToEnd(
          tester,
          find.byKey(GameCollectionListScreen.rowKey('e-2')),
        );
        expect(
          find.byKey(GameCollectionListScreen.rowKey('orphan-1')),
          findsOneWidget,
        );
      },
    );

    // Wingspan's five behind its control, with the marked row after it.
    auditScreen(
      'ready, a folded base game (#1048)',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, withExpansions());
        expect(controlOf(baseRow), findsOneWidget);
        expect(
          find.byKey(
            GameCollectionListScreen.nestedRowKey('g-base', 'exp-0'),
            skipOffstage: false,
          ),
          findsNothing,
        );
      },
    );

    auditScreen(
      'ready, a base game unfolded, 4 nested rows (#1048)',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, withExpansions(4));
        await unfold(tester, baseRow);
        expect(
          find.byKey(GameCollectionListScreen.nestedRowKey('g-base', 'exp-0')),
          findsOneWidget,
        );
        expect(nestedBox, findsNothing);
      },
    );

    // At 320dp × 2.0 the box is held to half the page, less than a row.
    auditScreen(
      'ready, a base game unfolded, 6 nested rows in a box (#1048)',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, withExpansions(6));
        await unfold(tester, baseRow);
        await tester.ensureVisible(nestedBox);
        expect(nestedBox, findsOneWidget);
        expect(
          find.byKey(GameCollectionListScreen.nestedRowKey('g-base', 'exp-0')),
          findsOneWidget,
        );
      },
    );

    // Rows that open nowhere take no focus, so the box is a stop itself
    // (#1048).
    auditScreen(
      'ready, rows that open nowhere, a base game unfolded, 6 nested rows in '
      'a box (#1048)',
      build: screen(open: false),
      arrange: (tester) async {
        await answer(tester, withExpansions(6));
        await unfold(tester, baseRow);
        await tester.ensureVisible(nestedBox);
        expect(
          tester.widget<BgeNestedRowsBox>(nestedBox).focusable,
          isTrue,
        );
      },
    );

    auditScreen(
      'ready, thumbnails, a badged cover and a marked one',
      build: screen(layouts: thumbnails()),
      arrange: (tester) async {
        await answer(tester, withExpansions());
        expect(badge, findsOneWidget);
        expect(
          find.byKey(GameCollectionListScreen.tileKey('orphan-1')),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'ready, thumbnails, a strip unfolded',
      build: screen(layouts: thumbnails()),
      arrange: (tester) async {
        await answer(tester, withExpansions());
        await tester.tap(badge);
        await tester.pumpAndSettle();
        expect(find.text('Wingspan expansions'), findsOneWidget);
        expect(find.byKey(BgeShelf.previousKey), findsOneWidget);
        expect(find.byKey(BgeShelf.nextKey), findsOneWidget);
        expect(
          find.byKey(GameCollectionListScreen.nestedTileKey('g-base', 'exp-0')),
          findsOneWidget,
        );
      },
    );

    // The retry's pass never ends, so the busy button never settles.
    auditScreen(
      'refreshing',
      build: screen(onRetry: () => Completer<void>().future),
      settle: false,
      arrange: (tester) async {
        items.add(rows());
        status.finished(CollectionHydrateOutcome.failed);
        await tester.pumpAndSettle();
        // Below the header (#715), at 320dp × 2.0 below the fold. Once
        // pressed, the busy banner is shorter, and the page goes back to its
        // top, where the banner now is.
        final retry = find.byKey(GameCollectionListScreen.refreshRetryKey);
        await tester.ensureVisible(retry);
        await tester.pumpAndSettle();
        await tester.tap(retry);
        await tester.pump();
        status.started();
        await tester.pump();
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pump();
        expect(find.text(_refreshingCopy), findsNWidgets(2));
        expectRefreshButton(refreshing: true);
      },
    );

    GameCollectionListBloc auditBloc(WidgetTester tester) =>
        BlocProvider.of<GameCollectionListBloc>(
          tester.element(find.byType(GameCollectionListSliver)),
        );

    /// Two filters in use, the platform one flipped, which keep every row
    /// but Azul, and the order with the longest name (#715).
    const twoFilters = CollectionFilter(
      mediums: {GameMedium.physical},
      game: GameSearchFilter(platformTypes: {PlatformType.pc}),
      excluded: {CollectionFacet.platformType},
    );

    /// [rows] under [twoFilters], most recently added first: the header at
    /// its fullest, with both chips and the count.
    Future<void> narrowed(WidgetTester tester) async {
      await answer(tester, rows());
      auditBloc(tester)
        ..add(const GameCollectionListFilterChanged(twoFilters))
        ..add(
          const GameCollectionListSortChanged(CollectionSort.recentlyAdded),
        );
      await tester.pumpAndSettle();
      expect(
        find.byKey(GameFilterKeys.inUse('platform_pc')),
        findsOneWidget,
      );
      expect(
        find.byKey(GameFilterKeys.inUse('medium_physical')),
        findsOneWidget,
      );
      expect(find.text('29 games of 30'), findsOneWidget);
      expect(find.text('Sort: Recently added'), findsOneWidget);
    }

    auditScreen(
      'ready, two filters in use and a sort',
      build: screen(),
      arrange: narrowed,
    );

    auditScreen(
      'ready, two filters in use and a sort, in thumbnails',
      build: screen(layouts: thumbnails()),
      arrange: narrowed,
    );

    auditScreen(
      'no games match',
      build: screen(),
      arrange: (tester) async {
        await answer(tester, rows());
        auditBloc(tester).add(
          const GameCollectionListFilterChanged(
            CollectionFilter(query: 'nothing has this name'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(GameCollectionListScreen.noMatchesKey),
          findsOneWidget,
        );
        expect(
          find.byKey(GameCollectionListScreen.clearFiltersKey),
          findsOneWidget,
        );
        expectRefreshButton();
      },
    );

    // The collection's sheet: Medium, the missing base game and a flip
    // under each section, on top of the game search's.
    auditScreen(
      'filter sheet open',
      build: screen(),
      arrange: (tester) async {
        await narrowed(tester);
        await tester.tap(find.byKey(GameFilterKeys.button));
        await tester.pumpAndSettle();
        expect(find.byKey(GameFilterKeys.sheet), findsOneWidget);
      },
    );

    auditScreen(
      'sort menu open',
      build: screen(),
      arrange: (tester) async {
        await narrowed(tester);
        await tester.tap(find.byKey(GameCollectionListScreen.sortButtonKey));
        await tester.pumpAndSettle();
        expect(
          find.byKey(GameCollectionListScreen.sortKey(CollectionSort.rating)),
          findsOneWidget,
        );
      },
    );

    for (final (layout, store, shown) in [
      ('the list', null, 2),
      ('thumbnails', thumbnails(), 1),
    ]) {
      testWidgets('under a filter, the semantic child count is what '
          '$layout shows', (tester) async {
        // Wingspan's five expansions are a box of rows under it in the list,
        // once unfolded, which counts once (#1048), and its cover's strip in
        // thumbnails.
        await tester.pumpWidget(screen(layouts: store)(BgeTheme.light()));
        await answer(tester, withExpansions());
        auditBloc(tester).add(
          const GameCollectionListFilterChanged(
            CollectionFilter(query: 'wingspan'),
          ),
        );
        await tester.pumpAndSettle();
        if (store == null) await unfold(tester, baseRow);

        expect(find.text('6 games of 9'), findsOneWidget);
        expect(
          find.byKey(GameCollectionListScreen.rowKey('orphan-1')),
          findsNothing,
        );
        expect(
          find.byKey(GameCollectionListScreen.tileKey('orphan-1')),
          findsNothing,
        );
        expect(
          tester
              .widget<CustomScrollView>(find.byType(CustomScrollView))
              .semanticChildCount,
          shown,
        );
      });
    }

    testWidgets('at 320dp and twice the text, each header control and its '
        'label are whole and on screen', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(screen()(BgeTheme.light()));
      await narrowed(tester);

      final screenRect = Offset.zero & const Size(320, 640);
      void expectWithin(Rect inner, Rect outer, String what) => expect(
        outer.inflate(0.5).contains(inner.topLeft) &&
            outer.inflate(0.5).contains(inner.bottomRight),
        isTrue,
        reason: '$what: $inner is not inside $outer',
      );

      /// [control] on screen and at least 48dp, and each text in it on one
      /// or more whole lines, painted inside it.
      void expectWhole(String what, Finder control) {
        final rect = tester.getRect(control);
        expectWithin(rect, screenRect, what);
        expect(rect.height, greaterThanOrEqualTo(48), reason: what);
        expect(rect.width, greaterThanOrEqualTo(48), reason: what);
        for (final label
            in find
                .descendant(of: control, matching: find.byType(RichText))
                .evaluate()) {
          final paragraph = label.renderObject! as RenderParagraph;
          // The painted rect, through any scaling above the text.
          expectWithin(
            tester.getRect(find.byElementPredicate((e) => e == label)),
            rect,
            '$what label',
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: what);
        }
      }

      final search = find.byKey(GameCollectionListScreen.searchKey);
      final searchLabel = find.descendant(
        of: search,
        matching: find.text('Search your collection'),
      );
      final controls = <String, Finder>{
        'search': search,
        'Filters': find.byKey(GameFilterKeys.button),
        'sort': find.byKey(GameCollectionListScreen.sortButtonKey),
        'layout': find.byKey(GameCollectionListScreen.layoutToggleKey),
        'PC chip': find.byKey(GameFilterKeys.inUse('platform_pc')),
        'Physical chip': find.byKey(GameFilterKeys.inUse('medium_physical')),
      };
      // The search's label is among the texts checked, resting.
      expect(searchLabel, findsOneWidget);
      for (final MapEntry(key: what, value: control) in controls.entries) {
        expectWhole(what, control);
      }
      expectWithin(
        tester.getRect(find.byKey(GameCollectionListScreen.resultCountKey)),
        screenRect,
        'count',
      );

      // And floating, once there is text: whole, on one line, across the
      // field. An outlined field floats its label onto its top border, so
      // the label straddles the field's top edge by design; it is held to
      // the screen there rather than to the field's box.
      await tester.enterText(search, 'Twilight');
      await tester.pumpAndSettle();
      expect(searchLabel, findsOneWidget);
      final field = tester.getRect(search);
      final floating = tester.getRect(searchLabel);
      expectWithin(floating, screenRect, 'floating search label');
      expect(floating.left, greaterThanOrEqualTo(field.left - 0.5));
      expect(floating.right, lessThanOrEqualTo(field.right + 0.5));
      expect(
        tester.renderObject<RenderParagraph>(searchLabel).didExceedMaxLines,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('expansions (#711)', () {
    final base = listItem('base-1', gameId: 'g-base', title: 'Wingspan');
    final expansion = listItem(
      'exp-1',
      gameId: 'g-exp',
      title: 'European Expansion',
      contentType: ContentType.expansion,
      baseGames: const [ExpansionLink(gameId: 'g-base', isStandalone: false)],
    );
    final baseRow = find.byKey(GameCollectionListScreen.rowKey('base-1'));

    testWidgets("an owned expansion's row sits under its base game's, "
        'indented, spoken as its expansion', (tester) async {
      await show(tester, [expansion, base]);
      await unfold(tester, baseRow);

      final nested = find.byKey(
        GameCollectionListScreen.nestedRowKey('g-base', 'exp-1'),
      );
      final top = find.byKey(GameCollectionListScreen.rowKey('base-1'));
      expect(nested, findsOneWidget);
      expect(
        tester.getTopLeft(nested).dy,
        greaterThan(tester.getTopLeft(top).dy),
      );
      expect(
        find.byKey(GameCollectionListScreen.rowKey('exp-1')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.text('European Expansion')).dx,
        greaterThan(tester.getTopLeft(find.text('Wingspan')).dx),
      );
      expect(
        mergedNode(tester, nested).label,
        contains('European Expansion, expansion for Wingspan'),
      );
    });

    testWidgets("a nested expansion row's outline starts at the indent "
        '(#647)', (tester) async {
      await show(tester, [expansion, base]);
      await unfold(tester, baseRow);

      double outlineStart(Finder row) => tester
          .getTopLeft(
            find.descendant(of: row, matching: find.byType(BgeOutlinedRow)),
          )
          .dx;
      expect(
        outlineStart(
          find.byKey(GameCollectionListScreen.nestedRowKey('g-base', 'exp-1')),
        ),
        outlineStart(find.byKey(GameCollectionListScreen.rowKey('base-1'))) +
            BgeTokens.standard.spaceLg,
      );
    });

    testWidgets('a nested stack keeps its picker', (tester) async {
      GameCollectionListItem copy(String id, String platform) => listItem(
        id,
        gameId: 'g-exp',
        title: 'European Expansion',
        platformName: platform,
        contentType: ContentType.expansion,
        baseGames: const [ExpansionLink(gameId: 'g-base', isStandalone: false)],
      );
      final opened = <String>[];
      await show(tester, [
        base,
        copy('exp-1', 'Tabletop'),
        copy('exp-2', 'Steam'),
      ], onOpen: (_, id) => opened.add(id));
      await unfold(tester, baseRow);

      final stack = find.byKey(
        GameCollectionListScreen.nestedStackKey('g-base', 'g-exp'),
      );
      expect(stack, findsOneWidget);
      expect(
        mergedNode(tester, stack).label,
        contains('European Expansion, expansion for Wingspan'),
      );
      await tester.tap(stack);
      await tester.pumpAndSettle();

      expect(
        find.byKey(CollectionEntryPicker.tileKey('exp-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(CollectionEntryPicker.tileKey('exp-2')),
        findsOneWidget,
      );
    });

    testWidgets("an orphan's row says its base game is missing", (
      tester,
    ) async {
      await show(tester, [
        listItem(
          'dlc-1',
          gameId: 'g-dlc',
          title: 'Season Pass',
          contentType: ContentType.dlc,
        ),
      ]);

      expect(
        find.textContaining('Base game not in your collection'),
        findsOneWidget,
      );
      expect(
        rowSemantics(tester, 'dlc-1').label,
        contains('Base game not in your collection'),
      );
    });

    testWidgets('a standalone game is not marked', (tester) async {
      await show(tester, [listItem('e-1')]);

      expect(
        find.textContaining('Base game not in your collection'),
        findsNothing,
      );
    });

    testWidgets("a parent's subtitle is spoken in its expansions' names", (
      tester,
    ) async {
      final catan = listItem(
        'c-1',
        gameId: 'g-catan',
        subtitle: 'Seafarers Edition',
      );
      final nested = listItem(
        'x-2',
        gameId: 'g-x',
        title: 'Cities',
        contentType: ContentType.expansion,
        baseGames: const [
          ExpansionLink(gameId: 'g-catan', isStandalone: false),
        ],
      );
      await show(tester, [catan, nested]);
      await unfold(tester, find.byKey(GameCollectionListScreen.rowKey('c-1')));

      final row = find.byKey(
        GameCollectionListScreen.nestedRowKey('g-catan', 'x-2'),
      );
      expect(
        mergedNode(tester, row).label,
        contains('Cities, expansion for Catan: Seafarers Edition'),
      );
    });

    testWidgets('the semantic child count counts the rows shown: nested '
        'ones while their base game is open, an expansion of two owned base '
        'games under each (#1048)', (tester) async {
      final baseB = listItem('base-2', gameId: 'g-base-b', title: 'Azul');
      final both = listItem(
        'exp-1',
        gameId: 'g-exp',
        title: 'European Expansion',
        contentType: ContentType.expansion,
        baseGames: const [
          ExpansionLink(gameId: 'g-base', isStandalone: false),
          ExpansionLink(gameId: 'g-base-b', isStandalone: false),
        ],
      );
      await show(tester, [base, baseB, both]);
      int? count() => tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .semanticChildCount;
      expect(count(), 2, reason: 'both folded');

      await unfold(tester, baseRow);
      await unfold(
        tester,
        find.byKey(GameCollectionListScreen.rowKey('base-2')),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(GameCollectionListScreen.nestedRowKey('g-base', 'exp-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(GameCollectionListScreen.nestedRowKey('g-base-b', 'exp-1')),
        findsOneWidget,
      );
      expect(count(), 4);
    });
  });

  group('folded in the list (#1048)', () {
    final wingspan = listItem('w-1', gameId: 'g-wingspan', title: 'Wingspan');
    final azul = listItem('a-1', gameId: 'g-azul', title: 'Azul');

    /// [count] expansions of [baseGameId], each owned once: entries
    /// `<prefix>0`, `<prefix>1` and on, of games `g-<prefix>0` and on.
    List<GameCollectionListItem> expansionsOf(
      String baseGameId,
      String prefix,
      int count,
    ) => [
      for (var i = 0; i < count; i++)
        listItem(
          '$prefix$i',
          gameId: 'g-$prefix$i',
          title: 'Expansion $prefix$i',
          contentType: ContentType.expansion,
          baseGames: [ExpansionLink(gameId: baseGameId, isStandalone: false)],
        ),
    ];

    /// Rows found whether or not they are in view.
    Finder row(String entryId) => find.byKey(
      GameCollectionListScreen.rowKey(entryId),
      skipOffstage: false,
    );
    Finder nested(String parentGameId, String entryId) => find.byKey(
      GameCollectionListScreen.nestedRowKey(parentGameId, entryId),
      skipOffstage: false,
    );
    final wingspanRow = row('w-1');
    final box = find.byType(BgeNestedRowsBox, skipOffstage: false);

    /// The control's own node: the ink inside it walks up to it.
    SemanticsNode controlNode(WidgetTester tester, Finder row) =>
        tester.getSemantics(
          find.descendant(
            of: controlOf(row),
            matching: find.byType(InkWell),
            skipOffstage: false,
          ),
        );

    /// The row's merged node, which its tile walks up to.
    SemanticsNode rowNode(WidgetTester tester, Finder row) =>
        tester.getSemantics(
          find.descendant(
            of: row,
            matching: find.byType(ListTile),
            skipOffstage: false,
          ),
        );

    /// The focus of [row]'s tile.
    FocusNode tileFocusOf(WidgetTester tester, Finder row) => tester
        .widget<ListTile>(
          find.descendant(
            of: row,
            matching: find.byType(ListTile),
            skipOffstage: false,
          ),
        )
        .focusNode!;

    /// The focus of the control at the end of [row].
    FocusNode controlFocusOf(WidgetTester tester, Finder row) => Focus.of(
      tester.element(
        find
            .descendant(
              of: controlOf(row),
              matching: find.byType(MouseRegion),
              skipOffstage: false,
            )
            .first,
      ),
    );

    /// The box's own stop, which it is where its rows take no focus.
    FocusNode boxFocusOf(WidgetTester tester) => tester
        .widget<Focus>(
          find.descendant(
            of: box,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Focus &&
                  widget.focusNode?.debugLabel == 'BgeNestedRowsBox',
            ),
            skipOffstage: false,
          ),
        )
        .focusNode!;

    void performCustomAction(SemanticsNode node, String label) =>
        node.owner!.performAction(
          node.id,
          SemanticsAction.customAction,
          CustomSemanticsAction.getIdentifier(
            CustomSemanticsAction(label: label),
          ),
        );

    Matcher isControl(String label, {required bool expanded}) => isSemantics(
      label: label,
      isButton: true,
      hasExpandedState: true,
      isExpanded: expanded,
      hasTapAction: true,
      isFocusable: true,
    );

    int? semanticChildCount(WidgetTester tester) => tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .semanticChildCount;

    /// A sync that leaves the cache holding [rows].
    Future<void> sync(
      WidgetTester tester,
      List<GameCollectionListItem> rows,
    ) async {
      items.add(rows);
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
    }

    GameCollectionListBloc bloc(WidgetTester tester) =>
        BlocProvider.of<GameCollectionListBloc>(
          tester.element(find.byType(GameCollectionListSliver)),
        );

    testWidgets('list starts folded: a base game shows its control and no '
        'nested rows', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 2),
        azul,
      ], onOpen: (_, _) {});

      expect(wingspanRow, findsOneWidget);
      expect(row('a-1'), findsOneWidget);
      expect(nested('g-wingspan', 'x0'), findsNothing);
      expect(nested('g-wingspan', 'x1'), findsNothing);
      expect(row('x0'), findsNothing);
      expect(
        find.descendant(of: controlOf(wingspanRow), matching: find.text('2')),
        findsOneWidget,
      );
      expect(
        controlNode(tester, wingspanRow),
        isControl('Wingspan expansions, 2', expanded: false),
      );
      expect(controlOf(row('a-1')), findsNothing);
      // The control is a node of its own, after the row's, and the row
      // offers the cover's custom action.
      expect(
        rowNode(tester, wingspanRow).id,
        isNot(controlNode(tester, wingspanRow).id),
      );
      expect(
        rowNode(tester, wingspanRow),
        isSemantics(
          hasTapAction: true,
          customActions: [
            const CustomSemanticsAction(label: 'Show expansions'),
          ],
        ),
      );
      expect(semanticChildCount(tester), 2);
      handle.dispose();
    });

    testWidgets('unfolding 2 shows them inline; unfolding 6 shows a box of '
        '6', (tester) async {
      final handle = tester.ensureSemantics();
      useViewSize(tester, const Size(400, 2400));
      await show(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 2),
        azul,
        ...expansionsOf('g-azul', 'y', 6),
      ], onOpen: (_, _) {});

      await unfold(tester, wingspanRow);

      for (final id in ['x0', 'x1']) {
        expect(nested('g-wingspan', id), findsOneWidget, reason: id);
      }
      expect(box, findsNothing);
      expect(
        controlNode(tester, wingspanRow),
        isControl('Wingspan expansions, 2', expanded: true),
      );
      expect(
        rowNode(tester, wingspanRow),
        isSemantics(
          hasTapAction: true,
          customActions: [
            const CustomSemanticsAction(label: 'Hide expansions'),
          ],
        ),
      );
      // Under Wingspan's row, and above Azul's.
      expect(
        tester.getRect(nested('g-wingspan', 'x1')).bottom,
        lessThanOrEqualTo(tester.getRect(row('a-1')).top),
      );

      await unfold(tester, row('a-1'));

      expect(box, findsOneWidget);
      expect(
        tester.widget<BgeNestedRowsBox>(box).semanticLabel,
        'Azul expansions',
      );
      expect(tester.widget<BgeNestedRowsBox>(box).focusable, isFalse);
      // Each row in the box keeps its key.
      for (var i = 0; i < 6; i++) {
        expect(
          find.descendant(of: box, matching: nested('g-azul', 'y$i')),
          findsOneWidget,
          reason: 'y$i',
        );
      }
      // Wingspan stays open.
      expect(nested('g-wingspan', 'x0'), findsOneWidget);
      expect(
        controlNode(tester, row('a-1')),
        isControl('Azul expansions, 6', expanded: true),
      );
      // Wingspan's row and its two, Azul's row, and its box as one.
      expect(semanticChildCount(tester), 5);
      handle.dispose();
    });

    testWidgets('two base games open at once', (tester) async {
      await show(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 1),
        azul,
        ...expansionsOf('g-azul', 'y', 1),
      ], onOpen: (_, _) {});

      await unfold(tester, wingspanRow);
      await unfold(tester, row('a-1'));

      expect(nested('g-wingspan', 'x0'), findsOneWidget);
      expect(nested('g-azul', 'y0'), findsOneWidget);

      // Folding one leaves the other open.
      await unfold(tester, wingspanRow);
      expect(nested('g-wingspan', 'x0'), findsNothing);
      expect(nested('g-azul', 'y0'), findsOneWidget);
    });

    testWidgets('open stays open as a sync brings another of its '
        'expansions', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 1),
      ], onOpen: (_, _) {});
      await unfold(tester, wingspanRow);

      await sync(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 2),
        azul,
      ]);

      expect(row('a-1'), findsOneWidget);
      expect(nested('g-wingspan', 'x0'), findsOneWidget);
      expect(nested('g-wingspan', 'x1'), findsOneWidget);
      expect(
        controlNode(tester, wingspanRow),
        isControl('Wingspan expansions, 2', expanded: true),
      );
      handle.dispose();
    });

    testWidgets('a base game whose last expansion goes comes back folded '
        'when one returns', (tester) async {
      await show(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 1),
      ], onOpen: (_, _) {});
      await unfold(tester, wingspanRow);
      expect(nested('g-wingspan', 'x0'), findsOneWidget);

      await sync(tester, [wingspan]);
      expect(controlOf(wingspanRow), findsNothing);
      await sync(tester, [wingspan, ...expansionsOf('g-wingspan', 'x', 1)]);

      expect(controlOf(wingspanRow), findsOneWidget);
      expect(nested('g-wingspan', 'x0'), findsNothing);
    });

    // A filter or a search narrows what is shown, not what is open: the
    // open set keeps the base games the whole collection nests games under.
    testWidgets('an open base game a filter hides, or whose expansions it '
        'hides, is open again once the filter clears', (tester) async {
      await show(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 2),
        azul,
      ], onOpen: (_, _) {});
      await unfold(tester, wingspanRow);

      for (final query in ['azul', 'wingspan']) {
        bloc(tester).add(
          GameCollectionListFilterChanged(CollectionFilter(query: query)),
        );
        await tester.pumpAndSettle();
        expect(nested('g-wingspan', 'x0'), findsNothing, reason: query);
        bloc(tester).add(
          const GameCollectionListFilterChanged(CollectionFilter()),
        );
        await tester.pumpAndSettle();

        expect(nested('g-wingspan', 'x0'), findsOneWidget, reason: query);
        expect(nested('g-wingspan', 'x1'), findsOneWidget, reason: query);
      }
    });

    testWidgets('an open base game stays open through a refresh, a failed '
        'read and a search that matches nothing', (tester) async {
      await tester.pumpWidget(
        harness(onOpen: (_, _) {}, onRetry: () async {}),
      );
      status.finished(CollectionHydrateOutcome.complete);
      final rows = [wingspan, ...expansionsOf('g-wingspan', 'x', 1), azul];
      items.add(rows);
      await tester.pumpAndSettle();
      await unfold(tester, wingspanRow);

      // A refresh by hand (#717).
      await tester.tap(find.byKey(GameCollectionListScreen.refreshButtonKey));
      await tester.pump();
      status.started();
      await tester.pump();
      status.finished(CollectionHydrateOutcome.complete);
      await tester.pumpAndSettle();
      expect(nested('g-wingspan', 'x0'), findsOneWidget, reason: 'refresh');

      // A read that fails, then answers again.
      items.addError(StateError('read failed'));
      await tester.pumpAndSettle();
      expect(find.byKey(GameCollectionListScreen.errorKey), findsOneWidget);
      await sync(tester, rows);
      expect(nested('g-wingspan', 'x0'), findsOneWidget, reason: 'error');

      // A search that leaves nothing.
      bloc(tester).add(
        const GameCollectionListFilterChanged(
          CollectionFilter(query: 'nothing has this name'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(GameCollectionListScreen.noMatchesKey),
        findsOneWidget,
      );
      bloc(tester).add(
        const GameCollectionListFilterChanged(CollectionFilter()),
      );
      await tester.pumpAndSettle();
      expect(nested('g-wingspan', 'x0'), findsOneWidget, reason: 'no match');
    });

    // An expansion that lands before its base game, on a first sync, is
    // held: counted nowhere and shown nowhere, under a folded base game or
    // an open one (#810).
    testWidgets('the #810 hold on a real first sync still places nothing '
        'early, folded or open', (tester) async {
      final handle = tester.ensureSemantics();
      // Titled Catan, as every item is by default.
      final catan = listItem('c-1', gameId: 'g-catan');
      final early = listItem(
        'h-1',
        gameId: 'g-h',
        title: 'Seafarers',
        contentType: ContentType.expansion,
        baseGames: const [
          ExpansionLink(gameId: 'g-catan', isStandalone: false),
        ],
      );
      final wingspanOne = expansionsOf('g-wingspan', 'x', 1);
      await tester.pumpWidget(harness(onOpen: (_, _) {}));
      status.started();
      items.add([wingspan, ...wingspanOne, early]);
      await tester.pumpAndSettle();
      await unfold(tester, wingspanRow);

      // Wingspan open with its one; Seafarers held for Catan.
      expect(nested('g-wingspan', 'x0'), findsOneWidget);
      expect(row('h-1'), findsNothing);
      expect(nested('g-wingspan', 'h-1'), findsNothing);
      expect(find.text('Seafarers', skipOffstage: false), findsNothing);
      expect(
        controlNode(tester, wingspanRow),
        isControl('Wingspan expansions, 1', expanded: true),
      );
      expect(semanticChildCount(tester), 2);

      // Catan's page lands: Seafarers goes under it, folded, and Wingspan
      // stays open.
      await sync(tester, [wingspan, ...wingspanOne, early, catan]);
      expect(row('h-1'), findsNothing);
      expect(nested('g-catan', 'h-1'), findsNothing);
      expect(
        controlNode(tester, row('c-1')),
        isControl('Catan expansions, 1', expanded: false),
      );
      expect(nested('g-wingspan', 'x0'), findsOneWidget);

      await unfold(tester, row('c-1'));
      expect(nested('g-catan', 'h-1'), findsOneWidget);

      // The pass ends: nothing moves, and nothing is marked.
      status.finished(CollectionHydrateOutcome.complete);
      await tester.pumpAndSettle();
      expect(row('h-1'), findsNothing);
      expect(nested('g-catan', 'h-1'), findsOneWidget);
      expect(nested('g-wingspan', 'x0'), findsOneWidget);
      expect(
        find.textContaining('Base game not in your collection'),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets('a nested stack (several copies of an expansion) folds with '
        'its base game and keeps its stack marker inside a box', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      GameCollectionListItem copy(String id, String platform) => listItem(
        id,
        gameId: 'g-eu',
        title: 'European Expansion',
        platformName: platform,
        contentType: ContentType.expansion,
        baseGames: const [
          ExpansionLink(gameId: 'g-wingspan', isStandalone: false),
        ],
      );
      final opened = <String>[];
      await show(tester, [
        wingspan,
        copy('eu-1', 'Tabletop'),
        copy('eu-2', 'Steam'),
        ...expansionsOf('g-wingspan', 'x', 4),
      ], onOpen: (_, id) => opened.add(id));
      final stack = find.byKey(
        GameCollectionListScreen.nestedStackKey('g-wingspan', 'g-eu'),
        skipOffstage: false,
      );

      // Folded: the stack counts once among Wingspan's five.
      expect(stack, findsNothing);
      expect(
        controlNode(tester, wingspanRow),
        isControl('Wingspan expansions, 5', expanded: false),
      );

      await unfold(tester, wingspanRow);

      expect(box, findsOneWidget);
      expect(find.descendant(of: box, matching: stack), findsOneWidget);
      expect(
        find.descendant(
          of: stack,
          matching: find.byType(BgeStackMarker, skipOffstage: false),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: stack,
          matching: find.text('2', skipOffstage: false),
        ),
        findsOneWidget,
      );
      expect(
        mergedNode(tester, stack).label,
        contains('European Expansion, expansion for Wingspan'),
      );
      // It still opens its picker.
      await tester.ensureVisible(stack);
      await tester.pumpAndSettle();
      await tester.tap(stack);
      await tester.pumpAndSettle();
      expect(
        find.byKey(CollectionEntryPicker.tileKey('eu-2')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a missing-base row (#711) is unaffected', (tester) async {
      final orphan = listItem(
        'o-1',
        gameId: 'g-orphan',
        title: 'Seafarers',
        contentType: ContentType.expansion,
        baseGames: const [
          ExpansionLink(gameId: 'g-catan', isStandalone: false),
        ],
      );
      await show(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 1),
        orphan,
      ], onOpen: (_, _) {});

      expect(row('o-1'), findsOneWidget);
      expect(controlOf(row('o-1')), findsNothing);
      expect(
        find.descendant(
          of: row('o-1'),
          matching: find.textContaining('Base game not in your collection'),
        ),
        findsOneWidget,
      );

      await unfold(tester, wingspanRow);
      expect(row('o-1'), findsOneWidget);
      expect(
        find.textContaining('Base game not in your collection'),
        findsOneWidget,
      );
    });

    testWidgets("a stack-free standalone expansion's own top-level row is "
        'unaffected', (tester) async {
      final standalone = listItem(
        's-1',
        gameId: 'g-s',
        title: 'Standalone',
        contentType: ContentType.standaloneExpansion,
        baseGames: const [
          ExpansionLink(gameId: 'g-wingspan', isStandalone: true),
        ],
      );
      await show(tester, [
        wingspan,
        standalone,
        ...expansionsOf('g-wingspan', 'x', 1),
      ], onOpen: (_, _) {});

      // Its own row, with no control: only its copy under Wingspan folds.
      expect(row('s-1'), findsOneWidget);
      expect(controlOf(row('s-1')), findsNothing);
      expect(nested('g-wingspan', 's-1'), findsNothing);
      expect(
        find.descendant(of: controlOf(wingspanRow), matching: find.text('2')),
        findsOneWidget,
      );

      await unfold(tester, wingspanRow);
      expect(nested('g-wingspan', 's-1'), findsOneWidget);
      expect(row('s-1'), findsOneWidget);

      await unfold(tester, wingspanRow);
      expect(nested('g-wingspan', 's-1'), findsNothing);
      expect(row('s-1'), findsOneWidget);
    });

    testWidgets('switching to thumbnails and back starts folded', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await show(
        tester,
        [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 1),
          azul,
        ],
        onOpen: (_, _) {},
        layouts: _FakeLayouts(),
      );
      await unfold(tester, wingspanRow);
      expect(nested('g-wingspan', 'x0'), findsOneWidget);

      await tester.tap(find.byTooltip('Thumbnails'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(GameCollectionListScreen.tileKey('w-1')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('List'));
      await tester.pumpAndSettle();

      expect(wingspanRow, findsOneWidget);
      expect(nested('g-wingspan', 'x0'), findsNothing);
      expect(
        controlNode(tester, wingspanRow),
        isControl('Wingspan expansions, 1', expanded: false),
      );
      expect(semanticChildCount(tester), 2);
      handle.dispose();
    });

    testWidgets("a base game's row keeps its focus as its first expansion "
        'arrives with a sync', (tester) async {
      await show(tester, [wingspan, azul], onOpen: (_, _) {});
      expect(controlOf(wingspanRow), findsNothing);
      final tile = tileFocusOf(tester, wingspanRow)..requestFocus();
      await tester.pump();

      await sync(tester, [
        wingspan,
        ...expansionsOf('g-wingspan', 'x', 1),
        azul,
      ]);

      expect(controlOf(wingspanRow), findsOneWidget);
      expect(tileFocusOf(tester, wingspanRow), same(tile));
      expect(tile.hasPrimaryFocus, isTrue);
    });

    group('focus as the rows fold', () {
      testWidgets('folding with focus on a nested row focuses the base '
          "game's control", (tester) async {
        final handle = tester.ensureSemantics();
        await show(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 2),
          azul,
        ], onOpen: (_, _) {});
        await unfold(tester, wingspanRow);
        // By way of Azul's row, so the control the page focused before the
        // nested row is that row, not Wingspan's control, which the
        // unfold's tap focused, and where the framework would put focus
        // anyway.
        tileFocusOf(tester, row('a-1')).requestFocus();
        await tester.pump();
        final tile = tileFocusOf(tester, nested('g-wingspan', 'x1'))
          ..requestFocus();
        await tester.pump();
        expect(tile.hasPrimaryFocus, isTrue);

        // A screen reader on the base game's row folds it, as its custom
        // action.
        performCustomAction(rowNode(tester, wingspanRow), 'Hide expansions');
        await tester.pumpAndSettle();

        expect(nested('g-wingspan', 'x1'), findsNothing);
        expect(_focusIsWithin(tester, controlOf(wingspanRow)), isTrue);
        expect(
          controlNode(tester, wingspanRow),
          isSemantics(
            label: 'Wingspan expansions, 2',
            isButton: true,
            hasExpandedState: true,
            isExpanded: false,
            hasTapAction: true,
            isFocusable: true,
            isFocused: true,
          ),
        );
        handle.dispose();
      });

      // Where the box is held to half the page: at 2.0 in landscape, a row
      // is taller than that.
      testWidgets('folding with focus inside the box focuses the base '
          "game's control, at 320 dp × 2.0 in landscape, and the page still "
          'drags', (tester) async {
        final handle = tester.ensureSemantics();
        useViewSize(tester, const Size(568, 320));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await show(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 6),
          for (var i = 0; i < 4; i++) listItem('f-$i', title: 'Filler $i'),
        ], onOpen: (_, _) {});
        await unfold(tester, wingspanRow);

        final page = _pagePosition(tester);
        ScrollPosition rows() => tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: box,
                    matching: find.byType(Scrollable),
                    skipOffstage: false,
                  )
                  .first,
            )
            .position;
        expect(
          rows().viewportDimension,
          lessThanOrEqualTo(page.viewportDimension / 2),
        );
        expect(rows().maxScrollExtent, greaterThan(0));

        // Focus on a row deep in the box, from the keyboard, by way of
        // Wingspan's own row, so the control the page focused before it isn't
        // Wingspan's control, where the framework would put focus anyway.
        // Not by way of the next game's row: with the control at the top of
        // Wingspan's tall row, unfolding scrolls the page too little for the
        // list to have built it.
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        tileFocusOf(tester, wingspanRow).requestFocus();
        await tester.pump();
        tileFocusOf(tester, nested('g-wingspan', 'x4')).requestFocus();
        await tester.pump();
        await tester.pump();
        expect(_focusIsWithin(tester, nested('g-wingspan', 'x4')), isTrue);

        performCustomAction(rowNode(tester, wingspanRow), 'Hide expansions');
        await tester.pumpAndSettle();

        expect(box, findsNothing);
        expect(_focusIsWithin(tester, controlOf(wingspanRow)), isTrue);
        expect(
          controlNode(tester, wingspanRow),
          isSemantics(
            label: 'Wingspan expansions, 6',
            isButton: true,
            hasExpandedState: true,
            isExpanded: false,
            hasTapAction: true,
            isFocusable: true,
            isFocused: true,
          ),
        );

        final before = page.pixels;
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -80));
        await tester.pumpAndSettle();
        expect(page.pixels, greaterThan(before));
        handle.dispose();
      });

      // A sync that brings a fifth expansion moves the rows into the box.
      testWidgets('a nested row with focus stays focused as the count '
          'crosses 4 → 5, shown in the box', (tester) async {
        await show(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 4),
          azul,
        ], onOpen: (_, _) {});
        await unfold(tester, wingspanRow);
        expect(box, findsNothing);
        // From the keyboard, so the focus is drawn, and a hidden row is
        // brought into view.
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        tileFocusOf(tester, nested('g-wingspan', 'x3')).requestFocus();
        await tester.pump();

        await sync(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 5),
          azul,
        ]);

        expect(box, findsOneWidget);
        final inBox = find.descendant(
          of: box,
          matching: nested('g-wingspan', 'x3'),
        );
        expect(inBox, findsOneWidget);
        expect(_focusIsWithin(tester, inBox), isTrue);
        // The fourth of five, half hidden in a box 3½ rows tall until the
        // focus brings it into view.
        final shown = FocusManager.instance.primaryFocus!.rect;
        final rows = tester.getRect(
          find
              .descendant(
                of: box,
                matching: find.byType(Scrollable),
                skipOffstage: false,
              )
              .first,
        );
        expect(shown.top, greaterThanOrEqualTo(rows.top - 0.5));
        expect(shown.bottom, lessThanOrEqualTo(rows.bottom + 0.5));
      });

      // A sync that takes the fifth away lays the rows out in the list.
      testWidgets('a nested row with focus in the box stays focused as the '
          'count drops 5 → 4, back in the list', (tester) async {
        await show(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 5),
          azul,
        ], onOpen: (_, _) {});
        await unfold(tester, wingspanRow);
        expect(box, findsOneWidget);
        // By way of Azul's row, so the framework's fallback isn't the row.
        tileFocusOf(tester, row('a-1')).requestFocus();
        await tester.pump();
        tileFocusOf(tester, nested('g-wingspan', 'x1')).requestFocus();
        await tester.pump();

        await sync(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 4),
          azul,
        ]);

        expect(box, findsNothing);
        expect(_focusIsWithin(tester, nested('g-wingspan', 'x1')), isTrue);
      });

      // The pop gives focus back to the row the user opened, laid out in
      // the list now, not to the base game's control: the box of rows that
      // take focus is no item of its own (#813).
      testWidgets('back from an entry opened from the box, after a sync '
          'drops the count 5 → 4, lands focus on its row', (tester) async {
        await show(
          tester,
          [wingspan, ...expansionsOf('g-wingspan', 'x', 5), azul],
          onOpen: (context, id) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  Scaffold(appBar: AppBar(), body: Text('entry $id')),
            ),
          ),
        );
        await unfold(tester, wingspanRow);
        // By way of Azul's row, so the page's focus history has another
        // row before this one.
        tileFocusOf(tester, row('a-1')).requestFocus();
        await tester.pump();
        final opened = find.descendant(
          of: box,
          matching: nested('g-wingspan', 'x1'),
        );
        await tester.ensureVisible(opened);
        await tester.pumpAndSettle();
        await tester.tap(opened);
        await tester.pumpAndSettle();
        expect(find.text('entry x1'), findsOneWidget);

        items.add([wingspan, ...expansionsOf('g-wingspan', 'x', 4), azul]);
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.text('entry x1'), findsNothing);
        expect(box, findsNothing);
        expect(_focusIsWithin(tester, nested('g-wingspan', 'x1')), isTrue);
      });

      testWidgets("a focused row in a box scrolled out of the list doesn't "
          "move focus to its game's other copy (#819)", (tester) async {
        // Wingspan at the top with six, in a box, and Azul at the end with
        // one, E under both: more than a screen and the list's cache apart.
        await show(tester, [
          wingspan,
          listItem(
            'e-1',
            gameId: 'g-e',
            title: 'Shared Expansion',
            contentType: ContentType.expansion,
            baseGames: const [
              ExpansionLink(gameId: 'g-wingspan', isStandalone: false),
              ExpansionLink(gameId: 'g-azul', isStandalone: false),
            ],
          ),
          ...expansionsOf('g-wingspan', 'x', 5),
          for (var i = 0; i < 30; i++) listItem('f-$i', title: 'Filler $i'),
          azul,
        ], onOpen: (_, _) {});
        await scrollListToEnd(
          tester,
          find.byKey(GameCollectionListScreen.rowKey('a-1')),
        );
        await unfold(tester, row('a-1'));
        _pagePosition(tester).jumpTo(0);
        await tester.pumpAndSettle();
        await unfold(tester, wingspanRow);
        final near = nested('g-wingspan', 'e-1');
        final far = nested('g-azul', 'e-1');
        expect(find.descendant(of: box, matching: near), findsOneWidget);
        expect(far, findsNothing);
        tileFocusOf(tester, near).requestFocus();
        await tester.pump();
        expect(_focusIsWithin(tester, near), isTrue);

        await scrollListToEnd(tester, far);

        expect(near, findsNothing);
        expect(_focusIsWithin(tester, far), isFalse);
      });
    });

    // Without onOpen the rows take no focus, so the box is a stop itself,
    // and joins the hand-off as one.
    group('in a list that opens nothing', () {
      testWidgets("folding while the box has focus focuses the base game's "
          'control', (tester) async {
        await show(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 6),
          azul,
          ...expansionsOf('g-azul', 'y', 1),
        ]);
        await unfold(tester, wingspanRow);
        expect(tester.widget<BgeNestedRowsBox>(box).focusable, isTrue);
        // By way of Azul's control, so the control the page focused before
        // the box isn't Wingspan's, where the framework would put focus
        // anyway.
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        controlFocusOf(tester, row('a-1')).requestFocus();
        await tester.pump();
        boxFocusOf(tester).requestFocus();
        await tester.pump();
        expect(boxFocusOf(tester).hasPrimaryFocus, isTrue);

        final handle = tester.ensureSemantics();
        performCustomAction(rowNode(tester, wingspanRow), 'Hide expansions');
        await tester.pumpAndSettle();

        expect(box, findsNothing);
        expect(_focusIsWithin(tester, controlOf(wingspanRow)), isTrue);
        handle.dispose();
      });

      testWidgets('a box that drops to 4 rows while it has focus hands it '
          "to the base game's control", (tester) async {
        await show(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 5),
          azul,
          ...expansionsOf('g-azul', 'y', 1),
        ]);
        await unfold(tester, wingspanRow);
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        controlFocusOf(tester, row('a-1')).requestFocus();
        await tester.pump();
        boxFocusOf(tester).requestFocus();
        await tester.pump();
        expect(boxFocusOf(tester).hasPrimaryFocus, isTrue);

        await sync(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 4),
          azul,
          ...expansionsOf('g-azul', 'y', 1),
        ]);

        expect(box, findsNothing);
        expect(nested('g-wingspan', 'x3'), findsOneWidget);
        // The rows take no focus, so not a row: the control, never the
        // page.
        expect(_focusIsWithin(tester, controlOf(wingspanRow)), isTrue);
      });

      // The row's tile takes no focus, so the control that goes has nothing
      // in its row to give it to: it hands the focus on as Tab would have,
      // to the next stop after the row, never to the page (#1048).
      testWidgets('a control that goes with the last expansion while it has '
          'focus hands it to the next stop after the row', (tester) async {
        await show(tester, [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 1),
          azul,
          ...expansionsOf('g-azul', 'y', 1),
        ]);
        // By way of the sort button, above the list, so the framework's
        // focus history would give the focus back up there, not on to
        // Azul's control.
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(GameCollectionListScreen.sortButtonKey),
              matching: find.byIcon(Icons.sort),
            ),
          ),
        ).requestFocus();
        await tester.pump();
        controlFocusOf(tester, wingspanRow).requestFocus();
        await tester.pump();
        expect(_focusIsWithin(tester, controlOf(wingspanRow)), isTrue);

        await sync(tester, [wingspan, azul, ...expansionsOf('g-azul', 'y', 1)]);

        expect(controlOf(wingspanRow), findsNothing);
        expect(_focusIsWithin(tester, controlOf(row('a-1'))), isTrue);
      });

      testWidgets('a box keeps its state as its rows come to open, and stop '
          'opening, entries', (tester) async {
        useViewSize(tester, const Size(400, 2400));
        final rows = [
          wingspan,
          ...expansionsOf('g-wingspan', 'x', 6),
          azul,
        ];
        await show(tester, rows);
        await unfold(tester, wingspanRow);
        expect(tester.widget<BgeNestedRowsBox>(box).focusable, isTrue);
        final state = tester.state(box);
        ScrollPosition inner() => tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: box,
                    matching: find.byType(Scrollable),
                    skipOffstage: false,
                  )
                  .first,
            )
            .position;
        inner().jumpTo(40);
        await tester.pump();

        // A session that can write now: the rows open their entries.
        await tester.pumpWidget(harness(onOpen: (_, _) {}));
        await tester.pumpAndSettle();
        expect(tester.widget<BgeNestedRowsBox>(box).focusable, isFalse);
        expect(tester.state(box), same(state));
        expect(inner().pixels, 40);

        // And back.
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();
        expect(tester.widget<BgeNestedRowsBox>(box).focusable, isTrue);
        expect(tester.state(box), same(state));
        expect(inner().pixels, 40);
      });
    });
  });

  group('expansions in thumbnails (#711)', () {
    const underBase = [ExpansionLink(gameId: 'g-base', isStandalone: false)];
    final base = listItem('base-1', gameId: 'g-base', title: 'Wingspan');
    final expansion = listItem(
      'exp-1',
      gameId: 'g-exp',
      title: 'European Expansion',
      contentType: ContentType.expansion,
      baseGames: underBase,
    );
    final other = listItem('azul-1', gameId: 'g-azul', title: 'Azul');

    Finder tile(String entryId) =>
        find.byKey(GameCollectionListScreen.tileKey(entryId));
    Finder badgeOf(Finder cover) => find.descendant(
      of: cover,
      matching: find.byKey(BgeCoverTile.expansionsBadgeKey),
    );
    final strip = find.byType(BgeShelf);
    final grids = find.byWidgetPredicate(
      (widget) => widget is BgeKeyedSliverGrid,
    );

    /// The cover's own node: with a badge, the tile holds two nodes and has
    /// none of its own, so it is found from the picture inside it.
    SemanticsNode coverNode(WidgetTester tester, Finder cover) =>
        tester.getSemantics(
          find.descendant(of: cover, matching: find.byType(BgeThumbnail)),
        );

    BgeCoverTile coverOf(WidgetTester tester, Finder cover) =>
        tester.widget<BgeCoverTile>(
          find.descendant(of: cover, matching: find.byType(BgeCoverTile)),
        );

    void performCustomAction(SemanticsNode node, String label) =>
        node.owner!.performAction(
          node.id,
          SemanticsAction.customAction,
          CustomSemanticsAction.getIdentifier(
            CustomSemanticsAction(label: label),
          ),
        );

    /// Shows [rows] in thumbnails, two columns wide and, unless [size] says
    /// otherwise, tall enough for every cover and the strip.
    Future<void> showThumbnails(
      WidgetTester tester,
      List<GameCollectionListItem> rows, {
      void Function(BuildContext context, String entryId)? onOpen,
      Size size = const Size(400, 1600),
    }) async {
      useViewSize(tester, size);
      await show(
        tester,
        rows,
        layouts: _FakeLayouts()..stored = ListLayout.thumbnails,
        onOpen: onOpen ?? (_, _) {},
      );
    }

    testWidgets("only top-level covers show, and a base game's carries the "
        'count', (tester) async {
      final handle = tester.ensureSemantics();
      GameCollectionListItem copy(String id, String platform) => listItem(
        id,
        gameId: 'g-catan',
        platformName: platform,
      );
      await showThumbnails(tester, [
        base,
        expansion,
        other,
        copy('catan-1', 'Tabletop'),
        copy('catan-2', 'Steam'),
        listItem(
          'seafarers-1',
          gameId: 'g-seafarers',
          title: 'Seafarers',
          contentType: ContentType.expansion,
          baseGames: const [
            ExpansionLink(gameId: 'g-catan', isStandalone: false),
          ],
        ),
      ]);

      expect(tile('base-1'), findsOneWidget);
      expect(tile('azul-1'), findsOneWidget);
      expect(tile('exp-1'), findsNothing);
      expect(tile('seafarers-1'), findsNothing);
      expect(strip, findsNothing);
      expect(
        find.descendant(of: badgeOf(tile('base-1')), matching: find.text('1')),
        findsOneWidget,
      );
      expect(badgeOf(tile('azul-1')), findsNothing);
      expect(
        tester.getSemantics(badgeOf(tile('base-1'))),
        isSemantics(
          label: 'Wingspan expansions, 1',
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
          isFocusable: true,
        ),
      );
      // A base game owned twice carries its badge on its stack.
      final stack = find.byKey(
        GameCollectionListScreen.stackTileKey('g-catan'),
      );
      expect(
        tester.getSemantics(badgeOf(stack)),
        isSemantics(label: 'Catan expansions, 1', isExpanded: false),
      );
      handle.dispose();
    });

    testWidgets("the badge unfolds a strip of its expansions' covers and "
        'folds it again', (tester) async {
      final handle = tester.ensureSemantics();
      await showThumbnails(tester, [
        base,
        expansion,
        other,
        listItem('carcassonne-1', gameId: 'g-carc', title: 'Carcassonne'),
      ]);

      await tester.tap(badgeOf(tile('base-1')));
      await tester.pumpAndSettle();

      expect(strip, findsOneWidget);
      expect(find.text('Wingspan expansions'), findsOneWidget);
      final nested = find.byKey(
        GameCollectionListScreen.nestedTileKey('g-base', 'exp-1'),
      );
      expect(nested, findsOneWidget);
      expect(
        tester.getSemantics(badgeOf(tile('base-1'))),
        isSemantics(label: 'Wingspan expansions, 1', isExpanded: true),
      );
      // Under the base game's row, which Azul shares at two columns, and
      // above Carcassonne's.
      expect(
        tester.getRect(tile('azul-1')).bottom,
        lessThan(tester.getRect(strip).top),
      );
      expect(
        tester.getRect(tile('carcassonne-1')).top,
        greaterThan(tester.getRect(strip).bottom),
      );
      // A strip cover is named as the expansion of its base game.
      expect(
        tester.getSemantics(nested).label,
        startsWith('European Expansion, expansion for Wingspan'),
      );

      await tester.tap(badgeOf(tile('base-1')));
      await tester.pumpAndSettle();

      expect(strip, findsNothing);
      expect(nested, findsNothing);
      expect(grids, findsOneWidget);
      handle.dispose();
    });

    testWidgets('a strip cover opens the entry, or the picker for a stack', (
      tester,
    ) async {
      GameCollectionListItem copy(String id, String platform) => listItem(
        id,
        gameId: 'g-exp-2',
        title: 'Oceania Expansion',
        platformName: platform,
        contentType: ContentType.expansion,
        baseGames: underBase,
      );
      final opened = <String>[];
      await showThumbnails(tester, [
        base,
        expansion,
        copy('oce-1', 'Tabletop'),
        copy('oce-2', 'Steam'),
      ], onOpen: (_, id) => opened.add(id));

      await tester.tap(badgeOf(tile('base-1')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: badgeOf(tile('base-1')), matching: find.text('2')),
        findsOneWidget,
        reason: 'a stack counts as one expansion',
      );

      await tester.tap(
        find.byKey(GameCollectionListScreen.nestedTileKey('g-base', 'exp-1')),
      );
      await tester.pumpAndSettle();
      expect(opened, ['exp-1']);

      await tester.tap(
        find.byKey(
          GameCollectionListScreen.nestedStackTileKey('g-base', 'g-exp-2'),
        ),
      );
      await tester.pumpAndSettle();

      expect(opened, ['exp-1']);
      expect(
        find.byKey(CollectionEntryPicker.tileKey('oce-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(CollectionEntryPicker.tileKey('oce-2')),
        findsOneWidget,
      );
    });

    testWidgets("Show expansions works from the cover's custom action", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await showThumbnails(tester, [base, expansion]);
      final cover = tile('base-1');
      final nested = find.byKey(
        GameCollectionListScreen.nestedTileKey('g-base', 'exp-1'),
      );

      expect(
        coverNode(tester, cover),
        isSemantics(
          customActions: [
            const CustomSemanticsAction(label: 'Show expansions'),
          ],
        ),
      );
      performCustomAction(coverNode(tester, cover), 'Show expansions');
      await tester.pumpAndSettle();

      expect(nested, findsOneWidget);
      expect(
        coverNode(tester, cover),
        isSemantics(
          customActions: [
            const CustomSemanticsAction(label: 'Hide expansions'),
          ],
        ),
      );

      performCustomAction(coverNode(tester, cover), 'Hide expansions');
      await tester.pumpAndSettle();

      expect(nested, findsNothing);
      handle.dispose();
    });

    testWidgets("opening a second strip keeps the tapped badge's semantics "
        'node (#820)', (tester) async {
      final handle = tester.ensureSemantics();
      await showThumbnails(tester, [
        base,
        expansion,
        other,
        listItem('carcassonne-1', gameId: 'g-carc', title: 'Carcassonne'),
        // Catan, by default.
        listItem('catan-1', gameId: 'g-catan'),
        listItem(
          'seafarers-1',
          gameId: 'g-seafarers',
          title: 'Seafarers',
          contentType: ContentType.expansion,
          baseGames: const [
            ExpansionLink(gameId: 'g-catan', isStandalone: false),
          ],
        ),
      ]);
      await tester.tap(badgeOf(tile('base-1')));
      await tester.pumpAndSettle();
      // At two columns Catan is in the row after Wingspan's strip, and
      // moves to the rows before its own strip.
      final catan = tile('catan-1');
      final badge = tester.getSemantics(badgeOf(catan)).id;
      final cover = coverNode(tester, catan).id;

      await tester.tap(badgeOf(catan));
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          GameCollectionListScreen.nestedTileKey('g-catan', 'seafarers-1'),
        ),
        findsOneWidget,
      );
      expect(tester.getSemantics(badgeOf(catan)).id, badge);
      expect(coverNode(tester, catan).id, cover);
      handle.dispose();
    });

    testWidgets("a marked cover's label says the base game isn't in the "
        'collection', (tester) async {
      await showThumbnails(tester, [
        expansion,
        listItem(
          'dlc-1',
          gameId: 'g-dlc',
          title: 'Season Pass',
          contentType: ContentType.dlc,
        ),
        other,
      ]);

      for (final id in ['exp-1', 'dlc-1']) {
        expect(coverOf(tester, tile(id)).marked, isTrue, reason: id);
        expect(
          coverOf(tester, tile(id)).label,
          startsWith(
            id == 'exp-1'
                ? 'European Expansion, Base game not in your collection, '
                : 'Season Pass, Base game not in your collection, ',
          ),
          reason: id,
        );
      }
      expect(coverOf(tester, tile('azul-1')).marked, isFalse);
      expect(
        coverOf(tester, tile('azul-1')).label,
        isNot(contains('Base game not in your collection')),
      );
    });

    testWidgets('the semantic child count is the top-level covers', (
      tester,
    ) async {
      final both = listItem(
        'exp-1',
        gameId: 'g-exp',
        title: 'European Expansion',
        contentType: ContentType.expansion,
        baseGames: const [
          ExpansionLink(gameId: 'g-base', isStandalone: false),
          ExpansionLink(gameId: 'g-azul', isStandalone: false),
        ],
      );
      await showThumbnails(tester, [base, other, both]);

      // Three games, an expansion under two of them: two covers.
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .semanticChildCount,
        2,
      );
    });

    for (final (before, what) in [
      ([base, expansion, other], 'with its badge'),
      ([base, other], 'gaining its badge'),
    ]) {
      testWidgets("a focused base game's cover keeps its focus as the game "
          'becomes a stack $what, not the badge (#769)', (tester) async {
        await showThumbnails(tester, before);
        bool inBadge(Finder cover) =>
            badgeOf(cover).evaluate().isNotEmpty &&
            _focusIsWithin(tester, badgeOf(cover));
        final ink = find.descendant(
          of: tile('base-1'),
          matching: find.byType(InkWell),
        );
        Focus.of(
          tester.element(
            find.descendant(of: ink.first, matching: find.byType(MouseRegion)),
          ),
        ).requestFocus();
        await tester.pump();
        expect(_focusIsWithin(tester, tile('base-1')), isTrue);
        expect(inBadge(tile('base-1')), isFalse);

        items.add([
          base,
          listItem(
            'base-2',
            gameId: 'g-base',
            title: 'Wingspan',
            platformName: 'Steam',
          ),
          expansion,
          other,
        ]);
        await tester.pumpAndSettle();

        final stack = find.byKey(
          GameCollectionListScreen.stackTileKey('g-base'),
        );
        expect(_focusIsWithin(tester, stack), isTrue);
        expect(badgeOf(stack), findsOneWidget);
        expect(inBadge(stack), isFalse);
      });
    }

    testWidgets('a focused marked expansion whose base game syncs in hands '
        "focus to the base game's badge (#813)", (tester) async {
      // Covers after the first row, so the page scrolls, and it is scrolled
      // a little, with the expansion's row still built.
      final after = [
        for (var i = 0; i < 8; i++)
          listItem('zoo-$i', gameId: 'g-zoo$i', title: 'Zoo $i'),
      ];
      await showThumbnails(tester, size: const Size(400, 700), [
        expansion,
        other,
        ...after,
      ]);
      final page =
          tester
              .state<ScrollableState>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                ),
              )
              .position
            ..jumpTo(120);
      await tester.pump();
      expect(coverOf(tester, tile('exp-1')).marked, isTrue);
      // Azul's cover, then the expansion's: each ink's own node.
      for (final id in ['azul-1', 'exp-1']) {
        Focus.of(
          tester.element(
            find
                .descendant(
                  of: find.descendant(
                    of: tile(id),
                    matching: find.byType(InkWell),
                  ),
                  matching: find.byType(MouseRegion),
                )
                .first,
          ),
        ).requestFocus();
        await tester.pump();
      }
      expect(_focusIsWithin(tester, tile('exp-1')), isTrue);

      // A sync brings its base game, and the expansion moves into the base
      // game's strip, which stays folded.
      items.add([base, expansion, other, ...after]);
      await tester.pumpAndSettle();

      expect(tile('exp-1'), findsNothing);
      expect(strip, findsNothing);
      expect(_focusIsWithin(tester, badgeOf(tile('base-1'))), isTrue);
      // The page doesn't move.
      expect(page.pixels, 120);
    });

    testWidgets('a focused strip cover whose strip a screen reader folds hands '
        "focus to the base game's badge (#813)", (tester) async {
      final handle = tester.ensureSemantics();
      await showThumbnails(tester, [base, expansion, other]);
      // A screen reader opens the strip from the cover, which moves no
      // focus, and the user goes on from Azul's cover into the strip.
      performCustomAction(coverNode(tester, tile('base-1')), 'Show expansions');
      await tester.pumpAndSettle();
      final nested = find.byKey(
        GameCollectionListScreen.nestedTileKey('g-base', 'exp-1'),
      );
      for (final cover in [tile('azul-1'), nested]) {
        Focus.of(
          tester.element(
            find
                .descendant(
                  of: find.descendant(
                    of: cover,
                    matching: find.byType(InkWell),
                  ),
                  matching: find.byType(MouseRegion),
                )
                .first,
          ),
        ).requestFocus();
        await tester.pump();
      }
      expect(_focusIsWithin(tester, nested), isTrue);

      performCustomAction(coverNode(tester, tile('base-1')), 'Hide expansions');
      await tester.pumpAndSettle();

      expect(strip, findsNothing);
      expect(_focusIsWithin(tester, badgeOf(tile('base-1'))), isTrue);
      handle.dispose();
    });

    testWidgets("a focused cover scrolled out of the grid doesn't move focus "
        "to its game's copy in an open strip (#819)", (tester) async {
      // A standalone expansion has a cover of its own and one in its base
      // game's strip: Animals' own cover at the top, Wingspan and its open
      // strip at the end, more than a screen and the grid's cache apart.
      final own = find.byKey(
        GameCollectionListScreen.tileKey('animals-1'),
        skipOffstage: false,
      );
      final inStrip = find.byKey(
        GameCollectionListScreen.nestedTileKey('g-wingspan', 'animals-1'),
        skipOffstage: false,
      );
      await showThumbnails(tester, size: const Size(400, 800), [
        listItem(
          'animals-1',
          gameId: 'g-animals',
          title: 'Animals',
          contentType: ContentType.standaloneExpansion,
          baseGames: const [
            ExpansionLink(gameId: 'g-wingspan', isStandalone: true),
          ],
        ),
        for (var i = 0; i < 20; i++)
          listItem('f-$i', gameId: 'g-f$i', title: 'Filler $i'),
        listItem('wingspan-1', gameId: 'g-wingspan', title: 'Wingspan'),
      ]);
      await scrollListToEnd(tester, tile('wingspan-1'));
      await tester.tap(badgeOf(tile('wingspan-1')));
      await tester.pumpAndSettle();
      // A strip isn't built lazily, so its covers stay built at the top.
      await scrollPageToTop(tester);
      expect(own, findsOneWidget);
      expect(inStrip, findsOneWidget);
      Focus.of(
        tester.element(
          find
              .descendant(
                of: find.descendant(of: own, matching: find.byType(InkWell)),
                matching: find.byType(MouseRegion),
              )
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      expect(_focusIsWithin(tester, own), isTrue);

      await scrollListToEnd(tester, tile('wingspan-1'));

      expect(own, findsNothing);
      expect(inStrip, findsOneWidget);
      expect(_focusIsWithin(tester, inStrip), isFalse);
    });

    testWidgets('the strip folds when its game goes', (tester) async {
      await showThumbnails(tester, [base, expansion, other]);
      await tester.tap(badgeOf(tile('base-1')));
      await tester.pumpAndSettle();
      expect(strip, findsOneWidget);

      // A sync takes the base game away.
      items.add([expansion, other]);
      await tester.pumpAndSettle();

      expect(strip, findsNothing);
      expect(grids, findsOneWidget);
      expect(tile('exp-1'), findsOneWidget);
      expect(coverOf(tester, tile('exp-1')).marked, isTrue);

      // Back again, it is folded: the unfold went with it.
      items.add([base, expansion, other]);
      await tester.pumpAndSettle();

      expect(badgeOf(tile('base-1')), findsOneWidget);
      expect(strip, findsNothing);
      expect(grids, findsOneWidget);
    });

    testWidgets('the strip folds when its game loses its expansions', (
      tester,
    ) async {
      await showThumbnails(tester, [base, expansion, other]);
      await tester.tap(badgeOf(tile('base-1')));
      await tester.pumpAndSettle();
      expect(strip, findsOneWidget);

      // A sync takes the expansion's entry away.
      items.add([base, other]);
      await tester.pumpAndSettle();

      expect(strip, findsNothing);
      expect(grids, findsOneWidget);
      expect(badgeOf(tile('base-1')), findsNothing);

      // Owned again, it is folded: the unfold went with the expansions.
      items.add([base, expansion, other]);
      await tester.pumpAndSettle();

      expect(badgeOf(tile('base-1')), findsOneWidget);
      expect(strip, findsNothing);
      expect(grids, findsOneWidget);
    });

    // The page's app bar is the Scaffold's, above the scroll view and not
    // over it, so a reveal measured in the scroll view's own space leaves
    // both the strip's bottom and the tapped row's top clear of it (#818).
    for (final (why, height, before, fits) in [
      ('the strip fits under its row', 700.0, 2, true),
      ("the row and its strip don't fit", 400.0, 0, false),
    ]) {
      testWidgets('opening a strip on the last row scrolls it into view below '
          'the app bar: $why', (tester) async {
        await showThumbnails(tester, size: Size(400, height), [
          for (var i = 0; i < before; i++)
            listItem('a$i', gameId: 'g-a$i', title: 'Before $i'),
          base,
          expansion,
          for (var i = 0; i < 6; i++)
            listItem('z$i', gameId: 'g-z$i', title: 'After $i'),
        ]);
        final appBar = tester.getRect(find.byType(AppBar));
        final page = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        );
        final view = tester.getRect(page);
        expect(view.top, appBar.bottom);
        // The base game's row is the last one wholly in view.
        final below = tester.getRect(tile('base-1')).bottom - view.bottom;
        if (below > 0) {
          final position = tester.state<ScrollableState>(page).position;
          position.jumpTo(position.pixels + below);
          await tester.pump();
        }

        await tester.tap(badgeOf(tile('base-1')));
        await tester.pumpAndSettle();

        final row = tester.getRect(tile('base-1'));
        if (fits) {
          expect(tester.getRect(strip).bottom, moreOrLessEquals(view.bottom));
          expect(row.top, greaterThan(appBar.bottom));
        } else {
          expect(row.top, moreOrLessEquals(appBar.bottom));
          expect(tester.getRect(strip).top, lessThan(view.bottom));
        }
      });
    }
  });

  group('focus across forms (#769)', () {
    final thumbs = _FakeLayouts()..stored = ListLayout.thumbnails;
    final catan = listItem('e-0');
    GameCollectionListItem wingspan(String id, String platformName) => listItem(
      id,
      gameId: 'g-wingspan',
      title: 'Wingspan',
      platformName: platformName,
    );
    final once = [catan, wingspan('e-1', 'Tabletop')];
    final twice = [...once, wingspan('e-2', 'Steam')];

    // The two views a game is drawn in: its entry's key and its stack's key
    // there, and the layout store that opens the screen in it.
    final views =
        <(String, Key Function(String), Key Function(String), _FakeLayouts?)>[
          (
            'the list',
            GameCollectionListScreen.rowKey,
            GameCollectionListScreen.stackKey,
            null,
          ),
          (
            'thumbnails',
            GameCollectionListScreen.tileKey,
            GameCollectionListScreen.stackTileKey,
            thumbs,
          ),
        ];

    /// The focus node of the control that opens [item]: its ink's.
    FocusNode control(WidgetTester tester, Finder item) => Focus.of(
      tester.element(
        find
            .descendant(
              of: find.descendant(of: item, matching: find.byType(InkWell)),
              matching: find.byType(MouseRegion),
            )
            .first,
      ),
    );

    /// Focuses Catan's item, then [item]: the page has focused something
    /// before, as it has once a keyboard user has got this far.
    Future<void> focus(WidgetTester tester, Finder item) async {
      final catanItem = find.byKey(GameCollectionListScreen.rowKey('e-0'));
      control(
        tester,
        catanItem.evaluate().isEmpty
            ? find.byKey(GameCollectionListScreen.tileKey('e-0'))
            : catanItem,
      ).requestFocus();
      await tester.pump();
      control(tester, item).requestFocus();
      await tester.pump();
      expect(_focusIsWithin(tester, item), isTrue);
    }

    Finder pickerTile(String entryId) =>
        find.byKey(CollectionEntryPicker.tileKey(entryId));

    for (final (view, entryKey, stackKey, layouts) in views) {
      final entry = find.byKey(entryKey('e-1'));
      final stack = find.byKey(stackKey('g-wingspan'));
      final what = view == 'the list' ? 'row' : 'tile';

      testWidgets('a focused stack reduced to one entry leaves focus on the '
          "entry's $what, in $view", (tester) async {
        await show(tester, twice, layouts: layouts, onOpen: (_, _) {});
        await focus(tester, stack);

        items.add(once);
        await tester.pumpAndSettle();

        expect(stack, findsNothing);
        expect(_focusIsWithin(tester, entry), isTrue);
      });

      testWidgets("a focused entry's $what that gains a second entry leaves "
          'focus on the stack, in $view', (tester) async {
        await show(tester, once, layouts: layouts, onOpen: (_, _) {});
        await focus(tester, entry);

        items.add(twice);
        await tester.pumpAndSettle();

        expect(entry, findsNothing);
        expect(_focusIsWithin(tester, stack), isTrue);
      });

      testWidgets('back from the entry page after removing a copy lands '
          "focus on the game's item, in $view", (tester) async {
        await show(
          tester,
          twice,
          layouts: layouts,
          onOpen: (context, id) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  Scaffold(appBar: AppBar(), body: Text('entry $id')),
            ),
          ),
        );
        await focus(tester, stack);
        // A tap, as a touch gives: the stack takes focus before the picker
        // opens.
        await tester.tap(stack);
        await tester.pumpAndSettle();
        await tester.tap(pickerTile('e-2'));
        await tester.pumpAndSettle();
        expect(find.text('entry e-2'), findsOneWidget);
        expect(pickerTile('e-2'), findsNothing);

        // The copy is removed on the entry page, under which the stack
        // becomes one entry.
        items.add(once);
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.text('entry e-2'), findsNothing);
        expect(_focusIsWithin(tester, entry), isTrue);
      });

      testWidgets('closing the picker after a sync leaves one entry lands '
          "focus on the game's item, in $view", (tester) async {
        await show(tester, twice, layouts: layouts, onOpen: (_, _) {});
        await focus(tester, stack);
        await tester.tap(stack);
        await tester.pumpAndSettle();
        expect(pickerTile('e-1'), findsOneWidget);

        items.add(once);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(pickerTile('e-1'), findsNothing);
        expect(_focusIsWithin(tester, entry), isTrue);
      });
    }

    testWidgets("a focused nested row scrolled out of the list doesn't move "
        "focus to its game's other copy (#819)", (tester) async {
      const bothBases = [
        ExpansionLink(gameId: 'g-wingspan', isStandalone: false),
        ExpansionLink(gameId: 'g-azul', isStandalone: false),
      ];
      // Wingspan at the top and Azul at the end, with the expansion under
      // each: more than a screen and the list's cache apart.
      await show(tester, [
        catan,
        wingspan('e-1', 'Tabletop'),
        for (var i = 0; i < 30; i++) listItem('f-$i', title: 'Filler $i'),
        listItem('azul-1', gameId: 'g-azul', title: 'Azul'),
        listItem(
          'x-1',
          gameId: 'g-exp',
          title: 'European Expansion',
          contentType: ContentType.expansion,
          baseGames: bothBases,
        ),
      ], onOpen: (_, _) {});
      // Both unfolded (#1048): Azul first, at the end, then Wingspan, at the
      // top.
      await scrollListToEnd(
        tester,
        find.byKey(GameCollectionListScreen.rowKey('azul-1')),
      );
      await unfold(
        tester,
        find.byKey(GameCollectionListScreen.rowKey('azul-1')),
      );
      _pagePosition(tester).jumpTo(0);
      await tester.pumpAndSettle();
      await unfold(tester, find.byKey(GameCollectionListScreen.rowKey('e-1')));
      // Back to the top, where Catan's row is, for focus to go by way of it.
      _pagePosition(tester).jumpTo(0);
      await tester.pumpAndSettle();
      final near = find.byKey(
        GameCollectionListScreen.nestedRowKey('g-wingspan', 'x-1'),
        skipOffstage: false,
      );
      final far = find.byKey(
        GameCollectionListScreen.nestedRowKey('g-azul', 'x-1'),
        skipOffstage: false,
      );
      expect(far, findsNothing);
      await focus(tester, near);

      await scrollListToEnd(tester, far);

      expect(near, findsNothing);
      expect(_focusIsWithin(tester, far), isFalse);
    });

    testWidgets('a mouse-clicked stack reduced to one entry leaves the tile '
        'focused without a ring or a tint', (tester) async {
      // A mouse leaves the highlight mode at the keyboard's on a desktop, so
      // the focus handed to the entry's tile would be ringed, for a user who
      // never touched the keyboard, unless the click's state goes with it.
      await show(tester, twice, layouts: thumbs, onOpen: (_, _) {});
      final stack = find.byKey(
        GameCollectionListScreen.stackTileKey('g-wingspan'),
      );
      final entry = find.byKey(GameCollectionListScreen.tileKey('e-1'));
      const away = Offset(4, 590);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: away);
      addTearDown(mouse.removePointer);
      Future<void> click(Offset at) async {
        await mouse.moveTo(at);
        await mouse.down(at);
        await tester.pump(const Duration(milliseconds: 50));
        await mouse.up();
        await mouse.moveTo(away);
        await tester.pumpAndSettle();
      }

      await click(tester.getCenter(stack));
      expect(pickerTile('e-1'), findsOneWidget);
      // A sync leaves the game one entry under the picker, which is closed
      // by a click on the barrier, below the dialog.
      items.add(once);
      await tester.pumpAndSettle();
      await click(away);
      expect(pickerTile('e-1'), findsNothing);

      expect(_focusIsWithin(tester, entry), isTrue);
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      final ring = find.descendant(
        of: entry,
        matching: find.byType(BgeFocusRing),
      );
      expect(tester.widget<BgeFocusRing>(ring).suppressed, isTrue);
      final drawn = tester.widget<DecoratedBox>(
        find.descendant(of: ring, matching: find.byType(DecoratedBox)).first,
      );
      expect((drawn.decoration as BoxDecoration).border, isNull);
      // Nor is its ink tinted: with the mouse away, the focus highlight is
      // all the ink paints, and it paints with no strength.
      expect(
        tester.renderObject(
          find.descendant(of: entry, matching: find.byType(Material)),
        ),
        paints..everything((method, arguments) {
          for (final argument in arguments) {
            if (argument is Paint) expect(argument.color.a, 0);
          }
          return true;
        }),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('focus ring (#770)', () {
    GameCollectionListItem copy(String id, String platform) => listItem(
      id,
      gameId: 'g-wingspan',
      title: 'Wingspan',
      platformName: platform,
    );
    final once = [copy('e-1', 'Tabletop')];
    final twice = [...once, copy('e-2', 'Steam')];
    final base = listItem('base-1', gameId: 'g-base');
    GameCollectionListItem expansion(String id, String platform) => listItem(
      id,
      gameId: 'g-exp',
      title: 'European Expansion',
      platformName: platform,
      contentType: ContentType.expansion,
      baseGames: const [ExpansionLink(gameId: 'g-base', isStandalone: false)],
    );

    Finder pickerTile(String entryId) =>
        find.byKey(CollectionEntryPicker.tileKey(entryId));

    /// Whether a ring is drawn over something under [finder]: a foreground
    /// box with a border.
    bool ringShown(WidgetTester tester, Finder finder) => tester
        .widgetList<DecoratedBox>(
          find.descendant(of: finder, matching: find.byType(DecoratedBox)),
        )
        .any((box) {
          final decoration = box.decoration;
          return box.position == DecorationPosition.foreground &&
              decoration is BoxDecoration &&
              decoration.border != null;
        });

    /// The focus node of the control that opens the item [item] finds.
    FocusNode control(WidgetTester tester, Finder item) => Focus.of(
      tester.element(
        find
            .descendant(
              of: find.descendant(of: item, matching: find.byType(InkWell)),
              matching: find.byType(MouseRegion),
            )
            .first,
      ),
    );

    const away = Offset(4, 590);

    /// A mouse that clicks where it is told and rests away from the rows.
    Future<Future<void> Function(Offset)> mouseClicker(
      WidgetTester tester,
    ) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: away);
      addTearDown(mouse.removePointer);
      Future<void> click(Offset at) async {
        await mouse.moveTo(at);
        await mouse.down(at);
        await tester.pump(const Duration(milliseconds: 50));
        await mouse.up();
        await mouse.moveTo(away);
        await tester.pumpAndSettle();
      }

      return click;
    }

    /// Clicks [stack], then closes its picker with a click on the barrier.
    /// First, with [unfolding], clicks the control at the end of that base
    /// game's row, to show the stack under it (#1048).
    Future<void> clickAndClose(
      WidgetTester tester,
      Finder stack,
      String firstEntry, {
      Finder? unfolding,
    }) async {
      final click = await mouseClicker(tester);
      if (unfolding != null) {
        await click(tester.getCenter(controlOf(unfolding)));
      }
      await click(tester.getCenter(stack));
      expect(pickerTile(firstEntry), findsOneWidget);
      await click(away);
      expect(pickerTile(firstEntry), findsNothing);
    }

    Future<void> pressShift(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
    }

    final baseRow = find.byKey(GameCollectionListScreen.rowKey('base-1'));

    // With the row of the base game to unfold first, for a nested one
    // (#1048).
    final stackRows =
        <(String, List<GameCollectionListItem>, String, Key, Finder?)>[
          (
            'a clicked stack row',
            twice,
            'e-1',
            GameCollectionListScreen.stackKey('g-wingspan'),
            null,
          ),
          (
            'a nested stack row',
            [base, expansion('x-1', 'Tabletop'), expansion('x-2', 'Steam')],
            'x-1',
            GameCollectionListScreen.nestedStackKey('g-base', 'g-exp'),
            baseRow,
          ),
        ];

    for (final (what, rows, first, key, under) in stackRows) {
      final stack = find.byKey(key);

      testWidgets('$what shows its ring once a key is pressed after the '
          'picker closes', (tester) async {
        await show(tester, rows, onOpen: (_, _) {});
        await clickAndClose(tester, stack, first, unfolding: under);

        expect(_focusIsWithin(tester, stack), isTrue);
        await pressShift(tester);

        expect(ringShown(tester, stack), isTrue);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('$what focused by a click and never touched by the '
          'keyboard shows no ring', (tester) async {
        await show(tester, rows, onOpen: (_, _) {});
        await clickAndClose(tester, stack, first, unfolding: under);

        expect(_focusIsWithin(tester, stack), isTrue);
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        expect(ringShown(tester, stack), isFalse);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }

    testWidgets("an entry's row shows its ring under keyboard focus", (
      tester,
    ) async {
      await show(tester, [
        ...once,
        base,
        expansion('x-1', 'Tabletop'),
      ], onOpen: (_, _) {});
      await unfold(tester, baseRow);
      // The unfold's tap was a touch's, which hides every ring until a key.
      await pressShift(tester);

      for (final key in [
        GameCollectionListScreen.rowKey('e-1'),
        GameCollectionListScreen.nestedRowKey('g-base', 'x-1'),
      ]) {
        final row = find.byKey(key);
        expect(ringShown(tester, row), isFalse);
        control(tester, row).requestFocus();
        await tester.pumpAndSettle();

        expect(ringShown(tester, row), isTrue);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets("a row's focus ring follows its outline (#647)", (
      tester,
    ) async {
      await show(tester, [...once, base, expansion('x-1', 'Tabletop')]);
      await unfold(tester, baseRow);

      for (final key in [
        GameCollectionListScreen.rowKey('e-1'),
        GameCollectionListScreen.nestedRowKey('g-base', 'x-1'),
      ]) {
        final ring = tester.widget<BgeFocusRing>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(BgeFocusRing),
          ),
        );
        expect(
          ring.borderRadius,
          BorderRadius.circular(BgeTokens.standard.radiusMd),
        );
        final outline = tester.widget<ListTileTheme>(
          find
              .descendant(
                of: find.byKey(key),
                matching: find.byType(ListTileTheme),
              )
              .first,
        );
        expect(
          (outline.data.shape! as RoundedRectangleBorder).borderRadius,
          ring.borderRadius,
        );
      }
    });

    testWidgets(
      "a row's node is the outline's: no gap beneath, no indent (#647)",
      (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await show(tester, [...once, base, expansion('x-1', 'Tabletop')]);
        await unfold(tester, baseRow);

        for (final (key, indented) in [
          (GameCollectionListScreen.rowKey('e-1'), false),
          (GameCollectionListScreen.nestedRowKey('g-base', 'x-1'), true),
        ]) {
          final row = find.byKey(key);
          final outline = tester.getRect(
            find.descendant(of: row, matching: find.byType(DecoratedBox)).first,
          );
          final whole = tester.getRect(row);
          final node = mergedNode(tester, row);

          // The key's box holds the gap below the outline, and the indent.
          expect(
            whole.height - outline.height,
            BgeTokens.standard.spaceSm,
            reason: '$key',
          );
          expect(
            whole.width - outline.width,
            indented ? BgeTokens.standard.spaceLg : 0,
            reason: '$key',
          );
          expect(node.rect.size, outline.size, reason: '$key');
        }
        handle.dispose();
      },
    );

    void openPage(BuildContext context, String id) =>
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(appBar: AppBar(), body: Text('entry $id')),
          ),
        );

    testWidgets('a clicked entry row is focused when its page opens and '
        'closes, with no ring', (tester) async {
      await show(tester, once, onOpen: openPage);
      final entry = find.byKey(GameCollectionListScreen.rowKey('e-1'));
      final click = await mouseClicker(tester);

      await click(tester.getCenter(entry));
      expect(find.text('entry e-1'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('entry e-1'), findsNothing);
      expect(_focusIsWithin(tester, entry), isTrue);
      expect(ringShown(tester, entry), isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    for (final (view, entryKey, stackKey, layouts) in [
      (
        'the list',
        GameCollectionListScreen.rowKey,
        GameCollectionListScreen.stackKey,
        null,
      ),
      (
        'thumbnails',
        GameCollectionListScreen.tileKey,
        GameCollectionListScreen.stackTileKey,
        _FakeLayouts()..stored = ListLayout.thumbnails,
      ),
    ]) {
      testWidgets('a clicked entry that becomes a stack while its page is '
          'open hands focus to the stack, in $view', (tester) async {
        await show(tester, once, layouts: layouts, onOpen: openPage);
        final click = await mouseClicker(tester);

        await click(tester.getCenter(find.byKey(entryKey('e-1'))));
        expect(find.text('entry e-1'), findsOneWidget);
        items.add(twice);
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        final stack = find.byKey(stackKey('g-wingspan'));
        expect(stack, findsOneWidget);
        expect(_focusIsWithin(tester, stack), isTrue);
        expect(ringShown(tester, stack), isFalse);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }

    testWidgets('a mouse-clicked stack row reduced to one entry leaves the '
        'entry row focused without a ring', (tester) async {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: harness(onOpen: (_, _) {}),
        ),
      );
      status.finished(CollectionHydrateOutcome.complete);
      items.add(twice);
      await tester.pumpAndSettle();
      final stack = find.byKey(GameCollectionListScreen.stackKey('g-wingspan'));
      final entry = find.byKey(GameCollectionListScreen.rowKey('e-1'));
      final click = await mouseClicker(tester);
      // Inside the row, past its text, where only the row's own ink draws.
      final rect = tester.getRect(stack);
      final blank = Offset(rect.right - 8, rect.center.dy);
      Future<Color> pixel() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = (await image.toByteData())!;
          final at = (blank.dy.floor() * image.width + blank.dx.floor()) * 4;
          return Color.fromARGB(
            bytes.getUint8(at + 3),
            bytes.getUint8(at),
            bytes.getUint8(at + 1),
            bytes.getUint8(at + 2),
          );
        }))!;
      }

      final unfocused = await pixel();

      await click(tester.getCenter(stack));
      expect(pickerTile('e-1'), findsOneWidget);
      // A sync leaves the game one entry under the picker, which is closed by
      // a click on the barrier, below the dialog.
      items.add(once);
      await tester.pumpAndSettle();
      await click(away);
      expect(pickerTile('e-1'), findsNothing);

      expect(_focusIsWithin(tester, entry), isTrue);
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      expect(ringShown(tester, entry), isFalse);
      // Nor is its ink tinted. A row's ink paints on the page's material, so
      // the painted pixel inside the row is compared with the row unfocused;
      // the colour the row hands its ink is not proof, as a highlight keeps
      // the strength it was first drawn with.
      expect(await pixel(), unfocused);
      final tile = tester.widget<ListTile>(
        find.descendant(of: entry, matching: find.byType(ListTile)),
      );
      expect(tile.focusColor?.a, 0);

      await pressShift(tester);
      expect(ringShown(tester, entry), isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });
}

/// The page's own scroll position: the first vertical scroll view, which
/// holds any other, such as a box of nested rows' (#1048).
ScrollPosition _pagePosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    )
    .position;

/// Whether the primary focus is on the widget [finder] finds, or inside it.
bool _focusIsWithin(WidgetTester tester, Finder finder) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final target = tester.element(finder);
  var within = identical(context, target);
  context.visitAncestorElements((ancestor) {
    within = within || identical(ancestor, target);
    return !within;
  });
  return within;
}

/// A layout store that answers with [stored], or after [hold].
class _FakeLayouts implements ListLayoutRepository {
  ListLayout? stored;
  Completer<ListLayout?>? hold;
  final writes = <(ListLayoutScreen, ListLayout)>[];

  /// Every read and write throws, as a store that has gone does.
  bool failing = false;

  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async {
    if (failing) throw StateError('ListLayoutRepository has been disposed');
    return hold == null ? stored : hold!.future;
  }

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async {
    if (failing) throw StateError('ListLayoutRepository has been disposed');
    stored = layout;
    writes.add((screen, layout));
  }
}
