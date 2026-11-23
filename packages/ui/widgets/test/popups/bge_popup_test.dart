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

  /// How many times the pop-up's builder has run.
  int popupBuilds = 0;

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
    popupBuilds++;
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

const _countKey = Key('count up');
const _fieldKey = Key('field');
const _lastKey = Key('last control');

/// What a pop-up's content went through while it was open.
class _ContentLog {
  /// How many times the content's `State` was created, and disposed.
  int created = 0;
  int disposed = 0;

  /// Every route the content found itself under, in order.
  final List<ModalRoute<Object?>> routes = [];

  /// How many times a route it was under popped: what stops an import
  /// being followed.
  int stops = 0;

  /// What the content was last laid out in.
  BoxConstraints? constraints;
}

/// Content with state to lose: a count, a field's text, and a listener on
/// its route's `popped`, as the catalog's import panel has (#733).
class _StatefulContent extends StatefulWidget {
  const _StatefulContent(this.log);

  final _ContentLog log;

  @override
  State<_StatefulContent> createState() => _StatefulContentState();
}

class _StatefulContentState extends State<_StatefulContent> {
  final _field = TextEditingController();
  ModalRoute<Object?>? _route;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    widget.log.created++;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && !identical(route, _route)) {
      _route = route;
      widget.log.routes.add(route);
      unawaited(route.popped.then((_) => widget.log.stops++));
    }
  }

  @override
  void dispose() {
    widget.log.disposed++;
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final form = BgePopupForm.maybeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        widget.log.constraints = constraints;
        return Column(
          key: _popupKey,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('count $_count'),
            Text('in a ${form?.name}'),
            TextButton(
              key: _countKey,
              onPressed: () => setState(() => _count++),
              child: const Text('count up'),
            ),
            TextField(key: _fieldKey, controller: _field),
            TextButton(
              key: _lastKey,
              onPressed: () {},
              child: const Text('last'),
            ),
          ],
        );
      },
    );
  }
}

/// One page whose button opens a pop-up of [_StatefulContent].
class _StatefulApp {
  final log = _ContentLog();
  final opener = FocusNode(debugLabel: 'opener');

  bool closed = false;

