import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:data_export/data_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:mocktail/mocktail.dart';

/// The bundler's `assemble`, as the screen takes it.
abstract class _Assemble {
  Future<UserDataExportBundle> call(
    ActiveServer server, {
    bool refresh = false,
  });
}

class _MockAssemble extends Mock implements _Assemble {}

class _MockSink extends Mock implements UserDataExportSink {}

class _MockContainer extends Mock implements DependencyContainer {}

class _Exporter implements UserDataExporter {
  const _Exporter();

  @override
  String get key => 'gameCollection';

  @override
  String get categoryNameKey => 'collectionExportName';

  @override
  String get descriptionKey => 'collectionExportDescription';

  @override
  Future<UserDataExport?> export(ActiveServer server, {bool refresh = false}) =>
      throw UnimplementedError('The screen never runs an exporter itself.');
}

JSObject get _document => globalContext['document']! as JSObject;

/// The number of elements the web engine's semantics tree has in the page.
int semanticsElementCount() =>
    (_document.callMethod<JSObject>(
              'querySelectorAll'.toJS,
              'flt-semantics'.toJS,
            )['length']!
            as JSNumber)
        .toDartInt;

/// Turns the web engine's semantics tree on, as a screen reader does, by
/// activating the placeholder the engine puts in the page for it. The
/// engine keeps it on for the rest of the page's life.
void enableEngineSemantics() {
  (_document.callMethod(
    'querySelector'.toJS,
    'flt-semantics-placeholder'.toJS,
  ) as JSObject?)?.callMethod('click'.toJS);
}

/// The name of the element that has the browser's focus, its label or else
/// its text, when it is a semantics button, or null.
String? _focusedDomButton() {
  final active = _document['activeElement'] as JSObject?;
  final role = active?.callMethod('getAttribute'.toJS, 'role'.toJS);
  if (role == null || (role as JSString).toDart != 'button') return null;
  final label = active!.callMethod('getAttribute'.toJS, 'aria-label'.toJS);
  if (label != null) return (label as JSString).toDart;
  return (active['textContent'] as JSString?)?.toDart.trim();
}

