import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
const _adminMessage =
    'No games here yet. Connect a DataGateway to bring them in.';
const _plainMessage = 'No games yet \u{2014} check back soon.';

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
    void Function(BuildContext context)? onConnectDataGateway,
    Widget? above,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    theme: BgeTheme.light(),
    localizationsDelegates: GameCatalogLocalizations.localizationsDelegates,
    supportedLocales: GameCatalogLocalizations.supportedLocales,
    home: Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?above,
          NewestGamesSection(
            remote: source ?? remote,
            cache: cache,
            connectivity: connectivity,
            gone: gone,
            onSeeAll: onSeeAll ?? (_) {},
            onOpen: onOpen,
            onConnectDataGateway: onConnectDataGateway,
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
    void Function(BuildContext context)? onConnectDataGateway,
  }) async {
    await tester.pumpWidget(
      harness(
        cache: cache,
        gone: gone,
        onSeeAll: onSeeAll,
        onOpen: onOpen,
        onConnectDataGateway: onConnectDataGateway,
      ),
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

  testWidgets('the spinner is announced', (tester) async {
    final handle = tester.ensureSemantics();
    final answer = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => answer.future;

    await tester.pumpWidget(harness());
    await tester.pump();

    expect(
      tester.getSemantics(find.bySemanticsLabel('Loading games\u{2026}')),
      isSemantics(isLiveRegion: true),
    );

    answer.complete(pageOf(_newest(1)));
    await tester.pumpAndSettle();
    handle.dispose();
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

  group('an empty server', () {
    setUp(() => remote.onFetchPage = (_, _) async => pageOf(const []));

    final message = find.byKey(NewestGamesSection.emptyKey);
    final action = find.byKey(NewestGamesSection.emptyActionKey);

    /// The text of the message, for a section that is showing one.
    String textOf(WidgetTester tester) => tester.widget<Text>(message).data!;

    testWidgets('the card has no margin, so it lines up with other sections', (
      tester,
    ) async {
      await show(tester, onConnectDataGateway: (_) {});

      final surface = tester.getRect(
        find
            .descendant(of: find.byType(Card), matching: find.byType(Material))
            .first,
      );
      expect(surface.left, 0);
      expect(surface.right, tester.getSize(find.byType(Scaffold)).width);
    });

    testWidgets('with a connect callback: the card and its action', (
      tester,
    ) async {
      await show(tester, onConnectDataGateway: (_) {});

      expect(remote.calls, ['fetchPage(1, 10, newest)']);
      expect(textOf(tester), _adminMessage);
      expect(
        find.ancestor(of: message, matching: find.byType(Card)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: action, matching: find.byType(Card)),
        findsOneWidget,
      );
      expect(tester.widget(action), isA<FilledButton>());
      expect(
        find.descendant(of: action, matching: find.text('Go to DataGateways')),
        findsOneWidget,
      );
    });

    testWidgets('the action calls onConnectDataGateway', (tester) async {
      final seen = <BuildContext>[];
      await show(tester, onConnectDataGateway: seen.add);
      expect(seen, isEmpty);

      await tester.tap(action);

      expect(seen, hasLength(1));
      expect(seen.single.mounted, isTrue);
    });

    testWidgets('with none: the plain message and no button', (tester) async {
      await show(tester);

      expect(textOf(tester), _plainMessage);
      expect(find.byType(Card), findsNothing);
      expect(action, findsNothing);
      expect(find.byType(ButtonStyleButton), findsNothing);
      expect(find.byType(InkWell), findsNothing);
      expect(find.text('Go to DataGateways'), findsNothing);
      expect(find.text(_adminMessage), findsNothing);
      expect(
        tester.getCenter(message).dx,
        moreOrLessEquals(tester.getCenter(find.byType(Scaffold)).dx),
        reason: 'centered',
      );
    });

    for (final connect in <void Function(BuildContext)?>[(_) {}, null]) {
      testWidgets('neither shows the heading or See all '
          '(${connect == null ? 'plain' : 'card'})', (tester) async {
        await show(tester, onConnectDataGateway: connect);

        expect(message, findsOneWidget);
        expect(find.byType(BgeShelf), findsNothing);
        expect(find.byKey(NewestGamesSection.headingKey), findsNothing);
        expect(find.byKey(NewestGamesSection.linkKey), findsNothing);
        expect(find.text('Recently added'), findsNothing);
        expect(find.text('See all'), findsNothing);
        expect(find.byKey(NewestGamesSection.loadingKey), findsNothing);
        expect(find.byKey(NewestGamesSection.failedKey), findsNothing);
      });
    }

    testWidgets('a callback arriving swaps the message for the card, and keeps '
        'the section state', (tester) async {
      await show(tester);
      expect(textOf(tester), _plainMessage);
      final cubit = tester.element(message).read<NewestGamesCubit>();

      await tester.pumpWidget(harness(onConnectDataGateway: (_) {}));
      await tester.pumpAndSettle();

      expect(textOf(tester), _adminMessage);
      expect(action, findsOneWidget);
      expect(find.text(_plainMessage), findsNothing);
      expect(
        tester.element(message).read<NewestGamesCubit>(),
        same(cubit),
        reason: 'the same section, not a new one',
      );
      expect(remote.calls, hasLength(1), reason: 'and no new read');

      // And the other way, where the access is withdrawn.
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(textOf(tester), _plainMessage);
      expect(action, findsNothing);
      expect(tester.element(message).read<NewestGamesCubit>(), same(cubit));
      expect(remote.calls, hasLength(1));
    });

    // The callback follows the caller's access to create, which can change
    // whenever the session asks again.
    group('the card coming and going (#456)', () {
      final other = find.byKey(const Key('other'));

      Widget withOther({void Function(BuildContext context)? connect}) =>
          harness(
            onConnectDataGateway: connect,
            above: TextButton(
              key: const Key('other'),
              onPressed: () {},
              child: const Text('Other'),
            ),
          );

      testWidgets('with focus on its action hands focus to the message', (
        tester,
      ) async {
        await show(tester, onConnectDataGateway: (_) {});
        Focus.of(
          tester.element(
            find.descendant(of: action, matching: find.byType(Text)),
          ),
        ).requestFocus();
        await tester.pump();

        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        final focus = FocusManager.instance.primaryFocus;
        expect(focus, isNot(isA<FocusScopeNode>()));
        expect(
          find.ancestor(
            of: message,
            matching: find.byElementPredicate(
              (element) => element == focus!.context,
            ),
          ),
          findsOneWidget,
          reason: 'on the message that takes the card\'s place',
        );
        expect(textOf(tester), _plainMessage);
      });

      testWidgets('coming back with focus on the message hands focus to its '
          'action', (tester) async {
        await show(tester);
        Focus.of(tester.element(message)).requestFocus();
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.context,
          tester.element(
            find.ancestor(of: message, matching: find.byType(Focus)).first,
          ),
          reason: 'on the message',
        );

        await tester.pumpWidget(harness(onConnectDataGateway: (_) {}));
        await tester.pumpAndSettle();

        final focus = FocusManager.instance.primaryFocus;
        expect(focus, isNot(isA<FocusScopeNode>()));
        expect(
          find.descendant(
            of: action,
            matching: find.byElementPredicate(
              (element) => element == focus!.context,
            ),
          ),
          findsOneWidget,
          reason: "on the action of the card that takes the message's place",
        );
      });

      testWidgets('the message is no Tab stop', (tester) async {
        await tester.pumpWidget(withOther());
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();

        expect(
          find.ancestor(
            of: message,
            matching: find.byElementPredicate(
              (element) =>
                  element == FocusManager.instance.primaryFocus?.context,
            ),
          ),
          findsNothing,
        );
      });

      testWidgets('with focus elsewhere leaves it alone', (tester) async {
        await tester.pumpWidget(withOther(connect: (_) {}));
        await tester.pumpAndSettle();
        Focus.of(
          tester.element(
            find.descendant(of: other, matching: find.byType(Text)),
          ),
        ).requestFocus();
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus;

        await tester.pumpWidget(withOther());
        await tester.pumpAndSettle();

        expect(action, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(focused));
      });
    });

    testWidgets('the message is a live region in both, and the button is not '
        'part of it', (tester) async {
      final handle = tester.ensureSemantics();

      await show(tester);
      expect(
        tester.getSemantics(message),
        isSemantics(label: _plainMessage, isLiveRegion: true),
      );

      await tester.pumpWidget(harness(onConnectDataGateway: (_) {}));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(message),
        isSemantics(label: _adminMessage, isLiveRegion: true),
      );
      expect(
        tester.getSemantics(action),
        isSemantics(
          label: 'Go to DataGateways',
          isButton: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          isLiveRegion: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('the card appearing is announced anew', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester);
      final plain = tester.getSemantics(message).id;

      await tester.pumpWidget(harness(onConnectDataGateway: (_) {}));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(message).id,
        isNot(plain),
        reason: 'a new live node, which a screen reader reads out',
      );
      handle.dispose();
    });

    testWidgets('the action is reached by the keyboard, and Enter presses it', (
      tester,
    ) async {
      var seen = 0;
      await show(tester, onConnectDataGateway: (_) => seen++);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      expect(
        find.descendant(
          of: action,
          matching: find.byElementPredicate(
            (element) => element == focus!.context,
          ),
        ),
        findsOneWidget,
        reason: 'the first stop is the button on the card',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(seen, 1);
    });

    testWidgets('a refused user is shown neither', (tester) async {
      remote.onFetchPage = (_, _) async =>
          throw const GamesForbiddenException('no');

      await show(tester, onConnectDataGateway: (_) {});

      expect(message, findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(tester.getSize(find.byType(NewestGamesSection)).height, 0);
    });

    testWidgets('a failed read with a connect callback shows neither', (
      tester,
    ) async {
      remote.onFetchPage = (_, _) async => throw unreachable();

      await show(tester, onConnectDataGateway: (_) {});

      expect(message, findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(action, findsNothing);
      expect(find.textContaining('No games'), findsNothing);
      expect(find.textContaining('DataGateway'), findsNothing);
      expect(find.byKey(NewestGamesSection.failedKey), findsOneWidget);
      expect(find.byKey(NewestGamesSection.retryKey), findsOneWidget);
    });

    testWidgets('offline with nothing cached shows neither', (tester) async {
      connectivity.current = ConnectivityState.offline;

      await show(tester, cache: FakeGamesCache(), onConnectDataGateway: (_) {});

      expect(remote.calls, isEmpty, reason: 'offline asks nothing');
      expect(message, findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(action, findsNothing);
      expect(find.textContaining('No games'), findsNothing);
      expect(find.textContaining('DataGateway'), findsNothing);
      expect(find.byKey(NewestGamesSection.failedKey), findsOneWidget);
    });

    /// Focuses the card's button, and returns what holds the focus.
    Future<FocusNode?> focusAction(WidgetTester tester) async {
      Focus.of(tester.element(find.text('Go to DataGateways'))).requestFocus();
      await tester.pump();
      return FocusManager.instance.primaryFocus;
    }

    testWidgets(
      'a failed reload leaves the card and its button\'s focus alone',
      (tester) async {
        final handle = tester.ensureSemantics();
        await show(tester, onConnectDataGateway: (_) {});
        final button = tester.element(action);
        final announced = tester.getSemantics(message).id;
        final focused = await focusAction(tester);
        expect(focused, isNotNull);

        remote.onFetchPage = (_, _) async => throw unreachable();
        unawaited(
          navigatorKey.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();

        expect(remote.calls, hasLength(2), reason: 'it did read again');
        expect(textOf(tester), _adminMessage);
        expect(find.byKey(NewestGamesSection.failedKey), findsNothing);
        expect(tester.element(action), same(button));
        expect(FocusManager.instance.primaryFocus, same(focused));
        expect(
          tester.getSemantics(message).id,
          announced,
          reason: 'no new live node, so nothing is announced again',
        );
        handle.dispose();
      },
    );

    testWidgets(
      'an offline blip leaves the card and its button\'s focus alone',
      (tester) async {
        await show(
          tester,
          cache: FakeGamesCache(),
          onConnectDataGateway: (_) {},
        );
        final button = tester.element(action);
        final focused = await focusAction(tester);

        connectivity.change(ConnectivityState.offline);
        await tester.pumpAndSettle();
        expect(textOf(tester), _adminMessage);
        expect(tester.element(action), same(button));
        expect(FocusManager.instance.primaryFocus, same(focused));

        remote.onFetchPage = (_, _) async => pageOf(const []);
        connectivity.change(ConnectivityState.online);
        await tester.pumpAndSettle();

        expect(remote.calls, hasLength(2), reason: 'reconnecting read again');
        expect(textOf(tester), _adminMessage);
        expect(tester.element(action), same(button));
        expect(FocusManager.instance.primaryFocus, same(focused));
      },
    );

    for (final connect in <void Function(BuildContext)?>[(_) {}, null]) {
      testWidgets('320dp at 2.0: it does not overflow '
          '(${connect == null ? 'plain' : 'card'})', (tester) async {
        const view = Size(320, 640);
        useViewSize(tester, view);
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: view,
              textScaler: const TextScaler.linear(2),
            ),
            child: harness(onConnectDataGateway: connect),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          MediaQuery.textScalerOf(tester.element(message)).scale(10),
          20,
          reason: 'the scale reaches the section',
        );
        final text = tester.getRect(message);
        expect(text.left, greaterThanOrEqualTo(0));
        expect(text.right, lessThanOrEqualTo(view.width));
        if (connect == null) return;

        final card = tester.getRect(find.byType(Card));
        final button = tester.getRect(action);
        expect(card.left, greaterThanOrEqualTo(0));
        expect(card.right, lessThanOrEqualTo(view.width));
        expect(card.contains(button.topLeft), isTrue);
        expect(card.contains(button.bottomRight - const Offset(1, 1)), isTrue);
        expect(card.contains(text.bottomRight - const Offset(1, 1)), isTrue);
        expect(
          button.top,
          greaterThanOrEqualTo(text.bottom),
          reason: 'the button sits under the message',
        );
      });
    }
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