  Future<void> pump(WidgetTester tester, Size size, {ThemeData? theme}) async {
    useViewSize(tester, size);
    addTearDown(opener.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        home: Scaffold(
          key: _homeKey,
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                key: _openKey,
                focusNode: opener,
                onPressed: () {
                  closed = false;
                  unawaited(
                    showBgePopup<void>(
                      context,
                      semanticLabel: _label,
                      builder: (_) => _StatefulContent(log),
                    ).then((_) => closed = true),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the pop-up from the keyboard, so focus has an opener to return
  /// to.
  Future<void> open(WidgetTester tester) async {
    opener.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(_popupKey), findsOneWidget);
  }
}

/// Resizes the window, as a rotation or a dragged window edge does, and
/// draws the one frame the change lands in.
Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pump();
}

/// The pop-up is drawn as a sheet, and not as a dialog too.
void _expectSheet() {
  expect(find.byType(BottomSheet), findsOneWidget);
  expect(find.byType(Dialog), findsNothing);
}

/// The pop-up is drawn as a dialog, and not as a sheet too.
void _expectDialog() {
  expect(find.byType(Dialog), findsOneWidget);
  expect(find.byType(BottomSheet), findsNothing);
}

/// The route the pop-up's content is under.
ModalRoute<Object?> _popupRoute(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byKey(_popupKey)))!;

/// The pop-up's own barrier: the last one, over the page's.
ModalBarrier _popupBarrier(WidgetTester tester) =>
    tester.widget<ModalBarrier>(find.byType(ModalBarrier).last);

/// The fade the pop-up's route draws its page through.
FadeTransition _popupFade(WidgetTester tester) => tester.widget<FadeTransition>(
  find
      .ancestor(
        of: find.byKey(_popupKey),
        matching: find.byType(FadeTransition),
      )
      .first,
);

/// Whether keyboard focus is on the control with [key], or inside it.
bool _focusIsIn(WidgetTester tester, Key key) {
  final control = tester.element(find.byKey(key));
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  var inside = focused == control;
  focused.visitAncestorElements((element) {
    inside = inside || element == control;
    return !inside;
  });
  return inside;
}

/// The pop-up, on screen or under a page.
final Finder _anyPopup = find.byKey(_popupKey, skipOffstage: false);

/// A semantics node as the web engine sees it when it picks the kind of
/// element to build for the node (#733): its id, its role, the flags it
/// reads for that, and whether it can be tapped or scrolled.
typedef _WebNode = ({
  int id,
  SemanticsRole role,
  bool isHeader,
  bool isButton,
  bool isLink,
  bool isTextField,
  bool scopesRoute,
  bool hasImplicitScrolling,
  bool tappable,
  bool scrollable,
});

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

    testWidgets('its sheet dims the page as showModalBottomSheet does', (
      tester,
    ) async {
      final app = _App();
      await app.pump(tester, _narrow);

      await app.open(tester);

      // The sheet theme names no barrier, so it is the modal sheet's default.
      expect(_popupBarrier(tester).color, Colors.black54);
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

        testWidgets('a page pushed over one still arriving, and popped before '
            'it arrives, leaves the first to remove it', (tester) async {
          final app = _NestedApp();
          await app.pump(tester, size);
          final popup = await app.open(tester);

          await tester.tap(find.byKey(_pushKey));
          final first = app.page!;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          expect(first.animation!.status, AnimationStatus.forward);

          final second = MaterialPageRoute<void>(builder: (_) => app._page());
          app.nested.push(second);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          expect(second.animation!.status, AnimationStatus.forward);
          app.nested.pop();
          await tester.pumpAndSettle();

          expect(second.isActive, isFalse);
          expect(first.isActive, isTrue);
          expect(first.animation!.isCompleted, isTrue);
          expect(popup.isActive, isFalse);
          expect(_anyPopup, findsNothing);
          expect(app.closed, isTrue);
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

  // #733: one route, whose form follows the window while it is open.
  group('a pop-up across a resize', () {
    testWidgets('opened at 400 wide and widened to 800 it becomes a dialog '
        'sized to its content', (tester) async {
      final app = _App();
      await app.pump(tester, _narrow);
      await app.open(tester);
      _expectSheet();

      await _resize(tester, _wide);

      _expectDialog();
      expect(app.closed, isFalse);
      // The swap took no time: nothing is left to run after its one frame.
      expect(tester.hasRunningAnimations, isFalse);
      final surface = find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first;
      expect(
        tester.getSize(surface).width,
        lessThanOrEqualTo(BgeTokens.standard.contentMaxWidth),
      );
      // As tall and as wide as the content, and clear of every edge.
      expect(tester.getSize(surface), tester.getSize(find.byKey(_popupKey)));
      final rect = tester.getRect(surface);
      expect(rect.top, greaterThan(0));
      expect(rect.bottom, lessThan(_wide.height));
      expect(rect.center.dx, _wide.width / 2);
      // And the dialog is whole in that frame.
      expect(_popupFade(tester).opacity.value, 1);
    }, variant: _platforms);

    testWidgets('opened at 800 and narrowed to 400 it becomes a sheet', (
      tester,
    ) async {
      final app = _App();
      await app.pump(tester, _wide);
      await app.open(tester);
      _expectDialog();

      await _resize(tester, _narrow);

      _expectSheet();
      expect(app.closed, isFalse);
      // The swap took no time: nothing is left to run after its one frame.
      expect(tester.hasRunningAnimations, isFalse);
      // Full width, on the bottom edge, with its drag handle: and already
      // there, having slid from nowhere.
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(sheet.width, _narrow.width);
      expect(sheet.bottom, _narrow.height);
      expect(
        find.bySemanticsLabel(
          const DefaultMaterialLocalizations().modalBarrierDismissLabel,
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getRect(find.byType(BottomSheet)), sheet);
    }, variant: _platforms);

    // A dialog keeps clear of every edge, and the sheet it becomes keeps
    // clear of them as a sheet opened narrow does: its content stops above
    // the system navigation, and nothing pads its top.
    testWidgets('narrowed to a sheet, its content keeps the safe area a sheet '
        'opened narrow has', (tester) async {
      const insets = FakeViewPadding(top: 24, bottom: 48);

      /// The sheet's rect and its content's, opened at [size] under
      /// [padding] and then narrowed.
      Future<(Rect, Rect)> sheetOpenedAt(
        Size size,
        FakeViewPadding padding,
      ) async {
        final app = _StatefulApp();
        await app.pump(tester, size);
        tester.view
          ..padding = padding
          ..viewPadding = padding;
        await app.open(tester);
        if (size != _narrow) {
          _expectDialog();
          await _resize(tester, _narrow);
        }
        _expectSheet();
        final rects = (
          tester.getRect(find.byType(BottomSheet)),
          tester.getRect(find.byKey(_popupKey)),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        return rects;
      }

      final (bareSheet, bareContent) = await sheetOpenedAt(
        _narrow,
        FakeViewPadding.zero,
      );
      final opened = await sheetOpenedAt(_narrow, insets);
      final swapped = await sheetOpenedAt(_wide, insets);

      expect(swapped, opened);
      final (sheet, content) = swapped;
      expect(sheet.bottom, _narrow.height);
      expect(content.bottom, _narrow.height - insets.bottom);
      // Its content starts as far below its top edge as with no insets.
      expect(content.top - sheet.top, bareContent.top - bareSheet.top);
    });

    for (final (name, from, to) in [
      ('a sheet becoming a dialog', _narrow, _wide),
      ('a dialog becoming a sheet', _wide, _narrow),
    ]) {
      void expectForm(Size size) =>
          size == _narrow ? _expectSheet() : _expectDialog();

      testWidgets('focus stays inside across the swap and returns to the '
          'opener on close: $name', (tester) async {
        final app = _StatefulApp();
        await app.pump(tester, from);
        await app.open(tester);
        final route = _popupRoute(tester);
        final scope = FocusScope.of(tester.element(find.byKey(_popupKey)));

        // Just opened, the pop-up's own scope has focus, and keeps it.
        expect(FocusManager.instance.primaryFocus, same(scope));
        await _resize(tester, to);
        expectForm(to);
        expect(FocusManager.instance.primaryFocus, same(scope));
        await _resize(tester, from);
        expectForm(from);

        // On a control, focus stays on that control.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus!;
        expect(focused, isNot(same(scope)));
        expect(ModalRoute.of(focused.context!), same(route));

        await _resize(tester, to);
        expectForm(to);
        expect(FocusManager.instance.primaryFocus, same(focused));
        expect(ModalRoute.of(focused.context!), same(route));
        expect(scope.focusedChild, same(focused));

        await _resize(tester, from);
        expectForm(from);
        expect(FocusManager.instance.primaryFocus, same(focused));

        await _resize(tester, to);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(_anyPopup, findsNothing);
        expect(app.closed, isTrue);
        expect(FocusManager.instance.primaryFocus, same(app.opener));
      });

      testWidgets("the content's state survives the swap: $name", (
        tester,
      ) async {
        final app = _StatefulApp();
        await app.pump(tester, from);
        await app.open(tester);
        await tester.tap(find.byKey(_countKey));
        await tester.tap(find.byKey(_countKey));
        await tester.enterText(find.byKey(_fieldKey), 'Catan');
        await tester.pump();
        expect(find.text('count 2'), findsOneWidget);
        final state = tester.state(find.byType(_StatefulContent));
        final field = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        expect(field.widget.focusNode.hasPrimaryFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);

        for (final size in [to, from, to]) {
          await _resize(tester, size);

          expectForm(size);
          expect(tester.state(find.byType(_StatefulContent)), same(state));
          expect(find.text('count 2'), findsOneWidget);
          expect(find.text('Catan'), findsOneWidget);
          expect(
            tester.state<EditableTextState>(find.byType(EditableText)),
            same(field),
          );
          expect(field.widget.focusNode.hasPrimaryFocus, isTrue);
          expect(tester.testTextInput.hasAnyClients, isTrue);
        }
        expect(app.log.created, 1);
        expect(app.log.disposed, 0);

        // The field still takes what is typed.
        await tester.enterText(find.byKey(_fieldKey), 'Catan: Seafarers');
        await tester.pump();
        expect(find.text('Catan: Seafarers'), findsOneWidget);
      });

      // The catalog's import panel stops following an import once its
      // route pops, and the route it sees must stay the one it opened in.
      testWidgets('a resize keeps an import being followed: $name', (
        tester,
      ) async {
        final app = _StatefulApp();
        await app.pump(tester, from);
        await app.open(tester);
        final route = _popupRoute(tester);

        await _resize(tester, to);
        expectForm(to);
        await _resize(tester, from);
        expectForm(from);
        await tester.pumpAndSettle();

        expect(app.log.stops, 0);
        expect(app.log.routes, [same(route)]);
        expect(_popupRoute(tester), same(route));
        expect(route.isActive, isTrue);
        expect(app.log.disposed, 0);
        expect(app.closed, isFalse);

        // It still hears the real close.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(app.log.stops, 1);
        expect(app.closed, isTrue);
      });

      testWidgets('a page pushed over it after a swap still removes it once '
          'arrived: $name', (tester) async {
        final app = _App();
        await app.pump(tester, from);
        await app.open(tester);
        await _resize(tester, to);
        expectForm(to);

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

      testWidgets('a page pushed on the nested navigator after a swap still '
          'removes it once arrived: $name', (tester) async {
        final app = _NestedApp();
        await app.pump(tester, from);
        final popup = await app.open(tester);
        await _resize(tester, to);
        expectForm(to);

        await tester.tap(find.byKey(_pushKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));

        expect(popup.isActive, isTrue);
        expect(app.closed, isFalse);

        await tester.pumpAndSettle();

        expect(popup.isActive, isFalse);
        expect(_anyPopup, findsNothing);
        expect(find.byKey(_pageKey), findsOneWidget);
        expect(app.closed, isTrue);
        expect(app.closedWith, isNull);
      }, variant: _platforms);

      testWidgets('a swap part of the way through its exit lets it go on '
          'leaving: $name', (tester) async {
        final app = _App();
        await app.pump(tester, from);
        await app.open(tester);
        final route = _popupRoute(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.byKey(_popupKey), findsOneWidget);
        await _resize(tester, to);

        // Drawn in its new form for what is left of the exit, and not
        // brought back.
        expectForm(to);
        expect(route.isActive, isFalse);
        expect(route.animation!.status, AnimationStatus.reverse);

        await tester.pumpAndSettle();

        expect(_anyPopup, findsNothing);
        expect(find.byKey(_homeKey), findsOneWidget);
        expect(app.closed, isTrue);
        expect(app.closedWith, isNull);
      });

      testWidgets('a swap while a page is arriving over it still has the '
          'page remove it: $name', (tester) async {
        final app = _App();
        await app.pump(tester, from);
        await app.open(tester);

        unawaited(app.router.push('/page'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        await _resize(tester, to);

        expectForm(to);
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

      testWidgets('a swap while a page is arriving on the nested navigator '
          'still has the page remove it: $name', (tester) async {
        final app = _NestedApp();
        await app.pump(tester, from);
        final popup = await app.open(tester);

        await tester.tap(find.byKey(_pushKey));
        // Through the hero frame, and part of the way in.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(app.page!.animation!.status, AnimationStatus.forward);
        await _resize(tester, to);

        expectForm(to);
        expect(popup.isActive, isTrue);
        expect(app.closed, isFalse);

        await tester.pumpAndSettle();

        expect(popup.isActive, isFalse);
        expect(_anyPopup, findsNothing);
        expect(find.byKey(_pageKey), findsOneWidget);
        expect(app.closed, isTrue);
        expect(app.closedWith, isNull);
      }, variant: _platforms);

      testWidgets('Escape, a barrier tap and back close it in either form '
          'after a swap: $name', (tester) async {
        final app = _App();
        await app.pump(tester, from);
        Future<void> openAndSwap() async {
          await _resize(tester, from);
          await app.open(tester);
          await _resize(tester, to);
          expectForm(to);
          expect(app.closed, isFalse);
        }

        void expectClosed() {
          expect(_anyPopup, findsNothing);
          expect(find.byKey(_homeKey), findsOneWidget);
          expect(app.closed, isTrue);
          expect(app.closedWith, isNull);
        }

        await openAndSwap();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expectClosed();

        await openAndSwap();
        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
        expectClosed();

        await openAndSwap();
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pumpAndSettle();
        expectClosed();
      });
    }

    testWidgets('drag to dismiss works in the sheet form, including after a '
        'swap from dialog', (tester) async {
      final app = _App();
      await app.pump(tester, _narrow);
      Offset handle() =>
          tester.getRect(find.byType(BottomSheet)).topCenter +
          const Offset(0, 24);

      // Opened as a sheet.
      await app.open(tester);
      await tester.dragFrom(handle(), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(_anyPopup, findsNothing);
      expect(app.closed, isTrue);
      expect(app.closedWith, isNull);

      // Opened as a dialog, which has no drag to dismiss.
      await _resize(tester, _wide);
      await app.open(tester);
      await tester.dragFrom(
        tester.getRect(find.byType(Dialog)).center - const Offset(0, 100),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_popupKey), findsOneWidget);
      expect(app.closed, isFalse);

      // And then a sheet: a short drag follows the finger and springs
      // back, a long one closes it.
      await _resize(tester, _narrow);
      _expectSheet();
      final rest = tester.getRect(find.byType(BottomSheet));
      final gesture = await tester.startGesture(handle());
      await gesture.moveBy(const Offset(0, 30));
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(tester.getRect(find.byType(BottomSheet)).top, rest.top + 30);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(BottomSheet)), rest);
      expect(app.closed, isFalse);

      await tester.dragFrom(handle(), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(_anyPopup, findsNothing);
      expect(app.closed, isTrue);
      expect(app.closedWith, isNull);
    }, variant: _platforms);

    // Content that sizes a part of itself from the height it is given, as
    // a pinned footer capped at half of it, needs that height bounded, and
    // the same after a swap as when opened in that form.
    testWidgets('its content is laid out after a swap as when opened in '
        'that form, in a bounded height', (tester) async {
      Future<BoxConstraints> openedAt(Size size) async {
        final app = _StatefulApp();
        await app.pump(tester, size);
        await app.open(tester);
        final constraints = app.log.constraints!;
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        return constraints;
      }

      final inSheet = await openedAt(_narrow);
      final inDialog = await openedAt(_wide);
      expect(inSheet.hasBoundedHeight, isTrue);
      expect(inSheet.maxHeight, lessThan(_narrow.height));
      expect(inDialog.hasBoundedHeight, isTrue);
      expect(inDialog.maxHeight, lessThan(_wide.height));

      final app = _StatefulApp();
      await app.pump(tester, _narrow);
      await app.open(tester);
      expect(app.log.constraints, inSheet);

      await _resize(tester, _wide);
      _expectDialog();
      expect(app.log.constraints, inDialog);

      await _resize(tester, _narrow);
      _expectSheet();
      expect(app.log.constraints, inSheet);
    });

    testWidgets("the barrier is the form's own, and changes with it", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final base = BgeTheme.light();
      final sheetBarrier = base.colorScheme.primary;
      final dialogBarrier = base.colorScheme.tertiary;
      final app = _StatefulApp();
      await app.pump(
        tester,
        _narrow,
        theme: base.copyWith(
          bottomSheetTheme: base.bottomSheetTheme.copyWith(
            modalBarrierColor: sheetBarrier,
          ),
          dialogTheme: base.dialogTheme.copyWith(barrierColor: dialogBarrier),
        ),
      );
      await app.open(tester);
      final route = _popupRoute(tester);
      const localizations = DefaultMaterialLocalizations();

      void expectSheetBarrier() {
        final barrier = _popupBarrier(tester);
        final sheet = tester.getRect(find.byType(BottomSheet));
        expect(barrier.color, sheetBarrier);
        expect(barrier.dismissible, isTrue);
        expect(barrier.semanticsLabel, localizations.scrimLabel);
        expect(
          barrier.semanticsOnTapHint,
          localizations.scrimOnTapHint(localizations.bottomSheetLabel),
        );
        // A screen reader's focus on it stops at the sheet's top edge.
        expect(
          tester.getSemantics(find.bySemanticsLabel(localizations.scrimLabel)),
          isSemantics(
            rect: Rect.fromLTRB(0, 0, _narrow.width, sheet.top),
            hasTapAction: true,
            hasDismissAction: true,
          ),
        );
        expect(route.barrierColor, sheetBarrier);
        expect(route.barrierLabel, localizations.scrimLabel);
      }

      void expectDialogBarrier() {
        final barrier = _popupBarrier(tester);
        expect(barrier.color, dialogBarrier);
        expect(barrier.dismissible, isTrue);
        expect(barrier.semanticsLabel, localizations.modalBarrierDismissLabel);
        expect(barrier.semanticsOnTapHint, isNull);
        // It reaches every edge: nothing of a sheet's is left on it.
        expect(barrier.clipDetailsNotifier, isNull);
        expect(find.bySemanticsLabel(localizations.scrimLabel), findsNothing);
        expect(route.barrierColor, dialogBarrier);
        expect(route.barrierLabel, localizations.modalBarrierDismissLabel);
      }

      expectSheetBarrier();

      await _resize(tester, _wide);
      _expectDialog();
      expectDialogBarrier();

      await _resize(tester, _narrow);
      _expectSheet();
      expectSheetBarrier();
      handle.dispose();
    });

    for (final opened in [_narrow, _wide]) {
      testWidgets('Tab stays inside the dialog, and goes where the navigator '
          'sends it in the sheet, opened at ${opened.width.round()} wide', (
        tester,
      ) async {
        final app = _StatefulApp();
        await app.pump(tester, opened);
        await app.open(tester);
        final route = _popupRoute(tester);
        final scope = FocusScope.of(tester.element(find.byKey(_popupKey)));
        final navigatorEdgeBehavior =
            route.navigator!.widget.routeTraversalEdgeBehavior;
        expect(navigatorEdgeBehavior, isNot(TraversalEdgeBehavior.closedLoop));

        for (final size in [_wide, _narrow, _wide]) {
          await _resize(tester, size);

          if (size == _narrow) {
            _expectSheet();
            expect(route.traversalEdgeBehavior, isNull);
            expect(scope.traversalEdgeBehavior, navigatorEdgeBehavior);
          } else {
            _expectDialog();
            expect(
              route.traversalEdgeBehavior,
              TraversalEdgeBehavior.closedLoop,
            );
            expect(
              scope.traversalEdgeBehavior,
              TraversalEdgeBehavior.closedLoop,
            );
          }
        }

        // As a dialog, Tab from the last control comes round to the first.
        for (final key in [_countKey, _fieldKey, _lastKey, _countKey]) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(_focusIsIn(tester, key), isTrue, reason: '$key');
        }
      });
    }

    testWidgets('its content reads the form it is in, and is built again '
        'when that changes', (tester) async {
      final app = _StatefulApp();
      await app.pump(tester, _narrow);
      expect(
        BgePopupForm.maybeOf(tester.element(find.byKey(_openKey))),
        isNull,
      );

      await app.open(tester);
      final route = _popupRoute(tester);

      expect(find.text('in a sheet'), findsOneWidget);
      expect(
        route,
        isA<BgePopupRoute<void>>().having(
          (route) => route.form,
          'form',
          BgePopupForm.sheet,
        ),
      );

      await _resize(tester, _wide);

      expect(find.text('in a dialog'), findsOneWidget);
      expect((route as BgePopupRoute<void>).form, BgePopupForm.dialog);

      await _resize(tester, _narrow);

      expect(find.text('in a sheet'), findsOneWidget);
      expect(route.form, BgePopupForm.sheet);
    });

    // Neither a sheet's route nor a dialog's builds its content on a
    // resize, and a pop-up's content can be a whole game's details.
    testWidgets('a resize does not build content again that reads nothing '
        'of the window', (tester) async {
      final app = _App();
      await app.pump(tester, _narrow);
      await app.open(tester);
      final builds = app.popupBuilds;

      await _resize(tester, const Size(500, 800));
      _expectSheet();
      await _resize(tester, _wide);
      _expectDialog();
      await _resize(tester, const Size(900, 600));
      _expectDialog();
      await _resize(tester, _narrow);
      _expectSheet();

      expect(app.popupBuilds, builds);
    });

    testWidgets('a dialog opened over it and closed after a swap returns '
        'focus to the control that opened it', (tester) async {
      final app = _App();
      await app.pump(tester, _narrow);
      app.opener.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_focusIsIn(tester, _openDialogKey), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(_dialogKey), findsOneWidget);
      expect(_focusIsIn(tester, _openDialogKey), isFalse);

      // The pop-up changes form under the dialog.
      await _resize(tester, _wide);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(_dialogKey), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(_dialogKey), findsNothing);
      expect(find.byKey(_popupKey), findsOneWidget);
      expect(app.closed, isFalse);
      expect(_focusIsIn(tester, _openDialogKey), isTrue);
    });

    testWidgets('a screen reader finds each form named as it is when opened '
        'in it', (tester) async {
      final handle = tester.ensureSemantics();
      final app = _App();
      await app.pump(tester, _narrow);
      await app.open(tester);
      // A modal sheet's route has a name of its own on Android, and none
      // on iOS. The pop-up's is on its content in both forms.
      final asSheet = [
        if (defaultTargetPlatform == TargetPlatform.android)
          const DefaultMaterialLocalizations().dialogLabel
        else
          '',
        _label,
      ];
      expect(_routeNames(tester), asSheet);

      await _resize(tester, _wide);

      expect(_routeNames(tester), [_label]);

      await _resize(tester, _narrow);

      expect(_routeNames(tester), asSheet);
      handle.dispose();
    }, variant: _platforms);

    // A screen reader's place is a semantics node, and in a browser it is
    // the element the web engine builds from one. The engine moves a node's
    // element when the node gets a new parent, and builds it again when the
    // node's role changes, and the browser takes focus off whatever is
    // inside as it does. Measured in Chrome with its semantics tree on: a
    // change of form that gave the content's node a new parent put keyboard
    // focus out of the pop-up (#733). This suite can't run in a browser, so
    // it holds the tree to what kept focus there: from a control in the
    // content up to the root, the same nodes with the same roles in both
    // forms.
    testWidgets("the content's semantics nodes, and every node above them, "
        'are the same ones after a swap', (tester) async {
      final handle = tester.ensureSemantics();
      final app = _StatefulApp();
      await app.pump(tester, _narrow);
      await app.open(tester);
      // The node [label] names and each node above it, the root last: its
      // id, and what the web engine picks its element's kind from. A
      // route's name and its label differ by design, and are left out.
      List<_WebNode> lineage(String label) {
        final nodes = <_WebNode>[];
        SemanticsNode? node = tester.getSemantics(
          find.bySemanticsLabel(label),
        );
        while (node != null) {
          final data = node.getSemanticsData();
          final flags = data.flagsCollection;
          nodes.add((
            id: node.id,
            role: data.role,
            isHeader: flags.isHeader,
            isButton: flags.isButton,
            isLink: flags.isLink,
            isTextField: flags.isTextField,
            scopesRoute: flags.scopesRoute,
            // What the engine calls a scroll container.
            hasImplicitScrolling: flags.hasImplicitScrolling,
            tappable: data.hasAction(SemanticsAction.tap),
            scrollable: [
              SemanticsAction.scrollUp,
              SemanticsAction.scrollDown,
              SemanticsAction.scrollLeft,
              SemanticsAction.scrollRight,
            ].any(data.hasAction),
          ));
          node = node.parent;
        }
        return nodes;
      }

      final opened = [lineage('count up'), lineage('last')];
      // The pop-up's own node is the control's parent, and it sits in a
      // dialog's node, in a route's.
      final popup = opened.first[1].id;
      expect(tester.getSemantics(find.bySemanticsLabel(_label)).id, popup);
      expect(opened.first[2].role, SemanticsRole.dialog);
      expect(
        opened.first.skip(3).where((node) => node.scopesRoute),
        hasLength(1),
      );

      for (final size in [_wide, _narrow, _wide]) {
        await _resize(tester, size);

        if (size == _narrow) {
          _expectSheet();
        } else {
          _expectDialog();
        }
        expect([lineage('count up'), lineage('last')], opened);
      }
      handle.dispose();
    });

    // The entrance and the exit are the ones of the form it has while they
    // run: a sheet's 250 ms slide up and 200 ms down, a dialog's 150 ms
    // fade each way.
    testWidgets('it arrives as its form does: a sheet slides up, and a '
        'dialog fades in', (tester) async {
      final app = _App();
      await app.pump(tester, _narrow);

      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(_popupFade(tester).opacity.value, 1);
      final rising = tester.getRect(find.byType(BottomSheet)).top;
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(BottomSheet)).top, lessThan(rising));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _resize(tester, _wide);

      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        _popupFade(tester).opacity.value,
        allOf(greaterThan(0), lessThan(1)),
      );
      final fading = tester.getRect(find.byKey(_popupKey));
      await tester.pumpAndSettle();
      expect(_popupFade(tester).opacity.value, 1);
      expect(tester.getRect(find.byKey(_popupKey)), fading);
    });

    // The page, the barrier and the transition each read the window, so
    // none is a frame behind the others when it changes mid-entrance.
    testWidgets('a swap part of the way through the entrance carries on as '
        'the new form from its first frame', (tester) async {
      final app = _App();
      await app.pump(tester, _narrow);
      const localizations = DefaultMaterialLocalizations();

      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _expectSheet();
      await _resize(tester, _wide);

      // No frame of a whole dialog before it fades on.
      _expectDialog();
      expect(
        _popupFade(tester).opacity.value,
        allOf(greaterThan(0), lessThan(1)),
      );
      expect(
        _popupBarrier(tester).semanticsLabel,
        localizations.modalBarrierDismissLabel,
      );
      await tester.pumpAndSettle();
      expect(_popupFade(tester).opacity.value, 1);
      expect(app.closed, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      _expectDialog();
      await _resize(tester, _narrow);

      // No frame of a faint sheet, nor of one already at rest.
      _expectSheet();
      expect(_popupFade(tester).opacity.value, 1);
      expect(_popupBarrier(tester).semanticsLabel, localizations.scrimLabel);
      final rising = tester.getRect(find.byType(BottomSheet)).top;
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(BottomSheet)).top, lessThan(rising));
      expect(app.closed, isFalse);
    });

    testWidgets('a sheet that became a dialog leaves as a dialog does', (
      tester,
    ) async {
      final app = _App();
      await app.pump(tester, _narrow);
      await app.open(tester);
      await _resize(tester, _wide);
      _expectDialog();
      final rest = tester.getRect(find.byKey(_popupKey));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Fading where it stands.
      expect(
        _popupFade(tester).opacity.value,
        allOf(greaterThan(0), lessThan(1)),
      );
      expect(tester.getRect(find.byKey(_popupKey)), rest);

      // Gone in a dialog's 150 ms, where a sheet takes 200.
      await tester.pump(const Duration(milliseconds: 60));

      expect(_anyPopup, findsNothing);
      expect(app.closed, isTrue);
    });

    testWidgets('a dialog that became a sheet leaves as a sheet does', (
      tester,
    ) async {
      final app = _App();
      await app.pump(tester, _wide);
      await app.open(tester);
      await _resize(tester, _narrow);
      _expectSheet();
      final rest = tester.getRect(find.byType(BottomSheet));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Sliding down, as solid as it was.
      expect(_popupFade(tester).opacity.value, 1);
      expect(
        tester.getRect(find.byType(BottomSheet)).top,
        greaterThan(rest.top),
      );

      // Still leaving after a dialog's 150 ms, and gone in a sheet's 200.
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(_popupKey), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));

      expect(_anyPopup, findsNothing);
      expect(app.closed, isTrue);
    });

    // Only the sheet hears the finger that drags it lift. Left as the drag
    // had it, the dialog would stay as faint as the sheet was low.
    testWidgets('a resize that cuts a drag short leaves a whole dialog', (
      tester,
    ) async {
      final app = _App();
      await app.pump(tester, _narrow);
      await app.open(tester);
      final rest = tester.getRect(find.byType(BottomSheet));
      final gesture = await tester.startGesture(
        rest.topCenter + const Offset(0, 24),
      );
      await gesture.moveBy(const Offset(0, 30));
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(
        tester.getRect(find.byType(BottomSheet)).top,
        greaterThan(rest.top),
      );

      await _resize(tester, _wide);
      _expectDialog();
      await tester.pumpAndSettle();

      expect(_popupFade(tester).opacity.value, 1);
      expect(_popupRoute(tester).isActive, isTrue);
      expect(app.closed, isFalse);

      // The finger lifts over a dialog, which has no drag to end.
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byKey(_popupKey), findsOneWidget);
      expect(_popupFade(tester).opacity.value, 1);
      expect(app.closed, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_anyPopup, findsNothing);
      expect(app.closed, isTrue);
    });

    // A back gesture holds the entrance part of the way as a drag does,
    // and ends it itself, forward or back.
    testWidgets('a resize during a back gesture leaves the gesture its hold', (
      tester,
    ) async {
      final app = _App();
      await app.pump(tester, _narrow);
      await app.open(tester);
      final route = _popupRoute(tester)..handleStartBackGesture(progress: 0.4);
      await tester.pump();
      await _resize(tester, _wide);
      await tester.pump(const Duration(milliseconds: 300));

      _expectDialog();
      expect(route.animation!.value, 0.4);

      route.handleCancelBackGesture();
      await tester.pumpAndSettle();

      expect(route.animation!.isCompleted, isTrue);
      expect(find.byKey(_popupKey), findsOneWidget);
      expect(app.closed, isFalse);
    });

    // Reduced motion is the animation controller's own, in both forms, as
    // it was for a sheet's route and a dialog's: it runs each at a
    // twentieth of its time.
    for (final (name, size) in [('sheet', _narrow), ('dialog', _wide)]) {
      testWidgets('under reduced motion a $name arrives and leaves within a '
          'frame', (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final app = _App();
        await app.pump(tester, size);

        await tester.tap(find.byKey(_openKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        expect(find.byKey(_popupKey), findsOneWidget);
        expect(_popupRoute(tester).animation!.isCompleted, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        expect(_anyPopup, findsNothing);
        expect(app.closed, isTrue);
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
