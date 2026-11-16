import 'dart:async';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:data_export/data_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

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
  const _Exporter(this.key, this.categoryNameKey, this.descriptionKey);

  @override
  final String key;

  @override
  final String categoryNameKey;

  @override
  final String descriptionKey;

  @override
  Future<UserDataExport?> export(ActiveServer server, {bool refresh = false}) =>
      throw UnimplementedError('The screen never runs an exporter itself.');
}

const _collection = _Exporter(
  'gameCollection',
  'collectionExportName',
  'collectionExportDescription',
);
const _profile = _Exporter(
  'profile',
  'profileExportName',
  'profileExportDescription',
);

const ExportCategoryLabels _collectionLabels = (
  name: 'Game collection',
  description: 'Every game in your collection.',
);
const ExportCategoryLabels _profileLabels = (
  name: 'Profile',
  description: 'Your public profile.',
);

ExportCategoryLabels? _collectionResolver(BuildContext context, String key) =>
    key == 'collectionExportName' || key == 'collectionExportDescription'
    ? _collectionLabels
    : null;

ExportCategoryLabels? _profileResolver(BuildContext context, String key) =>
    key == 'profileExportName' ? _profileLabels : null;

const _serverName = 'Test BGE Server';
const Duration _dwell = DataExportCubit.answerDwell;

const _preparing = 'Preparing your export…';
const _warningTitle = "This device's copy";
const _warning =
    "Game collection couldn't be checked with Test BGE Server, so it may be "
    'missing changes made on other devices.';
const _saved = 'Your data was saved.';
const _downloaded = 'Your download has started.';

UserDataExportBundle _bundle({List<String> unconfirmed = const []}) =>
    UserDataExportBundle(
      json: const {
        'exportedAt': '2026-11-15T12:00:00.000Z',
        'serverName': _serverName,
      },
      unconfirmedKeys: unconfirmed,
    );

