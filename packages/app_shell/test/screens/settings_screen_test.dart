import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockStorage extends Mock implements Storage {}

/// A minimal per-server entry for exercising per-server section
/// visibility without any backing state.
class _FakeEntry implements SettingsEntry {
  const _FakeEntry();
  @override
  String get id => 'fake';
  @override
  Widget build(BuildContext context) =>
      const Text('FAKE ENTRY', key: Key('fake_entry'));
}

void main() {
  late ThemeModeCubit themeModeCubit;
  late LocaleCubit localeCubit;

  setUp(() {
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    themeModeCubit = ThemeModeCubit();
    localeCubit = LocaleCubit();
  });

  tearDown(() {
    themeModeCubit.close();
    localeCubit.close();
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    required List<SettingsSection> sections,
    String? activeServerAlias,
    Size? size,
  }) async {
    // `MediaQueryData.size` is metadata, not constraints — a narrow or wide
    // window has to be set on the view or the widget still lays out against
    // the 800x600 default. Same trap `bge_page_test.dart` documents.
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      MaterialApp(
        // The real theme, so a measure assertion tests the wiring rather
        // than `BgeTokens.of`'s no-theme fallback agreeing with itself.
        theme: BgeTheme.light(),
        localizationsDelegates: ShellLocalizations.localizationsDelegates,
        supportedLocales: ShellLocalizations.supportedLocales,
        home: SettingsScreen(
          sections: sections,
          activeServerAlias: activeServerAlias,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<SettingsSection> appSections({required List<Locale> supportedLocales}) =>
      buildSettingsSections(
        themeModeCubit: themeModeCubit,
        localeCubit: localeCubit,
        supportedLocales: supportedLocales,
      );

  group('SettingsScreen — composition', () {
    testWidgets('renders the title and the app-level theme entry', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        sections: appSections(supportedLocales: const [Locale('en')]),
      );

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('General'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      // The three theme options render as radios.
      expect(find.byType(RadioListTile<ThemeMode>), findsNWidgets(3));
    });

    testWidgets('omits the language entry with a single supported locale', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        sections: appSections(supportedLocales: const [Locale('en')]),
      );

      expect(find.text('Language'), findsNothing);
    });

    testWidgets('shows the language entry with more than one supported '
        'locale', (tester) async {
      await pumpSettings(
        tester,
        sections: appSections(
          supportedLocales: const [Locale('en'), Locale('es')],
        ),
      );

      expect(find.text('Language'), findsOneWidget);
    });
  });

  group('SettingsScreen — per-server section visibility', () {
    List<SettingsSection> withPerServer(List<SettingsEntry> entries) => [
      SettingsSection(scope: SettingsScope.perServer, entries: entries),
    ];

    testWidgets('renders the per-server section under the server alias when a '
        'server is active and it has entries', (tester) async {
      await pumpSettings(
        tester,
        sections: withPerServer(const [_FakeEntry()]),
        activeServerAlias: 'Living Room Pi',
      );

      expect(find.text('Living Room Pi'), findsOneWidget);
      expect(find.byKey(const Key('fake_entry')), findsOneWidget);
    });

    testWidgets('omits the per-server section when no server is active', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        sections: withPerServer(const [_FakeEntry()]),
        activeServerAlias: null,
      );

      expect(find.text('Living Room Pi'), findsNothing);
      expect(find.byKey(const Key('fake_entry')), findsNothing);
    });

    testWidgets('omits an empty per-server section even with an active '
        'server', (tester) async {
      await pumpSettings(
        tester,
        sections: withPerServer(const []),
        activeServerAlias: 'Living Room Pi',
      );

      expect(find.text('Living Room Pi'), findsNothing);
    });
  });

  group('SettingsScreen — accessibility', () {
    testWidgets('theme options expose radio semantics with their labels', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSettings(
        tester,
        sections: appSections(supportedLocales: const [Locale('en')]),
      );

      // Scoped to each option's own tile rather than searched screen-wide.
      // A bare `bySemanticsLabel(RegExp('Light'))` matches any prose on the
      // screen that happens to contain the word — which is exactly what
      // happened when explanatory copy was added beneath the selector. The
      // claim under test is "each option carries its label", so assert it
      // against the option.
      for (final (key, label) in const [
        ('settings_theme_system', 'System default'),
        ('settings_theme_light', 'Light'),
        ('settings_theme_dark', 'Dark'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.bySemanticsLabel(RegExp(label)),
          ),
          findsWidgets,
          reason: '$key must expose its label to assistive technology',
        );
      }
      handle.dispose();
    });

    testWidgets('entries render in declaration order (logical focus order): '
        'theme precedes language', (tester) async {
      await pumpSettings(
        tester,
        sections: appSections(
          supportedLocales: const [Locale('en'), Locale('es')],
        ),
      );

      final themeY = tester.getTopLeft(find.text('Theme')).dy;
      final languageY = tester.getTopLeft(find.text('Language')).dy;
      expect(themeY, lessThan(languageY));
    });
  });

  group('SettingsScreen — interaction', () {
    testWidgets('tapping a theme option updates the backing cubit', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        sections: appSections(supportedLocales: const [Locale('en')]),
      );

      await tester.tap(find.byKey(const Key('settings_theme_dark')));
      await tester.pump();

      expect(themeModeCubit.state, ThemeMode.dark);
    });
  });

  group('theme-mode application', () {
    testWidgets('a theme-mode selection changes the applied brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        BlocBuilder<ThemeModeCubit, ThemeMode>(
          bloc: themeModeCubit,
          builder: (context, mode) => MediaQuery(
            data: const MediaQueryData(platformBrightness: Brightness.light),
            child: MaterialApp(
              theme: BgeTheme.light(),
              darkTheme: BgeTheme.dark(),
              themeMode: mode,
              home: Builder(
                builder: (context) => Text(
                  Theme.of(context).brightness == Brightness.dark
                      ? 'DARK'
                      : 'LIGHT',
                  textDirection: TextDirection.ltr,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('LIGHT'), findsOneWidget);

      themeModeCubit.select(ThemeMode.dark);
      // MaterialApp animates theme changes via AnimatedTheme (~200ms);
      // ThemeData.lerp holds brightness on the old value until t >= 0.5, so
      // a single pump() (0ms elapsed) would still read light. Settle it.
      await tester.pumpAndSettle();

      expect(find.text('DARK'), findsOneWidget);
    });
  });

  group('SettingsScreen width', () {
    testWidgets('caps the content column at the pane measure on desktop', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        sections: appSections(supportedLocales: const [Locale('en')]),
        size: const Size(2560, 1440),
      );

      // Measured on a row, not the list: the list is a sliver now and has no
      // width of its own. A row is what the measure actually governs, and a
      // ListTile-shaped row fills whatever it is given.
      //
      // The failure this pins: rows stretching the full width of a monitor,
      // stranding a trailing control an arm's length from its label. The pane
      // measure is wider than the 480 reading measure a form gets, because a
      // settings row is a label plus a control, not a line of prose.
      expect(
        tester.getSize(find.byKey(const Key('settings_theme_dark'))).width,
        BgeTokens.standard.paneMaxWidth,
      );
    });

    testWidgets('keeps the list collection semantics a screen reader needs', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSettings(
        tester,
        sections: appSections(
          supportedLocales: const [Locale('en'), Locale('es')],
        ),
        // Short, so the list genuinely overflows and the viewport is
        // scrollable — the count is only meaningful on a node that scrolls.
        size: const Size(400, 200),
      );

      // "Item 3 of 9". The count lives on the node that scrolls, and only a
      // real viewport puts it there — a list shrink-wrapped inside a box
      // scroll view splits the two apart, leaving the scrollable node with
      // no count and the counting node unable to scroll. Regressed once
      // already on the way to BgePage; this is what caught it.
      // Walked rather than looked up by finder: `tester.getSemantics`
      // resolves to the nearest merged ancestor, which is not the viewport's
      // node, so it reports null for both of these regardless.
      SemanticsNode? root;
      tester.binding.rootPipelineOwner.visitChildren((owner) {
        root ??= owner.semanticsOwner?.rootSemanticsNode;
      });

      int? countOnAScrollingNode;
      void walk(SemanticsNode node) {
        if (node.getSemanticsData().hasAction(SemanticsAction.scrollUp) &&
            node.scrollChildCount != null) {
          countOnAScrollingNode = node.scrollChildCount;
        }
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(root!);
      expect(
        countOnAScrollingNode,
        isNotNull,
        reason: 'the count has to sit on the node that actually scrolls',
      );
      expect(countOnAScrollingNode, greaterThan(0));
      handle.dispose();
    });

    testWidgets('fills a phone-width window', (tester) async {
      await pumpSettings(
        tester,
        sections: appSections(supportedLocales: const [Locale('en')]),
        size: const Size(360, 800),
      );

      // The cap is what makes this adaptive: below the measure it does not
      // bite, so the same widget fills a phone and stops short on a monitor.
      // Edge-to-edge, with no page gutter — a settings row's divider and
      // ripple run to the window edge the way a Material list surface does.
      expect(
        tester.getSize(find.byKey(const Key('settings_theme_dark'))).width,
        360,
      );
    });
  });
}
