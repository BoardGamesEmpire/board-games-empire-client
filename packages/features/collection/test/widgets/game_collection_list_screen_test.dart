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

  group('a game owned more than once (#709)', () {
    final thumbs = _FakeLayouts()..stored = ListLayout.thumbnails;

    GameCollectionListItem wingspan(
      String id,
      String platformName, {
      GameMedium medium = GameMedium.physical,
      bool? favorite,
    }) => listItem(
      id,
      gameId: 'g-wingspan',
      title: 'Wingspan',
      platformName: platformName,
      medium: medium,
      favorite: favorite,
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

      final label = tester
          .getSemantics(
            find.byKey(GameCollectionListScreen.stackKey('g-wingspan')),
          )
          .label;
      // The title first, then the copies, as a screen reader meets them.
      expect(
        label,
        matches(RegExp('Wingspan.*2 copies: Tabletop, Steam', dotAll: true)),
      );
      expect(find.text('2 copies: Tabletop, Steam'), findsOneWidget);
    });

    testWidgets('two mediums on one platform are a stack', (tester) async {
      await show(tester, [
        wingspan('e-1', 'Tabletop'),
        wingspan('e-2', 'Tabletop', medium: GameMedium.digital),
      ]);

      final stack = find.byKey(GameCollectionListScreen.stackKey('g-wingspan'));
      expect(stack, findsOneWidget);
      expect(
        find.text('2 copies: Tabletop · Physical, Tabletop · Digital'),
        findsOneWidget,
      );
      // No comma inside an entry: it would read as a third copy.
      expect(
        tester.getSemantics(stack).label,
        contains('2 copies: Tabletop Physical, Tabletop Digital'),
      );
    });

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
      expect(tester.getSemantics(row).label, contains('Favorite'));
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
    /// collection.
    Widget Function(ThemeData) screen({
      bool open = true,
      void Function(BuildContext context)? onBrowse,
      Future<void> Function()? onRetry,
      ListLayoutRepository? layouts,
    }) =>
        (theme) => harness(
          theme: theme,
          onOpen: open ? (_, _) {} : null,
          onBrowse: onBrowse,
          onRetry: onRetry,
          layouts: layouts,
        );

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
      },
    );

    auditScreen(
      'empty, with Browse',
      build: screen(onBrowse: (_) {}),
      arrange: (tester) async {
        await answer(tester, const []);
        expect(find.byKey(GameCollectionListScreen.browseKey), findsOneWidget);
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
      },
    );

    /// The banner over an empty collection, which it qualifies rather than
    /// replaces.
    Future<void> failedOverEmpty(WidgetTester tester) async {
      items.add(const []);
      status.finished(CollectionHydrateOutcome.failed);
      await tester.pumpAndSettle();
      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(GameCollectionListScreen.browseKey), findsOneWidget);
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
        await tester.tap(find.byKey(GameCollectionListScreen.refreshRetryKey));
        await tester.pump();
        status.started();
        await tester.pump();
        expect(find.text(_refreshingCopy), findsNWidgets(2));
      },
    );
  });
}

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
