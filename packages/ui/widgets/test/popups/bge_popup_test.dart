import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _narrow = Size(400, 800);
const _wide = Size(800, 600);

/// Both page transitions #707's hand-off was measured under.
final _platforms = TargetPlatformVariant(const <TargetPlatform>{
  TargetPlatform.android,
  TargetPlatform.iOS,
});

const _homeKey = Key('home');
const _openKey = Key('open');
const _popupKey = Key('popup');
const _openDialogKey = Key('open dialog');
const _dialogKey = Key('dialog over the popup');
const _pageKey = Key('page');
const _label = 'Quick look';

/// The app's router, cut down (#707): home on a `ShellRoute`'s nested
/// navigator, and pages pushed on the root navigator.
class _App {
  _App() {
    router = GoRouter(
      initialLocation: '/home',
      routes: [
        ShellRoute(
          builder: (context, state, child) => child,
          routes: [GoRoute(path: '/home', builder: (_, _) => _home())],
        ),
        GoRoute(
          path: '/page',
          pageBuilder: (_, state) =>
              MaterialPage(key: state.pageKey, child: _page()),
        ),
        // Arrives in no time: its entrance has completed by the time the
        // route below hears of it.
        GoRoute(
          path: '/instant',
          pageBuilder: (_, state) =>
              NoTransitionPage(key: state.pageKey, child: _page()),
        ),
      ],
    );
  }

  late final GoRouter router;
  final opener = FocusNode(debugLabel: 'opener');

  late BuildContext homeContext;
  BuildContext? popupContext;

  bool closed = false;
  Object? closedWith;

  Widget _home() => Builder(
    builder: (context) {
      homeContext = context;
      return Scaffold(
        key: _homeKey,
        body: Center(
          child: TextButton(
            key: _openKey,
            focusNode: opener,
            onPressed: () {
              closed = false;
              closedWith = null;
              unawaited(
                showBgePopup<Object>(
                  context,
                  semanticLabel: _label,
                  builder: _popup,
                ).then((value) {
                  closed = true;
                  closedWith = value;
                }),
              );
            },
            child: const Text('open'),
          ),
        ),
      );
    },
  );

  Widget _popup(BuildContext context) {
    popupContext = context;
    return Column(
      key: _popupKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Prose wraps at whatever width it is given, as a description does.
        Text('A long description. ' * 10),
        TextButton(
          key: _openDialogKey,
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(
              key: _dialogKey,
              content: Text('a dialog over the pop-up'),
            ),
          ),
          child: const Text('open a dialog'),
        ),
      ],
    );
  }

  Widget _page() => const Scaffold(key: _pageKey, body: Text('page'));

  Future<void> pump(WidgetTester tester, Size size) async {
    useViewSize(tester, size);
    addTearDown(router.dispose);
    addTearDown(opener.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        // The cached theme was built under whichever platform came first;
        // restated so each variant gets its own page transitions.
        theme: BgeTheme.light().copyWith(platform: defaultTargetPlatform),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_popupKey), findsOneWidget);
  }
}

/// The pop-up, on screen or under a page.
final _anyPopup = find.byKey(_popupKey, skipOffstage: false);

/// The labels of the nodes that name a route, as a screen reader announces
/// one on arrival.
List<String> _routeNames(WidgetTester tester) {
  final names = <String>[];
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.flagsCollection.namesRoute) names.add(data.label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  tester.binding.rootPipelineOwner.visitChildren((owner) {
    final root = owner.semanticsOwner?.rootSemanticsNode;
    if (root != null) walk(root);
  });
  return names;
}

