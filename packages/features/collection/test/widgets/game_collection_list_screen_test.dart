import 'dart:async';
import 'dart:io';

import 'package:bge_test_support/images.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
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

  Widget app(Widget home, {TextScaler textScaler = TextScaler.noScaling}) =>
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates:
            GameCollectionLocalizations.localizationsDelegates,
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
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
    TextScaler textScaler = TextScaler.noScaling,
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

  SemanticsNode rowSemantics(WidgetTester tester, String id) =>
      tester.getSemantics(find.byKey(GameCollectionListScreen.rowKey(id)));

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
      items.add([listItem('e-1', title: 'Catan')]);
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

  group('a row (#44)', () {
    testWidgets('shows the title alone when there is no subtitle', (
      tester,
    ) async {
      await show(tester, [listItem('e-1', title: 'Catan')]);

      expect(find.text('Catan'), findsOneWidget);
    });

    testWidgets('joins the subtitle onto the title line', (tester) async {
      // Rows sort by title alone, so the subtitle is what tells two
      // editions of one game apart.
      await show(tester, [
        listItem('e-1', title: 'Catan', subtitle: 'Seafarers'),
      ]);

      expect(find.text('Catan: Seafarers'), findsOneWidget);
    });

    testWidgets('always names the platform and the medium', (tester) async {
      // The same game owned in two media is two rows with one title, and
      // these are what tell them apart.
      await show(tester, [
        listItem('e-1', platformName: 'PC', medium: GameMedium.digital),
        listItem('e-2', platformName: 'Board game'),
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
          title: 'Catan',
          platformName: 'Board game',
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
          title: 'Catan',
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
            platformName: 'Board game',
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
          title: 'Catan',
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
    // bar, so the body cannot bring one.
    await tester.pumpWidget(
      app(
        Scaffold(
          body: BlocProvider(
            create: (_) => GameCollectionListBloc(
              repository: repository,
              hydration: status.watch(),
            ),
            child: const CustomScrollView(
              slivers: [GameCollectionListSliver()],
            ),
          ),
        ),
      ),
    );
    status.finished(CollectionHydrateOutcome.complete);
    items.add([listItem('e-1', title: 'Catan')]);
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
      );
      segment.requestFocus();
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
}

/// A layout store that answers with [stored], or after [hold].
class _FakeLayouts implements ListLayoutRepository {
  ListLayout? stored;
  Completer<ListLayout?>? hold;
  final writes = <(ListLayoutScreen, ListLayout)>[];

  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async =>
      hold == null ? stored : hold!.future;

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async {
    stored = layout;
    writes.add((screen, layout));
  }
}
