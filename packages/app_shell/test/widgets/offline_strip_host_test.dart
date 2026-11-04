import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/widgets/offline_strip_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:logging/logging.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_connectivity.dart';

const _offlineText = "You're offline. Changes will sync when you reconnect.";
const _backText = 'Back online';

const _contentKey = Key('content');

/// The window's top inset where a test gives it one.
const _inset = 24.0;

/// Where a screen below the strip reads the scope and its insets.
BuildContext _content(WidgetTester tester) =>
    tester.element(find.byKey(_contentKey));

/// The strip's one live-region node: the element whose label change is
/// what a screen reader announces.
final _liveRegion = find.descendant(
  of: find.byType(BgeOfflineStrip),
  matching: find.byType(MergeSemantics),
);

/// The host as the app wires it: in `MaterialApp`'s builder, above the
/// navigator, with the shell's strings.
Widget _app(ConnectivityService? connectivity) => MaterialApp(
  theme: BgeTheme.light(),
  localizationsDelegates: ShellLocalizations.localizationsDelegates,
  supportedLocales: ShellLocalizations.supportedLocales,
  builder: (context, child) => OfflineStripHost(
    connectivity: connectivity,
    child: _Below(child: child!),
  ),
  home: const SizedBox.expand(key: _contentKey),
);

/// Stands for what the app has between the host and its navigator: the
/// router and the selection region. It has no global key, unlike the
/// navigator, so a change of shape above it remounts it instead of moving
/// it.
class _Below extends StatefulWidget {
  const _Below({required this.child});

  final Widget child;

  @override
  State<_Below> createState() => _BelowState();
}

class _BelowState extends State<_Below> {
  @override
  Widget build(BuildContext context) => widget.child;
}

