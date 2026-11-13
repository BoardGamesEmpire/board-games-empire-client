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
const _platforms = TargetPlatformVariant(<TargetPlatform>{
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

const _pushKey = Key('push a page');
const _pushInstantKey = Key('push a page with no transition');
const _nestedDialogKey = Key('open a dialog on the nested navigator');
const _replaceKey = Key('replace the opener with a page');

/// #414's navigation shell, cut down: every page on a navigator nested in
/// the root one's home, with a [BgePopupCoverObserver] on it unless
/// [observed] is false.
///
/// The nested navigator has a [HeroController] of its own, as go_router
/// gives every navigator one. It puts a page pushed over another page
/// offstage for the page's first frame, which makes the page's entrance read
/// as complete for that frame.
class _NestedApp {
  _NestedApp({this.observed = true});

  final bool observed;
  final observer = BgePopupCoverObserver();
  final nestedKey = GlobalKey<NavigatorState>();
  final opener = FocusNode(debugLabel: 'opener');

  late BuildContext openerContext;

  /// The page the pop-up last pushed on the nested navigator.
  PageRoute<void>? page;

  bool closed = false;
  Object? closedWith;

  NavigatorState get nested => nestedKey.currentState!;

  Widget _opener() => Builder(
    builder: (context) {
      openerContext = context;
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

  /// Opens pages and a dialog on the nested navigator, as a quick look's
  /// `context.push` does from inside the shell.
  Widget _popup(BuildContext context) => Column(
    key: _popupKey,
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton(
        key: _pushKey,
        onPressed: () => nested.push(
          page = MaterialPageRoute<void>(builder: (_) => _page()),
        ),
        child: const Text('open a page'),
      ),
      TextButton(
        key: _pushInstantKey,
        onPressed: () => nested.push(
          page = PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => _page(),
          ),
        ),
        child: const Text('open a page at once'),
      ),
      TextButton(
        key: _replaceKey,
        onPressed: () => nested.pushReplacement(
          page = MaterialPageRoute<void>(builder: (_) => _page()),
        ),
        child: const Text('open a page in place of this one'),
      ),
      TextButton(
        key: _nestedDialogKey,
        onPressed: () => showDialog<void>(
          context: openerContext,
          useRootNavigator: false,
          builder: (_) => const AlertDialog(
            key: _dialogKey,
            content: Text('a dialog on the nested navigator'),
          ),
        ),
        child: const Text('open a dialog on the nested navigator'),
      ),
    ],
  );

  Widget _page() => Scaffold(
    key: _pageKey,
    appBar: AppBar(title: const Text('page')),
    body: const Text('page'),
  );

  Future<void> pump(WidgetTester tester, Size size) async {
    useViewSize(tester, size);
    final heroes = HeroController();
    addTearDown(heroes.dispose);
    addTearDown(opener.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light().copyWith(platform: defaultTargetPlatform),
        home: HeroControllerScope(
          controller: heroes,
          child: Navigator(
            key: nestedKey,
            observers: [if (observed) observer],
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => _opener(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the pop-up and returns its route.
  Future<ModalRoute<Object?>> open(WidgetTester tester) async {
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_popupKey), findsOneWidget);
    final popup = ModalRoute.of(tester.element(find.byKey(_popupKey)))!;
    final root = Navigator.of(openerContext, rootNavigator: true);
    expect(nested, isNot(same(root)));
    expect(popup.navigator, same(root));
    return popup;
  }
}

/// The pop-up, on screen or under a page.
final Finder _anyPopup = find.byKey(_popupKey, skipOffstage: false);

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

    // #414: the pop-up on the root navigator, its opener and the pages it
    // opens on a nested one.
    for (final (shape, size) in [('sheet', _narrow), ('dialog', _wide)]) {
      group('as a $shape opened from a nested navigator', () {
        testWidgets('a page pushed on a nested navigator removes a root '
            'pop-up once it has arrived', (tester) async {
          final app = _NestedApp();
          await app.pump(tester, size);
          final popup = await app.open(tester);

          await tester.tap(find.byKey(_pushKey));
          final page = app.page!;

          // The hero frame: the page is offstage, and its entrance reads as
          // complete though it has not started.
          expect(page.offstage, isTrue);
          expect(page.animation!.isCompleted, isTrue);
          await tester.pump();

          expect(page.offstage, isFalse);
          expect(page.animation!.status, AnimationStatus.forward);
          expect(popup.isActive, isTrue);
          expect(find.byKey(_popupKey), findsOneWidget);

          await tester.pump(const Duration(milliseconds: 80));

          expect(page.animation!.status, AnimationStatus.forward);
          expect(popup.isActive, isTrue);
          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.closed, isFalse);

          await tester.pumpAndSettle();

          expect(page.animation!.isCompleted, isTrue);
          expect(popup.isActive, isFalse);
          expect(_anyPopup, findsNothing);
          expect(find.byKey(_pageKey), findsOneWidget);
          expect(app.closed, isTrue);
          expect(app.closedWith, isNull);

          await tester.pageBack();
          await tester.pumpAndSettle();

          expect(find.byKey(_pageKey, skipOffstage: false), findsNothing);
          expect(find.byKey(_homeKey), findsOneWidget);
          expect(_anyPopup, findsNothing);
        }, variant: _platforms);

        testWidgets('focus is in the page once the pop-up has gone, and back '
            'on the opener after Back', (tester) async {
          final app = _NestedApp();
          await app.pump(tester, size);
          app.opener.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byKey(_popupKey), findsOneWidget);

          await tester.tap(find.byKey(_pushKey));
          await tester.pumpAndSettle();

          expect(_anyPopup, findsNothing);
          expect(
            FocusScope.of(tester.element(find.byKey(_pageKey))).hasFocus,
            isTrue,
          );

          await tester.pageBack();
          await tester.pumpAndSettle();

          expect(FocusManager.instance.primaryFocus, same(app.opener));
        }, variant: _platforms);

        testWidgets('a page that arrives at once on the nested navigator '
            'removes it too', (tester) async {
          final app = _NestedApp();
          await app.pump(tester, size);
          final popup = await app.open(tester);

          await tester.tap(find.byKey(_pushInstantKey));
          await tester.pumpAndSettle();

          expect(popup.isActive, isFalse);
          expect(_anyPopup, findsNothing);
          expect(find.byKey(_pageKey), findsOneWidget);
          expect(app.closed, isTrue);
          expect(app.closedWith, isNull);
        }, variant: _platforms);

        testWidgets('a page that replaces the opener on the nested '
            'navigator removes it too', (tester) async {
          final app = _NestedApp();
          await app.pump(tester, size);
          final popup = await app.open(tester);

          await tester.tap(find.byKey(_replaceKey));
          await tester.pumpAndSettle();

          expect(app.page!.animation!.isCompleted, isTrue);
          expect(popup.isActive, isFalse);
          expect(_anyPopup, findsNothing);
          expect(find.byKey(_pageKey), findsOneWidget);
          expect(app.closed, isTrue);
        }, variant: _platforms);

        testWidgets('a page popped before it arrives leaves the pop-up', (
          tester,
        ) async {
          final app = _NestedApp();
          await app.pump(tester, size);
          final popup = await app.open(tester);

          await tester.tap(find.byKey(_pushKey));
          // Through the hero frame, and part of the way in.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          app.nested.pop();
          await tester.pumpAndSettle();

          expect(find.byKey(_pageKey, skipOffstage: false), findsNothing);
          expect(popup.isActive, isTrue);
          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.closed, isFalse);
        }, variant: _platforms);

        testWidgets('a dialog opened from the pop-up on the nested navigator '
            'does not remove it', (tester) async {
          final app = _NestedApp();
          await app.pump(tester, size);
          final popup = await app.open(tester);

          await tester.tap(find.byKey(_nestedDialogKey));
          await tester.pumpAndSettle();

          expect(find.byKey(_dialogKey), findsOneWidget);
          expect(popup.isActive, isTrue);
          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.closed, isFalse);
        }, variant: _platforms);

        testWidgets('a pop-up opened from a navigator without the observer '
            'behaves as before', (tester) async {
          final app = _NestedApp(observed: false);
          await app.pump(tester, size);
          final popup = await app.open(tester);

          await tester.tap(find.byKey(_pushKey));
          await tester.pumpAndSettle();

          // The page arrives beneath the pop-up, which never hears of it.
          expect(app.page!.animation!.isCompleted, isTrue);
          expect(popup.isActive, isTrue);
          expect(find.byKey(_popupKey), findsOneWidget);
          expect(app.closed, isFalse);

          await tester.tapAt(const Offset(8, 8));
          await tester.pumpAndSettle();

          expect(_anyPopup, findsNothing);
          expect(find.byKey(_pageKey), findsOneWidget);
          expect(app.closed, isTrue);
        }, variant: _platforms);
      });
    }
  });

  group('BgeRemoveWhenCovered', () {
    // Mixed into a route of another kind, with no nested navigator to watch:
    // it hears of a page over it on its own navigator alone (#707).
    testWidgets('with no cover observer, a route goes once a page pushed '
        'over it has arrived', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Home'))),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final route = _PlainPopupRoute(const Text('Pop-up'));
      expect(route.coverObserver, isNull);
      navigator.push(route);
      await tester.pumpAndSettle();
      expect(find.text('Pop-up'), findsOneWidget);

      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const Text('Page')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(route.isActive, isTrue, reason: 'the page is still arriving');

      await tester.pumpAndSettle();
      expect(route.isActive, isFalse);

      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Pop-up'), findsNothing);
    });
  });
}

/// A route that mixes [BgeRemoveWhenCovered] in and leaves its
/// `coverObserver` as the mixin has it.
class _PlainPopupRoute extends PopupRoute<void>
    with BgeRemoveWhenCovered<void> {
  _PlainPopupRoute(this.child);

  final Widget child;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => child;
}
