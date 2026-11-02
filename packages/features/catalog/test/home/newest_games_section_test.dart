import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/catalog_app.dart';
import '../support/fake_connectivity.dart';
import '../support/fake_games_remote.dart';

/// [count] games as the server sends them, newest first: `g-0` is the newest.
List<Game> _newest(int count) => [
  for (var n = 0; n < count; n++)
    game('g-$n').copyWith(createdAt: DateTime.utc(2026, 10, 30 - n)),
];

const _failedMessage = "Couldn't load recently added games.";

void main() {
  late FakeGamesRemote remote;
  late FakeConnectivity connectivity;

  setUp(() {
    remote = FakeGamesRemote();
    connectivity = FakeConnectivity();
  });

  tearDown(() => connectivity.close());

  final navigatorKey = GlobalKey<NavigatorState>();

  Finder cover(int index) =>
      find.byKey(NewestGamesSection.coverKey('g-$index'));

  /// The section in the column the home page puts its sections in.
  Widget harness({
    GamesRemoteDataSource? source,
    FakeGamesCache? cache,
    Stream<String>? gone,
    void Function(BuildContext context)? onSeeAll,
    void Function(BuildContext context, String gameId)? onOpen,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    theme: BgeTheme.light(),
    localizationsDelegates: GameCatalogLocalizations.localizationsDelegates,
    supportedLocales: GameCatalogLocalizations.supportedLocales,
    home: Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NewestGamesSection(
            remote: source ?? remote,
            cache: cache,
            connectivity: connectivity,
            gone: gone,
            onSeeAll: onSeeAll ?? (_) {},
            onOpen: onOpen,
          ),
        ],
      ),
    ),
  );

  /// Shows the section and lets a read that has answered reach the screen,
  /// and the row's buttons, which come a frame after it.
  Future<void> show(
    WidgetTester tester, {
    FakeGamesCache? cache,
    Stream<String>? gone,
    void Function(BuildContext context)? onSeeAll,
    void Function(BuildContext context, String gameId)? onOpen,
  }) async {
    await tester.pumpWidget(
      harness(cache: cache, gone: gone, onSeeAll: onSeeAll, onOpen: onOpen),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the heading, the covers in order, and See all', (
    tester,
  ) async {
    remote.onFetchPage = (_, _) async => pageOf(_newest(3));

    await show(tester);

    expect(remote.calls, ['fetchPage(1, 10, newest)']);
    expect(
      tester.widget<Text>(find.byKey(NewestGamesSection.headingKey)).data,
      'Recently added',
    );
    expect(find.text('Game g-0'), findsOneWidget);
    expect(find.text('Game g-2'), findsOneWidget);
    expect(
      tester.getTopLeft(cover(0)).dx,
      lessThan(tester.getTopLeft(cover(1)).dx),
    );
    expect(
      tester.getTopLeft(cover(1)).dx,
      lessThan(tester.getTopLeft(cover(2)).dx),
    );
    expect(
      find.descendant(
        of: find.byKey(NewestGamesSection.linkKey),
        matching: find.text('See all'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('See all calls onSeeAll, and speaks "See all recently added '
      'games"', (tester) async {
    final handle = tester.ensureSemantics();
    remote.onFetchPage = (_, _) async => pageOf(_newest(2));
    var seen = 0;
    await show(tester, onSeeAll: (_) => seen++);

    expect(
      find.bySemanticsLabel('See all recently added games'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp(r'^See all$')), findsNothing);

    await tester.tap(find.byKey(NewestGamesSection.linkKey));
    expect(seen, 1);
    handle.dispose();
  });

  testWidgets('tapping a cover calls onOpen with its id', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf(_newest(3));
    final opened = <String>[];
    await show(tester, onOpen: (_, id) => opened.add(id));

    await tester.tap(cover(1));

    expect(opened, ['g-1']);
  });

  testWidgets('shows a spinner under the heading while the first read runs', (
    tester,
  ) async {
    final answer = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => answer.future;

    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.byKey(NewestGamesSection.headingKey), findsOneWidget);
    expect(find.byKey(NewestGamesSection.linkKey), findsOneWidget);
    expect(find.byKey(NewestGamesSection.loadingKey), findsOneWidget);

    answer.complete(pageOf(_newest(1)));
    await tester.pumpAndSettle();
    expect(find.byKey(NewestGamesSection.loadingKey), findsNothing);
    expect(cover(0), findsOneWidget);
  });

  testWidgets('See all keeps focus from loading to loaded', (tester) async {
    final answer = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => answer.future;
    await tester.pumpWidget(harness());
    await tester.pump();
    final label = find.descendant(
      of: find.byKey(NewestGamesSection.linkKey),
      matching: find.byType(Text),
    );
    Focus.of(tester.element(label)).requestFocus();
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);

    answer.complete(pageOf(_newest(2)));
    await tester.pumpAndSettle();

    expect(cover(0), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, same(focused));
  });

  testWidgets('reads again when uncovered', (tester) async {
    remote.onFetchPage = (_, _) async => pageOf(_newest(2));
    await show(tester);
    expect(remote.calls, hasLength(1));

    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    expect(remote.calls, hasLength(1), reason: 'covering it reads nothing');
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(remote.calls, hasLength(2));
  });

  testWidgets('reads again on reconnecting', (tester) async {
    connectivity.current = ConnectivityState.offline;
    remote.onFetchPage = (_, _) async => pageOf(_newest(2));
    await show(tester, cache: FakeGamesCache());
    expect(remote.calls, isEmpty);

    connectivity.change(ConnectivityState.online);
    await tester.pumpAndSettle();

    expect(remote.calls, hasLength(1));
    expect(cover(0), findsOneWidget);
  });

  testWidgets('a failed read shows the games saved on this device', (
    tester,
  ) async {
    remote.onFetchPage = (_, _) async => throw unreachable();

    await show(tester, cache: FakeGamesCache(_newest(3)));

    expect(cover(0), findsOneWidget);
    expect(cover(2), findsOneWidget);
    expect(find.byKey(NewestGamesSection.failedKey), findsNothing);
  });

  testWidgets('a game found gone comes down', (tester) async {
    final gone = StreamController<String>.broadcast();
    addTearDown(gone.close);
    remote.onFetchPage = (_, _) async => pageOf(_newest(3));
    await show(tester, gone: gone.stream);

    gone.add('g-1');
    await tester.pumpAndSettle();

    expect(cover(0), findsOneWidget);
    expect(cover(1), findsNothing);
    expect(cover(2), findsOneWidget);
  });

  testWidgets('Denied draws nothing', (tester) async {
    remote.onFetchPage = (_, _) async =>
        throw const GamesForbiddenException('no');

    await show(tester, cache: FakeGamesCache(_newest(3)));

    expect(find.byType(BgeShelf), findsNothing);
    expect(find.byKey(NewestGamesSection.headingKey), findsNothing);
    expect(tester.getSize(find.byType(NewestGamesSection)).height, 0);
  });

  group('Failed', () {
    Future<void> showFailed(WidgetTester tester) async {
      remote.onFetchPage = (_, _) async => throw unreachable();
      await show(tester);
    }

    testWidgets('says so in a live region, with a retry', (tester) async {
      final handle = tester.ensureSemantics();

      await showFailed(tester);

      expect(find.byKey(NewestGamesSection.headingKey), findsOneWidget);
      expect(find.byKey(NewestGamesSection.linkKey), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(NewestGamesSection.failedKey)),
        isSemantics(label: _failedMessage, isLiveRegion: true),
      );
      expect(
        find.descendant(
          of: find.byKey(NewestGamesSection.retryKey),
          matching: find.text('Try again'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    /// Focuses the retry button, and returns what holds the focus.
    Future<FocusNode?> focusRetry(WidgetTester tester) async {
      final label = find.descendant(
        of: find.byKey(NewestGamesSection.retryKey),
        matching: find.byType(Text),
      );
      Focus.of(tester.element(label)).requestFocus();
      await tester.pump();
      return FocusManager.instance.primaryFocus;
    }

    /// Starts a read that waits for the test, and presses retry.
    Future<Completer<PaginatedResult<Game>>> pressRetry(
      WidgetTester tester,
    ) async {
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;
      await tester.tap(find.byKey(NewestGamesSection.retryKey));
      await tester.pump();
      await tester.pump();
      return answer;
    }

    testWidgets('a press says it is trying again, and keeps focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await showFailed(tester);
      final retry = find.byKey(NewestGamesSection.retryKey);
      final focused = await focusRetry(tester);
      expect(focused, isNotNull);
      expect(
        tester.getSemantics(retry),
        isSemantics(label: 'Try again', isLiveRegion: false, isButton: true),
      );

      await pressRetry(tester);

      expect(remote.calls, hasLength(2));
      expect(find.text('Try again'), findsNothing);
      expect(
        tester.getSemantics(retry),
        isSemantics(
          label: 'Trying again…',
          isLiveRegion: true,
          isButton: true,
          isEnabled: true,
        ),
      );
      expect(
        tester.widget<TextButton>(retry).onPressed,
        isNotNull,
        reason: 'a disabled button would drop the focus it holds',
      );
      expect(FocusManager.instance.primaryFocus, same(focused));
      expect(
        tester.getSemantics(find.byKey(NewestGamesSection.failedKey)),
        isSemantics(label: _failedMessage, isLiveRegion: false),
        reason: 'the message stays, and does not announce on the way in',
      );
      handle.dispose();
    });

    testWidgets('a second press while it reads is ignored', (tester) async {
      await showFailed(tester);
      await pressRetry(tester);
      expect(remote.calls, hasLength(2));

      await tester.tap(find.byKey(NewestGamesSection.retryKey));
      await tester.pump();

      expect(remote.calls, hasLength(2));
    });

    testWidgets('failing again says so again, and keeps focus', (tester) async {
      final handle = tester.ensureSemantics();
      await showFailed(tester);
      final retry = find.byKey(NewestGamesSection.retryKey);
      final message = find.byKey(NewestGamesSection.failedKey);
      final focused = await focusRetry(tester);
      final firstMessage = tester.getSemantics(message).id;

      final answer = await pressRetry(tester);
      final duringRetry = tester.getSemantics(message).id;
      answer.completeError(unreachable());
      await tester.pump(NewestGamesCubit.retryDwell);
      await tester.pumpAndSettle();

      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Trying again…'), findsNothing);
      final again = tester.getSemantics(message);
      expect(
        again,
        isSemantics(label: _failedMessage, isLiveRegion: true),
        reason: 'the message is live again',
      );
      expect(
        {firstMessage, duringRetry}.contains(again.id),
        isFalse,
        reason: 'and is a new node, which a screen reader announces',
      );
      expect(
        tester.getSemantics(retry),
        isSemantics(label: 'Try again', isLiveRegion: false),
      );
      expect(FocusManager.instance.primaryFocus, same(focused));

      // And it works again.
      remote.onFetchPage = (_, _) async => pageOf(_newest(2));
      await tester.tap(retry);
      await tester.pump(NewestGamesCubit.retryDwell);
      await tester.pumpAndSettle();
      expect(remote.calls, hasLength(3));
      expect(cover(0), findsOneWidget);
      expect(find.byKey(NewestGamesSection.failedKey), findsNothing);
      handle.dispose();
    });

    testWidgets('a read that answers shows the games', (tester) async {
      await showFailed(tester);

      final answer = await pressRetry(tester);
      answer.complete(pageOf(_newest(2)));
      await tester.pump(NewestGamesCubit.retryDwell);
      await tester.pumpAndSettle();

      expect(cover(0), findsOneWidget);
      expect(find.byKey(NewestGamesSection.failedKey), findsNothing);
      expect(find.byKey(NewestGamesSection.retryKey), findsNothing);
    });

    testWidgets(
      'offline with nothing saved, a retry still says so, and fails again '
      'after the dwell',
      (tester) async {
        // The app already knows the answer, so the read lands in the turn it
        // begins, before the page has drawn a frame.
        final handle = tester.ensureSemantics();
        connectivity.current = ConnectivityState.offline;
        await show(tester);
        final retry = find.byKey(NewestGamesSection.retryKey);
        final message = find.byKey(NewestGamesSection.failedKey);
        final button = tester.element(retry);
        final focused = await focusRetry(tester);
        final firstMessage = tester.getSemantics(message).id;

        await tester.tap(retry);
        await tester.pump();

        expect(find.text('Trying again…'), findsOneWidget);
        expect(tester.element(retry), same(button));
        expect(FocusManager.instance.primaryFocus, same(focused));
        expect(
          tester.getSemantics(retry),
          isSemantics(
            label: 'Trying again…',
            isLiveRegion: true,
            isButton: true,
            isEnabled: true,
          ),
        );
        expect(remote.calls, isEmpty, reason: 'offline asks nothing');

        await tester.pump(NewestGamesCubit.retryDwell);
        await tester.pump();

        expect(find.text('Try again'), findsOneWidget);
        expect(tester.element(retry), same(button));
        expect(FocusManager.instance.primaryFocus, same(focused));
        final again = tester.getSemantics(message);
        expect(again, isSemantics(label: _failedMessage, isLiveRegion: true));
        expect(again.id, isNot(firstMessage), reason: 'a new node: announced');
        expect(
          tester.getSemantics(retry),
          isSemantics(label: 'Try again', isLiveRegion: false),
        );
        handle.dispose();
      },
    );

    testWidgets('a read begun by uncovering leaves the button alone', (
      tester,
    ) async {
      await showFailed(tester);
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;

      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(remote.calls, hasLength(2));
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Trying again…'), findsNothing);
    });
  });
}