/// #49's timing: the strip waits 2 s before it says anything, holds "Back
/// online" for 2 s, and a control reads the debounced flag through
/// [BgeConnectivityScope].
void main() {
  late FakeConnectivity connectivity;

  setUp(() => connectivity = FakeConnectivity());
  tearDown(() => connectivity.close());

  /// Moves the fake to [state] and draws the frame the host asks for.
  ///
  /// `pump(Duration.zero)`, not `pump()`: the change reaches the host in a
  /// microtask, and with no frame already scheduled a bare `pump()` flushes
  /// microtasks only after deciding not to draw.
  Future<void> go(WidgetTester tester, ConnectivityState state) async {
    connectivity.change(state);
    await tester.pump(Duration.zero);
  }

  /// Gives the window a top inset of [_inset], as a status bar would.
  void useInset(WidgetTester tester) {
    tester.view.padding = FakeViewPadding(
      top: _inset * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.reset);
  }

  /// What the content sees while nothing is drawn yet: controls enabled, no
  /// notice for the unverified banner to step aside for, and its own top
  /// inset.
  ///
  /// The app above rebuilds first, as a theme, locale or keyboard change
  /// would. Entering the wait draws nothing, so without a rebuild the
  /// host's output for the wait would never be built at all.
  Future<void> expectUntouched(WidgetTester tester, String when) async {
    await tester.pumpWidget(_app(connectivity));
    final content = _content(tester);
    expect(BgeConnectivityScope.offlineOf(content), isFalse, reason: when);
    expect(
      BgeConnectivityScope.noticeShowingOf(content),
      isFalse,
      reason: when,
    );
    expect(MediaQuery.paddingOf(content).top, _inset, reason: when);
  }

  testWidgets('offline shows nothing for 2 s, then the strip', (tester) async {
    useInset(tester);
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);

    await tester.pump(const Duration(milliseconds: 1999));
    expect(find.text(_offlineText), findsNothing);
    await expectUntouched(tester, 'still waiting');

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(_offlineText), findsOneWidget);
  });

  testWidgets('flapping inside the wait shows nothing', (tester) async {
    useInset(tester);
    await tester.pumpWidget(_app(connectivity));

    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 1));
    await expectUntouched(tester, 'first wait');
    await go(tester, ConnectivityState.online);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(_offlineText), findsNothing);
    await expectUntouched(tester, 'back online inside the wait');
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text(_offlineText), findsNothing);
    expect(tester.getSize(find.byType(BgeOfflineStrip)).height, 0);
    await expectUntouched(tester, 'second wait');
  });

  testWidgets('reconnect shows Back online for 2 s, then collapses', (
    tester,
  ) async {
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));

    await go(tester, ConnectivityState.online);
    expect(find.text(_backText), findsOneWidget);
    expect(find.text(_offlineText), findsNothing);

    await tester.pump(const Duration(milliseconds: 1999));
    expect(find.text(_backText), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(_backText), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BgeOfflineStrip)).height, 0);
  });

  testWidgets('offline during the hold returns to the offline text without '
      'collapsing', (tester) async {
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    await go(tester, ConnectivityState.online);
    await tester.pump(const Duration(seconds: 1));
    final announcer = tester.element(_liveRegion);

    await go(tester, ConnectivityState.offline);

    expect(find.text(_offlineText), findsOneWidget);
    expect(find.text(_backText), findsNothing);
    expect(
      identical(tester.element(_liveRegion), announcer),
      isTrue,
      reason: 'the same node changes its label, which is what announces',
    );

    // Past where the cancelled hold would have collapsed it, the strip is
    // still there, at the same height.
    await tester.pumpAndSettle();
    final height = tester.getSize(find.byType(BgeOfflineStrip)).height;
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_offlineText), findsOneWidget);
    expect(identical(tester.element(_liveRegion), announcer), isTrue);
    expect(tester.getSize(find.byType(BgeOfflineStrip)).height, height);
  });

  testWidgets('controls come back at reconnect, not after the hold', (
    tester,
  ) async {
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    expect(BgeConnectivityScope.offlineOf(_content(tester)), isTrue);
    expect(
      BgeConnectivityScope.onlineOnlyReasonOf(_content(tester)),
      "Available when you're online",
    );

    await go(tester, ConnectivityState.online);

    expect(find.text(_backText), findsOneWidget);
    expect(BgeConnectivityScope.offlineOf(_content(tester)), isFalse);
    expect(BgeConnectivityScope.noticeShowingOf(_content(tester)), isTrue);
  });

  testWidgets('unknown counts as online', (tester) async {
    await tester.pumpWidget(_app(connectivity));

    await go(tester, ConnectivityState.unknown);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(_offlineText), findsNothing);
    expect(BgeConnectivityScope.offlineOf(_content(tester)), isFalse);

    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_offlineText), findsOneWidget);

    await go(tester, ConnectivityState.unknown);
    expect(find.text(_backText), findsOneWidget);
    expect(BgeConnectivityScope.offlineOf(_content(tester)), isFalse);
  });

  testWidgets('the strip consumes the top inset and gives it back on '
      'collapse', (tester) async {
    tester.view.padding = FakeViewPadding(
      top: 24 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(connectivity));
    double contentInset() => MediaQuery.paddingOf(_content(tester)).top;
    expect(contentInset(), 24);

    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    expect(contentInset(), 0, reason: 'an app bar below would inset twice');
    expect(
      tester.getTopLeft(find.text(_offlineText)).dy,
      greaterThanOrEqualTo(24),
      reason: 'the strip took the inset itself',
    );

    await go(tester, ConnectivityState.online);
    expect(contentInset(), 0, reason: 'Back online is still on screen');

    await tester.pump(const Duration(seconds: 2));
    expect(contentInset(), 24, reason: 'back the frame the strip collapses');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BgeOfflineStrip)).height, 0);
    expect(contentInset(), 24);
  });

  testWidgets('null connectivity: online, nothing drawn', (tester) async {
    await tester.pumpWidget(_app(null));
    await tester.pump(const Duration(seconds: 5));

    // The strip is there, empty: the same shape as with a service, so one
    // that arrives later does not remount the app.
    expect(find.byType(BgeOfflineStrip), findsOneWidget);
    expect(tester.getSize(find.byType(BgeOfflineStrip)).height, 0);
    expect(find.text(_offlineText), findsNothing);
    expect(BgeConnectivityScope.offlineOf(_content(tester)), isFalse);
    expect(BgeConnectivityScope.noticeShowingOf(_content(tester)), isFalse);
  });

  testWidgets('a duplicate offline does not restart the wait', (tester) async {
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 1));

    // What a resubscription's replay looks like to the host.
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text(_offlineText), findsOneWidget);
  });

  testWidgets('a duplicate online does not restart the hold', (tester) async {
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    await go(tester, ConnectivityState.online);
    await tester.pump(const Duration(seconds: 1));

    await go(tester, ConnectivityState.online);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text(_backText), findsNothing);
  });

  testWidgets('offline when the host mounts shows the strip after 2 s', (
    tester,
  ) async {
    connectivity.current = ConnectivityState.offline;
    await tester.pumpWidget(_app(connectivity));

    await tester.pump(const Duration(milliseconds: 1999));
    expect(find.text(_offlineText), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(_offlineText), findsOneWidget);
  });

  testWidgets('a new service instance is followed', (tester) async {
    final next = FakeConnectivity();
    addTearDown(next.close);

    // The shell's service can arrive after the first build.
    await tester.pumpWidget(_app(null));
    final below = tester.state(find.byType(_Below));
    await tester.pumpWidget(_app(connectivity));
    expect(connectivity.listened, isTrue);
    expect(
      identical(tester.state(find.byType(_Below)), below),
      isTrue,
      reason: 'a service arriving must not remount the app below',
    );

    await tester.pumpWidget(_app(next));
    expect(connectivity.listened, isFalse);
    expect(next.listened, isTrue);

    // The first service is no longer heard.
    connectivity.change(ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(_offlineText), findsNothing);

    next.change(ConnectivityState.offline);
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_offlineText), findsOneWidget);
    expect(identical(tester.state(find.byType(_Below)), below), isTrue);

    // No service is no news of a lost connection: the strip goes, without
    // claiming the connection came back.
    await tester.pumpWidget(_app(null));
    expect(next.listened, isFalse);
    expect(find.text(_offlineText), findsNothing);
    expect(find.text(_backText), findsNothing);
    expect(BgeConnectivityScope.offlineOf(_content(tester)), isFalse);
    expect(identical(tester.state(find.byType(_Below)), below), isTrue);
  });

  testWidgets('the content below stays mounted through a whole episode', (
    tester,
  ) async {
    await tester.pumpWidget(_app(connectivity));
    final below = tester.state(find.byType(_Below));
    void expectMounted(String when) => expect(
      identical(tester.state(find.byType(_Below)), below),
      isTrue,
      reason: when,
    );

    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    expectMounted('strip showing');
    await go(tester, ConnectivityState.online);
    expectMounted('Back online');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expectMounted('collapsed');
  });

  testWidgets('the strip reaches a screen reader over the route below it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // Every route carries a modal barrier, which drops the semantics of
    // whatever was painted before it, up to the nearest container.
    expect(find.byType(ModalBarrier), findsWidgets);
    expect(
      tester.getSemantics(find.text(_offlineText)),
      matchesSemantics(label: _offlineText, isLiveRegion: true),
    );
    handle.dispose();
  });

  testWidgets('an error on the stream changes nothing and throws nothing', (
    tester,
  ) async {
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final logs = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await logs.cancel();
      Logger.root.level = previousLevel;
    });
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    final announcer = tester.element(_liveRegion);

    final error = StateError('connectivity source failed');
    connectivity.fail(error);
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(seconds: 3));

    expect(tester.takeException(), isNull);
    expect(find.text(_offlineText), findsOneWidget);
    expect(identical(tester.element(_liveRegion), announcer), isTrue);
    expect(BgeConnectivityScope.offlineOf(_content(tester)), isTrue);
    expect(
      records.where(
        (r) =>
            r.loggerName == 'bge.shell.offline_strip' &&
            r.level == Level.WARNING &&
            identical(r.error, error),
      ),
      hasLength(1),
    );

    // Still listening: the next state arrives as usual.
    await go(tester, ConnectivityState.online);
    expect(find.text(_backText), findsOneWidget);
    expect(BgeConnectivityScope.offlineOf(_content(tester)), isFalse);
  });

  // flutter_test fails a test that ends with a timer still pending, so each
  // of these passes only if disposal cancelled the wait or the hold.
  testWidgets('disposing mid-wait leaves no timer running', (tester) async {
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 1));

    await tester.pumpWidget(const SizedBox.shrink());

    expect(connectivity.listened, isFalse);
  });

  testWidgets('disposing mid-hold leaves no timer running', (tester) async {
    await tester.pumpWidget(_app(connectivity));
    await go(tester, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    await go(tester, ConnectivityState.online);
    await tester.pump(const Duration(seconds: 1));

    await tester.pumpWidget(const SizedBox.shrink());

    expect(connectivity.listened, isFalse);
  });
}