void main() {
  group('showBgePopup', () {
    testWidgets('at 400 wide it opens a bottom sheet', (tester) async {
      final app = _App();
      await app.pump(tester, _narrow);

      await app.open(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    }, variant: _platforms);

    // The sheet keeps clear of the top and the sides only; it reaches the
    // bottom edge, under three-button navigation or the home indicator.
    testWidgets('its sheet ends its content above the system navigation, and '
        'its surface reaches the bottom edge', (tester) async {
      final app = _App();
      await app.pump(tester, _narrow);
      tester.view
        ..padding = const FakeViewPadding(bottom: 48)
        ..viewPadding = const FakeViewPadding(bottom: 48);

      await app.open(tester);

      expect(
        tester.getBottomLeft(find.byKey(_openDialogKey)).dy,
        lessThanOrEqualTo(_narrow.height - 48),
      );
      expect(tester.getBottomLeft(find.byType(BottomSheet)).dy, _narrow.height);
    }, variant: _platforms);

    testWidgets('at 800 wide it opens a dialog no wider than the content '
        'measure', (tester) async {
      final app = _App();
      await app.pump(tester, _wide);

      await app.open(tester);

      expect(find.byType(BottomSheet), findsNothing);
      final surface = find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first;
      expect(
        tester.getSize(surface).width,
        lessThanOrEqualTo(BgeTokens.standard.contentMaxWidth),
      );
    }, variant: _platforms);

    testWidgets('its dialog dims the page as showDialog does', (tester) async {
      final app = _App();
      await app.pump(tester, _wide);

      await app.open(tester);

      // The dialog theme names no barrier, so it is showDialog's default.
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).last,
      );
      expect(barrier.color, Colors.black54);
    }, variant: _platforms);

    for (final (shape, size) in [('sheet', _narrow), ('dialog', _wide)]) {
      group('as a $shape', () {
        testWidgets('opened from the nested navigator it sits on the root '
            'navigator', (tester) async {
          final app = _App();
          await app.pump(tester, size);

          await app.open(tester);

          final root = Navigator.of(app.homeContext, rootNavigator: true);
          expect(Navigator.of(app.homeContext), isNot(same(root)));
          expect(Navigator.of(app.popupContext!), same(root));
        }, variant: _platforms);

        testWidgets('a screen reader hears its label as it opens', (
          tester,
        ) async {
          final app = _App();
          await app.pump(tester, size);

          await app.open(tester);

          expect(_routeNames(tester), contains(_label));
        }, variant: _platforms);

        testWidgets('a page pushed over it removes it once the page has '
            'arrived', (tester) async {
          final app = _App();
          await app.pump(tester, size);
          await app.open(tester);

          unawaited(app.router.push('/page'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));

          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.closed, isFalse);

          await tester.pumpAndSettle();

          expect(find.byKey(_pageKey), findsOneWidget);
          expect(_anyPopup, findsNothing);
          expect(app.closed, isTrue);
          expect(app.closedWith, isNull);

          app.router.pop();
          await tester.pumpAndSettle();

          expect(find.byKey(_homeKey), findsOneWidget);
          expect(_anyPopup, findsNothing);
        }, variant: _platforms);

        testWidgets('a page that arrives at once removes it too', (
          tester,
        ) async {
          final app = _App();
          await app.pump(tester, size);
          await app.open(tester);

          unawaited(app.router.push('/instant'));
          await tester.pumpAndSettle();

          expect(find.byKey(_pageKey), findsOneWidget);
          expect(_anyPopup, findsNothing);
          expect(app.closed, isTrue);
          expect(app.closedWith, isNull);

          app.router.pop();
          await tester.pumpAndSettle();

          expect(find.byKey(_homeKey), findsOneWidget);
          expect(_anyPopup, findsNothing);
        }, variant: _platforms);

        testWidgets('a page popped before it has arrived leaves the pop-up', (
          tester,
        ) async {
          final app = _App();
          await app.pump(tester, size);
          await app.open(tester);

          unawaited(app.router.push('/page'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          app.router.pop();
          await tester.pumpAndSettle();

          expect(find.byKey(_pageKey, skipOffstage: false), findsNothing);
          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.closed, isFalse);
        }, variant: _platforms);

        testWidgets('a dialog opened over it leaves it in place', (
          tester,
        ) async {
          final app = _App();
          await app.pump(tester, size);
          await app.open(tester);

          await tester.tap(find.byKey(_openDialogKey));
          await tester.pumpAndSettle();

          expect(find.byKey(_dialogKey), findsOneWidget);
          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.closed, isFalse);

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();

          expect(find.byKey(_dialogKey), findsNothing);
          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.closed, isFalse);
        }, variant: _platforms);

        testWidgets('Escape and a barrier tap close it with null', (
          tester,
        ) async {
          final app = _App();
          await app.pump(tester, size);

          await app.open(tester);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();

          expect(_anyPopup, findsNothing);
          expect(app.closed, isTrue);
          expect(app.closedWith, isNull);

          await app.open(tester);
          expect(app.closed, isFalse);
          await tester.tapAt(const Offset(8, 8));
          await tester.pumpAndSettle();

          expect(_anyPopup, findsNothing);
          expect(app.closed, isTrue);
          expect(app.closedWith, isNull);
        }, variant: _platforms);

        testWidgets('the system back closes it with null, and focus returns '
            'to the opener', (tester) async {
          final app = _App();
          await app.pump(tester, size);
          app.opener.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byKey(_popupKey), findsOneWidget);

          expect(await tester.binding.handlePopRoute(), isTrue);
          await tester.pumpAndSettle();

          expect(_anyPopup, findsNothing);
          expect(find.byKey(_homeKey), findsOneWidget);
          expect(app.closed, isTrue);
          expect(app.closedWith, isNull);
          expect(FocusManager.instance.primaryFocus, same(app.opener));
        }, variant: TargetPlatformVariant.only(TargetPlatform.android));

        testWidgets('an edge swipe back from a page pushed over it lands on '
            'home with no pop-up, all the way through', (tester) async {
          final app = _App();
          await app.pump(tester, size);
          await app.open(tester);
          unawaited(app.router.push('/page'));
          await tester.pumpAndSettle();
          expect(find.byKey(_pageKey), findsOneWidget);
          expect(_anyPopup, findsNothing);

          final swipe = await tester.startGesture(Offset(5, size.height / 2));
          await swipe.moveBy(Offset(size.width / 2, 0));
          await tester.pump();

          // Halfway, home shows beside the page, with no pop-up over it.
          expect(find.byKey(_pageKey), findsOneWidget);
          expect(find.byKey(_homeKey), findsOneWidget);
          expect(find.byKey(_popupKey), findsNothing);

          await swipe.moveBy(Offset(size.width / 3, 0));
          await swipe.up();
          await tester.pumpAndSettle();

          expect(find.byKey(_pageKey, skipOffstage: false), findsNothing);
          expect(find.byKey(_homeKey), findsOneWidget);
          expect(_anyPopup, findsNothing);
        }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

        testWidgets('focus returns to the control that opened it', (
          tester,
        ) async {
          final app = _App();
          await app.pump(tester, size);
          app.opener.requestFocus();
          await tester.pump();

          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.opener.hasFocus, isFalse);

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();

          expect(_anyPopup, findsNothing);
          expect(FocusManager.instance.primaryFocus, same(app.opener));
        }, variant: _platforms);
      });
    }
  });
}