void main() {
  late _MockAssemble assemble;
  late _MockSink sink;

  setUpAll(() {
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

  Widget app({
    ThemeData? theme,
    bool overAnotherPage = false,
    String serverName = _serverName,
    List<UserDataExporter> exporters = const [_collection],
    List<ExportCategoryLabelResolver> resolvers = const [_collectionResolver],
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: DataExportLocalizations.localizationsDelegates,
    supportedLocales: DataExportLocalizations.supportedLocales,
    home: overAnotherPage ? const _FirstPage() : null,
    onGenerateRoute: (_) => MaterialPageRoute<void>(
      builder: (_) => DataExportScreen(
        server: ActiveServer(
          serverId: 'local-1',
          displayName: 'My nickname for it',
          identity: testServerIdentity().copyWith(name: serverName),
          container: _MockContainer(),
        ),
        exporters: exporters,
        assemble: assemble.call,
        sink: sink,
        labelResolvers: resolvers,
      ),
    ),
  );

  Finder exportButton() => find.byKey(DataExportScreen.exportKey);
  Finder refresh() => find.byKey(DataExportScreen.refreshKey);
  Finder saveAnyway() => find.byKey(DataExportScreen.saveAnywayKey);
  Finder dismiss() => find.byKey(DataExportScreen.dismissKey);

  Finder bannerOf(BgeBannerTone tone) => find.byWidgetPredicate(
    (widget) => widget is BgeInlineBanner && widget.tone == tone,
  );

  FocusNode nodeOf(WidgetTester tester, Finder button) =>
      tester.widget<OutlinedButton>(button).focusNode!;

  Future<void> press(WidgetTester tester, Finder button) async {
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }

  /// Whether keyboard focus is on a control under the widget keyed [key].
  bool focusIsUnder(Key key) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget.key == key) return true;
    var under = false;
    context.visitAncestorElements((element) {
      under = element.widget.key == key;
      return !under;
    });
    return under;
  }

  /// The Export button's own focus node: the one its `FilledButton` keeps.
  FocusNode exportNode(WidgetTester tester) => Focus.of(
    tester.element(
      find.descendant(of: exportButton(), matching: find.byType(Text)),
    ),
  );

  /// Focuses the Export button and activates it from the keyboard.
  Future<void> exportFromKeyboard(WidgetTester tester) async {
    exportNode(tester).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  /// Focuses [button] and presses it.
  Future<void> focusAndPress(WidgetTester tester, Finder button) async {
    nodeOf(tester, button).requestFocus();
    await tester.pump();
    await press(tester, button);
  }

  /// Lets a run's answer land, and the frame after the one that built it,
  /// where a hand-off's focus request applies.
  Future<void> land(WidgetTester tester) async {
    await tester.pump(_dwell);
    await tester.pump();
  }

  /// Presses Export on a bundle whose collection is unconfirmed, and lets
  /// the answer land.
  Future<void> toWarning(WidgetTester tester) async {
    assembles(() async => _bundle(unconfirmed: ['gameCollection']));
    await press(tester, exportButton());
    await tester.pump(_dwell);
  }

  testWidgets('names the server by the name its identity gives itself', (
    tester,
  ) async {
    await tester.pumpWidget(app());

    expect(find.text('Export your data'), findsOneWidget);
    expect(
      find.text('Save a copy of your data on Test BGE Server as a JSON file.'),
      findsOneWidget,
    );
    expect(find.textContaining('My nickname for it'), findsNothing);
  });

  testWidgets('lists each exporter by its resolved name and description', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        exporters: const [_collection, _profile],
        resolvers: const [_collectionResolver, _profileResolver],
      ),
    );

    expect(find.text('Included'), findsOneWidget);
    expect(find.text('Game collection'), findsOneWidget);
    expect(find.text('Every game in your collection.'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Your public profile.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Game collection')).dy,
      lessThan(tester.getTopLeft(find.text('Profile')).dy),
    );
  });

  testWidgets('an unresolved key shows the key, never a blank row', (
    tester,
  ) async {
    await tester.pumpWidget(app(exporters: const [_collection, _profile]));

    expect(find.text('Game collection'), findsOneWidget);
    expect(find.text('profileExportName'), findsOneWidget);
  });

  testWidgets('the export button shows progress while assembling', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final assembled = Completer<UserDataExportBundle>();
    assembles(() => assembled.future);
    await tester.pumpWidget(app());

    await press(tester, exportButton());

    expect(
      tester.widget<BgeSubmitButton>(exportButton()).submitting,
      isTrue,
    );
    // The button's own node carries the progress label as its name.
    final button = tester.getSemantics(
      find.descendant(of: exportButton(), matching: find.byType(FilledButton)),
    );
    expect(button.label, _preparing);
    expect(button, isSemantics(isButton: true));
    handle.dispose();
  });

  testWidgets('the unconfirmed banner names the category and offers both '
      'actions', (tester) async {
    await tester.pumpWidget(app());

    await toWarning(tester);

    final banner = tester.widget<BgeInlineBanner>(
      bannerOf(BgeBannerTone.warning),
    );
    expect(banner.title, _warningTitle);
    expect(banner.message, _warning);
    expect(banner.announce, isTrue);
    expect(banner.action, isNull);
    expect(find.text('Refresh and export'), findsOneWidget);
    expect(find.text('Save this copy'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(refresh()).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(saveAnyway()).onPressed, isNotNull);
  });

  testWidgets('the warning names each unconfirmed category, in order', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        exporters: const [_collection, _profile],
        resolvers: const [_collectionResolver, _profileResolver],
      ),
    );
    assembles(
      () async => _bundle(unconfirmed: ['gameCollection', 'profile', 'other']),
    );

    await press(tester, exportButton());
    await tester.pump(_dwell);

    expect(
      tester.widget<BgeInlineBanner>(bannerOf(BgeBannerTone.warning)).message,
      startsWith('Game collection, Profile, other couldn'),
    );
  });

  testWidgets('"Save this copy" saves the bundle the warning is about', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await toWarning(tester);
    saves(() async => UserDataExportSaveResult.saved);

    await press(tester, saveAnyway());
    await tester.pump(_dwell);

    expect(find.text(_saved), findsOneWidget);
    expect(bannerOf(BgeBannerTone.warning), findsNothing);
    expect(refresh(), findsNothing);
    verify(
      () => assemble(any(), refresh: any(named: 'refresh')),
    ).called(1);
  });

  testWidgets('pressing "Refresh and export" keeps the warning and both '
      'buttons on screen while it runs', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app());
    await toWarning(tester);
    final refreshed = Completer<UserDataExportBundle>();
    assembles(() => refreshed.future);
    nodeOf(tester, refresh()).requestFocus();
    await tester.pump();

    await press(tester, refresh());
    await press(tester, refresh());

    expect(bannerOf(BgeBannerTone.warning), findsOneWidget);
    expect(refresh(), findsOneWidget);
    expect(saveAnyway(), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus,
      same(nodeOf(tester, refresh())),
    );
    verify(() => assemble(any(), refresh: true)).called(1);
    expect(
      tester.getSemantics(refresh()),
      isSemantics(hasEnabledState: true, isEnabled: false, isFocused: true),
    );
    expect(tester.widget<OutlinedButton>(saveAnyway()).onPressed, isNull);
    handle.dispose();
  });

  testWidgets('pressing "Save this copy" keeps the warning up while the save '
      'runs', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app());
    await toWarning(tester);
    final saved = Completer<UserDataExportSaveResult>();
    saves(() => saved.future);
    nodeOf(tester, saveAnyway()).requestFocus();
    await tester.pump();

    await press(tester, saveAnyway());
    await press(tester, saveAnyway());

    expect(bannerOf(BgeBannerTone.warning), findsOneWidget);
    expect(refresh(), findsOneWidget);
    expect(saveAnyway(), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus,
      same(nodeOf(tester, saveAnyway())),
    );
    verify(
      () => sink.save(
        fileName: any(named: 'fileName'),
        bytes: any(named: 'bytes'),
      ),
    ).called(1);
    expect(
      tester.getSemantics(saveAnyway()),
      isSemantics(hasEnabledState: true, isEnabled: false, isFocused: true),
    );
    expect(tester.widget<OutlinedButton>(refresh()).onPressed, isNull);
    handle.dispose();
  });

  testWidgets('the same warning twice is a new banner', (tester) async {
    await tester.pumpWidget(app());
    await toWarning(tester);
    final first = tester.state(bannerOf(BgeBannerTone.warning));
    final firstKey = tester.widget(bannerOf(BgeBannerTone.warning)).key;
    nodeOf(tester, refresh()).requestFocus();
    await tester.pump();

    await press(tester, refresh());
    await tester.pump(_dwell);

    expect(
      tester.widget(bannerOf(BgeBannerTone.warning)).key,
      isNot(firstKey),
    );
    expect(
      tester.state(bannerOf(BgeBannerTone.warning)),
      isNot(same(first)),
    );
    // The buttons sit outside the banner, so its new key leaves them, and
    // the focus on one, where they were.
    expect(
      FocusManager.instance.primaryFocus,
      same(nodeOf(tester, refresh())),
    );
  });

  testWidgets('the banner goes when a refresh confirms, and the buttons stay '
      'until the save lands', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app());
    await toWarning(tester);
    final saved = Completer<UserDataExportSaveResult>();
    assembles(() async => _bundle());
    saves(() => saved.future);

    await focusAndPress(tester, refresh());
    await tester.pump(_dwell);

    verify(
      () => sink.save(
        fileName: any(named: 'fileName'),
        bytes: any(named: 'bytes'),
      ),
    ).called(1);
    // The confirmed copy left the banner nothing to describe.
    expect(bannerOf(BgeBannerTone.warning), findsNothing);
    // The buttons, and the focus on the pressed one, stay through the save.
    expect(refresh(), findsOneWidget);
    expect(saveAnyway(), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus,
      same(nodeOf(tester, refresh())),
    );
    expect(
      tester.getSemantics(refresh()),
      isSemantics(hasEnabledState: true, isEnabled: false, isFocused: true),
    );
    expect(tester.widget<OutlinedButton>(saveAnyway()).onPressed, isNull);
    expect(tester.widget<BgeSubmitButton>(exportButton()).submitting, isTrue);

    saved.complete(UserDataExportSaveResult.saved);
    await land(tester);
    expect(refresh(), findsNothing);
    expect(saveAnyway(), findsNothing);
    handle.dispose();
  });

  testWidgets('Export pressed under the warning keeps the warning and disables '
      'both of its buttons', (tester) async {
    await tester.pumpWidget(app());
    await toWarning(tester);
    final banner = tester.state(bannerOf(BgeBannerTone.warning));
    await tester.ensureVisible(exportButton());
    await tester.pump();
    final refreshAt = tester.getTopLeft(refresh());
    final assembled = Completer<UserDataExportBundle>();
    assembles(() => assembled.future);

    await press(tester, exportButton());
    await tester.pump(_dwell);

    // The same banner, not a new one: nothing moves and nothing is said
    // again while the run is out.
    expect(tester.state(bannerOf(BgeBannerTone.warning)), same(banner));
    expect(tester.getTopLeft(refresh()), refreshAt);
    expect(tester.widget<OutlinedButton>(refresh()).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(saveAnyway()).onPressed, isNull);

    // Still unconfirmed: a new warning, announced again.
    assembled.complete(_bundle(unconfirmed: ['gameCollection']));
    await land(tester);
    expect(
      tester.state(bannerOf(BgeBannerTone.warning)),
      isNot(same(banner)),
    );
    expect(tester.widget<OutlinedButton>(refresh()).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(saveAnyway()).onPressed, isNotNull);
  });

  testWidgets('an inert warning button is named for what it is doing', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app());
    await toWarning(tester);
    final atRest = tester.getSize(refresh());
    expect(tester.getSemantics(refresh()).label, 'Refresh and export');
    expect(
      find.descendant(
        of: refresh(),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    final refreshed = Completer<UserDataExportBundle>();
    assembles(() => refreshed.future);

    await focusAndPress(tester, refresh());

    expect(tester.getSemantics(refresh()).label, _preparing);
    expect(
      find.descendant(
        of: refresh(),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(refresh()), atRest);
    // The other is disabled, not busy: it keeps its own name.
    expect(tester.getSemantics(saveAnyway()).label, 'Save this copy');

    refreshed.complete(_bundle(unconfirmed: ['gameCollection']));
    await land(tester);
    expect(tester.getSemantics(refresh()).label, 'Refresh and export');
    handle.dispose();
  });

  group('focus after an Export run', () {
    testWidgets('focus returns to Export when its run lands on a download', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.downloaded);

      await exportFromKeyboard(tester);
      // Disabled while it runs, the button lets its focus go.
      expect(exportNode(tester).hasPrimaryFocus, isFalse);
      await land(tester);

      expect(find.text(_downloaded), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(exportNode(tester)));
    });

    testWidgets('focus returns to Export when its run lands on the warning', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      assembles(() async => _bundle(unconfirmed: ['gameCollection']));

      await exportFromKeyboard(tester);
      await land(tester);

      expect(bannerOf(BgeBannerTone.warning), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(exportNode(tester)));
    });

    testWidgets('focus returns to Export when its run lands on a failure', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      assembles(() async => throw const ExportNotAuthenticatedException());

      await exportFromKeyboard(tester);
      await land(tester);

      expect(bannerOf(BgeBannerTone.error), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(exportNode(tester)));
    });

    testWidgets('focus returns to Export when its run lands after a cancelled '
        'save', (tester) async {
      await tester.pumpWidget(app());
      final saved = Completer<UserDataExportSaveResult>();
      assembles(() async => _bundle());
      saves(() => saved.future);

      await exportFromKeyboard(tester);
      // The save dialog is open, and the disabled button let its focus go.
      expect(exportNode(tester).hasPrimaryFocus, isFalse);
      saved.complete(UserDataExportSaveResult.cancelled);
      await land(tester);

      expect(find.byType(BgeInlineBanner), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(exportNode(tester)));
    });

    testWidgets('focus returns to Export when the user tabbed to it past '
        'another control', (tester) async {
      await tester.pumpWidget(app(overAnotherPage: true));
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/export');
      await tester.pumpAndSettle();
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.downloaded);
      final back = Focus.of(tester.element(find.byType(BackButtonIcon)));

      // Tab through the back button to Export, as a keyboard user does.
      final passed = <FocusNode>[];
      for (var i = 0; i < 5 && !exportNode(tester).hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        passed.add(FocusManager.instance.primaryFocus!);
      }
      expect(passed, contains(back));
      expect(exportNode(tester).hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // Disabled while it runs, Export let its focus go, and not to the
      // back button: the user didn't move it there.
      expect(back.hasPrimaryFocus, isFalse);
      await land(tester);

      expect(find.text(_downloaded), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(exportNode(tester)));
    });

    testWidgets('a pointer press on Export leaves focus on another control '
        'where it is', (tester) async {
      await tester.pumpWidget(app(overAnotherPage: true));
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/export');
      await tester.pumpAndSettle();
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.downloaded);
      final back = Focus.of(tester.element(find.byType(BackButtonIcon)))
        ..requestFocus();
      await tester.pump();

      await press(tester, exportButton());
      // The frame that disables Export, and its post-frame callback.
      await tester.pump();
      expect(find.text(_preparing), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(back));
      await land(tester);

      expect(find.text(_downloaded), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(back));
    });

    testWidgets('focus the user moved before the frame that disables Export '
        'stays put', (tester) async {
      await tester.pumpWidget(app(overAnotherPage: true));
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/export');
      await tester.pumpAndSettle();
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.downloaded);
      exportNode(tester).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      // Away to the back button in the same turn as the press, before the
      // frame that disables Export.
      final back = Focus.of(tester.element(find.byType(BackButtonIcon)))
        ..requestFocus();
      await tester.pump();
      expect(find.text(_preparing), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(back));
      await land(tester);

      expect(find.text(_downloaded), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(back));
    });

    testWidgets('focus the user moved during an Export run stays put', (
      tester,
    ) async {
      await tester.pumpWidget(app(overAnotherPage: true));
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/export');
      await tester.pumpAndSettle();
      final assembled = Completer<UserDataExportBundle>();
      assembles(() => assembled.future);
      saves(() async => UserDataExportSaveResult.saved);

      await exportFromKeyboard(tester);
      final back = Focus.of(tester.element(find.byType(BackButtonIcon)))
        ..requestFocus();
      await tester.pump();
      assembled.complete(_bundle());
      await land(tester);

      expect(find.text(_saved), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(back));
    });

    testWidgets('focus returns to Export when a run it started under the '
        'warning lands', (tester) async {
      await tester.pumpWidget(app());
      await toWarning(tester);
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.saved);

      await exportFromKeyboard(tester);
      expect(refresh(), findsOneWidget);
      await land(tester);

      // The landing took the warning's buttons down; none of them had focus,
      // so only the return to Export acts.
      expect(find.text(_saved), findsOneWidget);
      expect(refresh(), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(exportNode(tester)));
    });

    testWidgets('an Export run started without focus on it moves none', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      assembles(() async => _bundle(unconfirmed: ['gameCollection']));

      await press(tester, exportButton());
      await land(tester);

      expect(exportNode(tester).hasPrimaryFocus, isFalse);
    });
  });

  group('focus when the warning leaves', () {
    testWidgets('focus goes to Dismiss when "Save this copy" lands', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await toWarning(tester);
      saves(() async => UserDataExportSaveResult.saved);

      await focusAndPress(tester, saveAnyway());
      await land(tester);

      expect(saveAnyway(), findsNothing);
      expect(focusIsUnder(DataExportScreen.dismissKey), isTrue);
    });

    testWidgets('focus goes to Dismiss when a refresh confirms and saves', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await toWarning(tester);
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.downloaded);

      await focusAndPress(tester, refresh());
      await land(tester);

      expect(find.text(_downloaded), findsOneWidget);
      expect(focusIsUnder(DataExportScreen.dismissKey), isTrue);
    });

    testWidgets('focus goes to Export when a refresh fails', (tester) async {
      await tester.pumpWidget(app());
      await toWarning(tester);
      assembles(() async => throw StateError('exporter broke'));

      await focusAndPress(tester, refresh());
      await land(tester);

      expect(bannerOf(BgeBannerTone.error), findsOneWidget);
      expect(focusIsUnder(DataExportScreen.exportKey), isTrue);
    });

    testWidgets("focus goes to Export when a confirmed refresh's save is "
        'cancelled', (tester) async {
      await tester.pumpWidget(app());
      await toWarning(tester);
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.cancelled);

      await focusAndPress(tester, refresh());
      await land(tester);

      expect(find.byType(BgeInlineBanner), findsNothing);
      expect(focusIsUnder(DataExportScreen.exportKey), isTrue);
    });

    testWidgets('focus the user moved away stays put when the warning leaves', (
      tester,
    ) async {
      await tester.pumpWidget(app(overAnotherPage: true));
      tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/export');
      await tester.pumpAndSettle();
      await toWarning(tester);
      final saved = Completer<UserDataExportSaveResult>();
      saves(() => saved.future);
      await focusAndPress(tester, saveAnyway());

      // Away to the page's back button while the save runs.
      final back = Focus.of(tester.element(find.byType(BackButtonIcon)))
        ..requestFocus();
      await tester.pump();
      saved.complete(UserDataExportSaveResult.saved);
      await land(tester);

      expect(find.text(_saved), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(back));
    });

    testWidgets('a warning that stays keeps focus where it is', (tester) async {
      await tester.pumpWidget(app());
      await toWarning(tester);
      saves(() async => UserDataExportSaveResult.cancelled);

      await focusAndPress(tester, saveAnyway());
      await land(tester);

      expect(bannerOf(BgeBannerTone.warning), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus,
        same(nodeOf(tester, saveAnyway())),
      );
    });
  });

  group('the outcome', () {
    testWidgets('a save says so, announced, and Dismiss retires it', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.saved);

      await press(tester, exportButton());
      await tester.pump(_dwell);

      final banner = tester.widget<BgeInlineBanner>(
        bannerOf(BgeBannerTone.success),
      );
      expect(banner.message, _saved);
      expect(banner.announce, isTrue);
      expect(find.text('Dismiss'), findsOneWidget);

      await press(tester, dismiss());

      expect(bannerOf(BgeBannerTone.success), findsNothing);
    });

    testWidgets('a download says it has started', (tester) async {
      await tester.pumpWidget(app());
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.downloaded);

      await press(tester, exportButton());
      await tester.pump(_dwell);

      expect(find.text(_downloaded), findsOneWidget);
    });

    testWidgets('a cancelled save says nothing', (tester) async {
      await tester.pumpWidget(app());
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.cancelled);

      await press(tester, exportButton());
      await tester.pump(_dwell);

      expect(find.byType(BgeInlineBanner), findsNothing);
      expect(
        tester.widget<BgeSubmitButton>(exportButton()).submitting,
        isFalse,
      );
    });

    testWidgets('the same outcome twice is a new banner', (tester) async {
      await tester.pumpWidget(app());
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.saved);
      await press(tester, exportButton());
      await tester.pump(_dwell);
      final first = tester.state(bannerOf(BgeBannerTone.success));

      await press(tester, exportButton());
      await tester.pump(_dwell);

      expect(
        tester.state(bannerOf(BgeBannerTone.success)),
        isNot(same(first)),
      );
    });
  });

  testWidgets('a failure sits on the submit through BgeFormActions', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    assembles(() async => throw const ExportNotAuthenticatedException());

    await press(tester, exportButton());
    await tester.pump(_dwell);

    final actions = tester.widget<BgeFormActions>(find.byType(BgeFormActions));
    expect(actions.failure?.message, 'Sign in again to export your data.');
    expect(actions.failure?.title, isNull);
    expect(
      find.descendant(
        of: find.byType(BgeFormActions),
        matching: bannerOf(BgeBannerTone.error),
      ),
      findsOneWidget,
    );

    // A repeat of the same failure is a new banner.
    final first = tester.state(bannerOf(BgeBannerTone.error));
    await press(tester, exportButton());
    await tester.pump(_dwell);
    expect(tester.state(bannerOf(BgeBannerTone.error)), isNot(same(first)));
  });

  for (final (name, Object error, message) in [
    (
      'an unreadable session',
      ExportSessionUnavailableException(cause: Exception('store')),
      "Your sign-in couldn't be read on this device. Try again.",
    ),
    (
      'a broken exporter',
      StateError('broke'),
      "Your data couldn't be exported. Try again.",
    ),
  ]) {
    testWidgets('$name says so on the submit', (tester) async {
      assembles(() => Future.error(error));
      await tester.pumpWidget(app());

      await press(tester, exportButton());
      await tester.pump(_dwell);

      expect(
        tester
            .widget<BgeFormActions>(find.byType(BgeFormActions))
            .failure
            ?.message,
        message,
      );
    });
  }

  testWidgets('a file that cannot be saved says so on the submit', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    assembles(() async => _bundle());
    saves(() async => throw Exception('disk full'));

    await press(tester, exportButton());
    await tester.pump(_dwell);

    expect(
      tester
          .widget<BgeFormActions>(find.byType(BgeFormActions))
          .failure
          ?.message,
      "The file couldn't be saved. Try again.",
    );
  });

  group('fits at 320dp and 2.0× text scale', () {
    const longName =
        'The Riverside Board Game Club and Friends of Greater Example';

    Future<void> atNarrowLarge(WidgetTester tester) async {
      expect(longName, hasLength(60));
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(app(serverName: longName));
      // The scale reaches the screen, not only the test's dispatcher.
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('Included')))
            .scale(10),
        20,
      );
    }

    testWidgets('ready', (tester) async {
      await atNarrowLarge(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('assembling', (tester) async {
      await atNarrowLarge(tester);
      final assembled = Completer<UserDataExportBundle>();
      assembles(() => assembled.future);

      await press(tester, exportButton());

      expect(find.text(_preparing), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unconfirmed, with both buttons', (tester) async {
      await atNarrowLarge(tester);
      assembles(() async => _bundle(unconfirmed: ['gameCollection']));

      await press(tester, exportButton());
      await tester.pump(_dwell);
      await tester.pumpAndSettle();

      expect(refresh(), findsOneWidget);
      expect(saveAnyway(), findsOneWidget);
      for (final button in [refresh(), saveAnyway()]) {
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(button).width, lessThanOrEqualTo(320));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('refreshing, with its button busy', (tester) async {
      await atNarrowLarge(tester);
      assembles(() async => _bundle(unconfirmed: ['gameCollection']));
      await press(tester, exportButton());
      await tester.pump(_dwell);
      assembles(() => Completer<UserDataExportBundle>().future);

      await press(tester, refresh());

      for (final button in [refresh(), saveAnyway()]) {
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(button).width, lessThanOrEqualTo(320));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('saved', (tester) async {
      await atNarrowLarge(tester);
      assembles(() async => _bundle());
      saves(() async => UserDataExportSaveResult.saved);

      await press(tester, exportButton());
      await tester.pump(_dwell);
      await tester.pumpAndSettle();

      expect(find.text(_saved), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failed', (tester) async {
      await atNarrowLarge(tester);
      assembles(() async => throw const ExportNotAuthenticatedException());

      await press(tester, exportButton());
      await tester.pump(_dwell);
      await tester.pumpAndSettle();

      expect(bannerOf(BgeBannerTone.error), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('accessibility audit', () {
    /// Pumps [DataExportScreen] in [theme] and presses Export on what the
    /// mocks answer, letting the answer land.
    Future<void> Function(WidgetTester, ThemeData) exported() =>
        (tester, theme) async {
          await tester.pumpWidget(app(theme: theme));
          await press(tester, exportButton());
          await tester.pump(_dwell);
        };

    auditScreen(
      'ready',
      pump: (tester, theme) => tester.pumpWidget(app(theme: theme)),
    );

    auditScreen(
      'assembling',
      pump: (tester, theme) async {
        assembles(() => Completer<UserDataExportBundle>().future);
        await tester.pumpWidget(app(theme: theme));
        await press(tester, exportButton());
      },
      settle: false,
    );

    auditScreen(
      'unconfirmed, with both buttons',
      pump: (tester, theme) {
        assembles(() async => _bundle(unconfirmed: ['gameCollection']));
        return exported()(tester, theme);
      },
      arrange: (tester) async {
        expect(refresh(), findsOneWidget);
        expect(saveAnyway(), findsOneWidget);
      },
    );

    auditScreen(
      'saving, with the warning up',
      pump: (tester, theme) async {
        assembles(() async => _bundle(unconfirmed: ['gameCollection']));
        saves(() => Completer<UserDataExportSaveResult>().future);
        await exported()(tester, theme);
        await press(tester, saveAnyway());
      },
      arrange: (tester) async {
        expect(bannerOf(BgeBannerTone.warning), findsOneWidget);
        expect(tester.widget<OutlinedButton>(refresh()).onPressed, isNull);
      },
      settle: false,
    );

    auditScreen(
      'refreshing, with its button busy',
      pump: (tester, theme) async {
        assembles(() async => _bundle(unconfirmed: ['gameCollection']));
        await exported()(tester, theme);
        assembles(() => Completer<UserDataExportBundle>().future);
        await press(tester, refresh());
      },
      arrange: (tester) async {
        expect(bannerOf(BgeBannerTone.warning), findsOneWidget);
        expect(tester.widget<OutlinedButton>(saveAnyway()).onPressed, isNull);
      },
      settle: false,
    );

    auditScreen(
      'exporting from the warning, both of its buttons disabled',
      pump: (tester, theme) async {
        assembles(() async => _bundle(unconfirmed: ['gameCollection']));
        await exported()(tester, theme);
        assembles(() => Completer<UserDataExportBundle>().future);
        await press(tester, exportButton());
      },
      arrange: (tester) async {
        expect(bannerOf(BgeBannerTone.warning), findsOneWidget);
        expect(tester.widget<OutlinedButton>(refresh()).onPressed, isNull);
        expect(tester.widget<OutlinedButton>(saveAnyway()).onPressed, isNull);
      },
      settle: false,
    );

    auditScreen(
      'saving a confirmed refresh, the buttons up without the banner',
      pump: (tester, theme) async {
        assembles(() async => _bundle(unconfirmed: ['gameCollection']));
        await exported()(tester, theme);
        assembles(() async => _bundle());
        saves(() => Completer<UserDataExportSaveResult>().future);
        await press(tester, refresh());
      },
      arrange: (tester) async {
        expect(bannerOf(BgeBannerTone.warning), findsNothing);
        expect(refresh(), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'saved',
      pump: (tester, theme) {
        assembles(() async => _bundle());
        saves(() async => UserDataExportSaveResult.saved);
        return exported()(tester, theme);
      },
      arrange: (tester) async => expect(dismiss(), findsOneWidget),
    );

    auditScreen(
      'failed',
      pump: (tester, theme) {
        assembles(() async => throw const ExportNotAuthenticatedException());
        return exported()(tester, theme);
      },
      arrange: (tester) async =>
          expect(bannerOf(BgeBannerTone.error), findsOneWidget),
    );
  });
}

/// A page to open the export screen over, so it has a back button.
class _FirstPage extends StatelessWidget {
  const _FirstPage();

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}