/// Focus after a run, on the real web engine, with the screen under the
/// app's text-selection region, as on a desktop browser (#93).
///
/// With [semantics], the engine's semantics tree is on and the browser's
/// focus is checked as well as the framework's. Without it, the same steps
/// are the control.
void webFocusCases({required bool semantics}) {
  late _MockAssemble assemble;
  late _MockSink sink;

  setUpAll(() {
    // Before any test: the framework holds a semantics handle of its own
    // from then on, which a test must not see appear.
    if (semantics) enableEngineSemantics();
    registerFallbackValue(
      ActiveServer(
        serverId: 'fallback',
        displayName: 'Fallback',
        identity: testServerIdentity(),
        container: _MockContainer(),
      ),
    );
    registerFallbackValue(Uint8List(0));
  });

  setUp(() {
    assemble = _MockAssemble();
    sink = _MockSink();
  });

  void assembles(Future<UserDataExportBundle> Function() answer) => when(
    () => assemble(any(), refresh: any(named: 'refresh')),
  ).thenAnswer((_) => answer());

  void saves(Future<UserDataExportSaveResult> Function() answer) => when(
    () => sink.save(
      fileName: any(named: 'fileName'),
      bytes: any(named: 'bytes'),
    ),
  ).thenAnswer((_) => answer());

  UserDataExportBundle bundle({List<String> unconfirmed = const []}) =>
      UserDataExportBundle(
        json: const {
          'exportedAt': '2026-11-15T12:00:00.000Z',
          'serverName': 'Test BGE Server',
        },
        unconfirmedKeys: unconfirmed,
      );

  /// The screen under the app's selection region; [overAnotherPage] gives
  /// it a page to go back to, and so a back button before its content.
  Widget app({required bool overAnotherPage}) => MaterialApp(
    theme: pointerPlatformTheme(),
    builder: underSelectionRegion,
    localizationsDelegates: DataExportLocalizations.localizationsDelegates,
    supportedLocales: DataExportLocalizations.supportedLocales,
    home: overAnotherPage ? const Scaffold(body: SizedBox()) : null,
    onGenerateRoute: (_) => MaterialPageRoute<void>(
      builder: (_) => DataExportScreen(
        server: ActiveServer(
          serverId: 'local-1',
          displayName: 'My nickname for it',
          identity: testServerIdentity(),
          container: _MockContainer(),
        ),
        exporters: const [_Exporter()],
        assemble: assemble.call,
        sink: sink,
        labelResolvers: const [],
      ),
    ),
  );

  FocusNode exportNode(WidgetTester tester) => Focus.of(
    tester.element(
      find.descendant(
        of: find.byKey(DataExportScreen.exportKey),
        matching: find.byType(Text),
      ),
    ),
  );

  FocusNode outlinedNode(WidgetTester tester, Key key) =>
      tester.widget<OutlinedButton>(find.byKey(key)).focusNode!;

  FocusNode dismissNode(WidgetTester tester) => tester
      .widget<TextButton>(find.byKey(DataExportScreen.dismissKey))
      .focusNode!;

  Future<void> pumpScreen(
    WidgetTester tester, {
    required bool overAnotherPage,
  }) async {
    await tester.pumpWidget(app(overAnotherPage: overAnotherPage));
    if (overAnotherPage) {
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/export');
    }
    await tester.pumpAndSettle();
    // The page has the browser's focus, as when the user has clicked or
    // tabbed into it.
    (_document.callMethod('querySelector'.toJS, 'flutter-view'.toJS)!
            as JSObject)
        .callMethod('focus'.toJS);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(
      semanticsElementCount(),
      semantics ? greaterThan(0) : 0,
      reason: 'the engine semantics tree is ${semantics ? 'on' : 'off'}',
    );
  }

  /// A test that pumps the screen first, with the semantics tree held on
  /// for its body when [semantics] says so.
  void focusTest(
    String description,
    WidgetTesterCallback body, {
    bool overAnotherPage = false,
  }) => testWidgets(description, (tester) async {
    final handle = semantics ? tester.ensureSemantics() : null;
    try {
      await pumpScreen(tester, overAnotherPage: overAnotherPage);
      await body(tester);
    } finally {
      handle?.dispose();
    }
    // The engine clears a screen-reader announcement, such as a
    // banner's, on timers the fake clock owns.
    await tester.pump(const Duration(milliseconds: 300));
  });

  /// Presses Tab until [node] has focus, as a keyboard user gets there,
  /// and returns the nodes focus stopped on along the way.
  Future<List<FocusNode>> tabTo(
    WidgetTester tester,
    FocusNode Function() node,
  ) async {
    final stops = <FocusNode>[];
    for (var i = 0; i < 10 && !node().hasPrimaryFocus; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      stops.add(FocusManager.instance.primaryFocus!);
    }
    expect(node().hasPrimaryFocus, isTrue);
    // A frame for the engine to move the browser's focus there too.
    await tester.pump();
    if (semantics) expect(_focusedDomButton(), isNotNull);
    return stops;
  }

  /// Expects a warning button pressed from the keyboard to keep focus
  /// through its own run, the browser's included: it stays enabled and
  /// inert, so nothing moves focus off it, and it needs no parking.
  Future<void> expectKeepsFocusWhileBusy(
    WidgetTester tester,
    FocusNode node,
  ) async {
    // The frame after the busy one, for the browser's focus to settle.
    await tester.pump();
    expect(find.text('Preparing your export…'), findsOneWidget);
    expect(node.hasPrimaryFocus, isTrue);
    if (semantics) expect(_focusedDomButton(), 'Preparing your export…');
  }

  /// Lets a run's answer land, with the frame after it, where a hand-off's
  /// request applies, and a turn of the browser's event loop.
  ///
  /// The turn matters: what the engine sends the framework from a browser
  /// focus event runs outside the test's fake clock, so focus changes it
  /// asks for apply only when the browser gets a turn, as in a live page.
  Future<void> land(WidgetTester tester) async {
    await tester.pump(DataExportCubit.answerDwell);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  /// Presses Enter on whatever has focus.
  Future<void> enter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  /// Lands the warning, from a pointer press on Export.
  Future<void> toWarning(WidgetTester tester) async {
    assembles(() async => bundle(unconfirmed: ['gameCollection']));
    await tester.tap(find.byKey(DataExportScreen.exportKey));
    await tester.pump();
    await land(tester);
    expect(find.byKey(DataExportScreen.refreshKey), findsOneWidget);
  }

  void expectFocusOn(WidgetTester tester, FocusNode node, String domLabel) {
    expect(FocusManager.instance.primaryFocus, same(node));
    if (semantics) expect(_focusedDomButton(), domLabel);
  }

  focusTest('focus returns to Export when its run lands on a download', (
    tester,
  ) async {
    assembles(() async => bundle());
    saves(() async => UserDataExportSaveResult.downloaded);

    await tabTo(tester, () => exportNode(tester));
    await enter(tester);
    await land(tester);

    expect(find.text('Your download has started.'), findsOneWidget);
    expectFocusOn(tester, exportNode(tester), 'Export');
  });

  focusTest(
    'focus returns to Export when the user tabbed to it past another control',
    (tester) async {
      assembles(() async => bundle());
      saves(() async => UserDataExportSaveResult.downloaded);
      final back = Focus.of(tester.element(find.byType(BackButtonIcon)));

      final stops = await tabTo(tester, () => exportNode(tester));
      expect(stops, contains(back));
      await enter(tester);
      await land(tester);

      expect(find.text('Your download has started.'), findsOneWidget);
      expectFocusOn(tester, exportNode(tester), 'Export');
    },
    overAnotherPage: true,
  );

  focusTest('focus returns to Export when its run lands on the warning', (
    tester,
  ) async {
    assembles(() async => bundle(unconfirmed: ['gameCollection']));

    await tabTo(tester, () => exportNode(tester));
    await enter(tester);
    await land(tester);

    expect(find.byKey(DataExportScreen.refreshKey), findsOneWidget);
    expectFocusOn(tester, exportNode(tester), 'Export');
  });

  focusTest('focus goes to Export when the warning leaves on a failed '
      'refresh', (tester) async {
    await toWarning(tester);
    assembles(() async => throw StateError('exporter broke'));

    await tabTo(
      tester,
      () => outlinedNode(tester, DataExportScreen.refreshKey),
    );
    await enter(tester);
    await expectKeepsFocusWhileBusy(
      tester,
      outlinedNode(tester, DataExportScreen.refreshKey),
    );
    await land(tester);

    expect(find.byKey(DataExportScreen.refreshKey), findsNothing);
    expectFocusOn(tester, exportNode(tester), 'Export');
  });

  focusTest('focus goes to Dismiss when the warning leaves on a save', (
    tester,
  ) async {
    await toWarning(tester);
    saves(() async => UserDataExportSaveResult.saved);

    await tabTo(
      tester,
      () => outlinedNode(tester, DataExportScreen.saveAnywayKey),
    );
    await enter(tester);
    await expectKeepsFocusWhileBusy(
      tester,
      outlinedNode(tester, DataExportScreen.saveAnywayKey),
    );
    await land(tester);

    expect(find.byKey(DataExportScreen.saveAnywayKey), findsNothing);
    expectFocusOn(tester, dismissNode(tester), 'Dismiss');
  });
}
