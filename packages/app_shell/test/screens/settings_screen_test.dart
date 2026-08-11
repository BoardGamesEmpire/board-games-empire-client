import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart';
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
  }) async {
    await tester.pumpWidget(
      MaterialApp(
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
}
