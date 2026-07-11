import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapInitializing(),
    );
  });

  Future<MaterialApp> pumpApp(
    WidgetTester tester, {
    ThemeData? theme,
    ThemeData? darkTheme,
    ThemeData? highContrastTheme,
    ThemeData? highContrastDarkTheme,
  }) async {
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        theme: theme,
        darkTheme: darkTheme,
        highContrastTheme: highContrastTheme,
        highContrastDarkTheme: highContrastDarkTheme,
      ),
    );
    // Not pumpAndSettle: the mock cubit stays in Initializing, so the
    // splash spinner animates indefinitely and would never settle.
    await tester.pump();
    return tester.widget<MaterialApp>(find.byType(MaterialApp));
  }

  BuildContext splashContext(WidgetTester tester) =>
      tester.element(find.byType(SplashScreen));

  group('BgeApp theme defaults (#32)', () {
    testWidgets('shell defaults all four theme slots from BgeTheme when '
        'none are provided (thin apps)', (tester) async {
      final app = await pumpApp(tester);

      expect(app.theme!.colorScheme.primary, BgeColorSchemes.light.primary);
      expect(app.darkTheme!.colorScheme.primary, BgeColorSchemes.dark.primary);
      expect(
        app.highContrastTheme!.colorScheme.primary,
        BgeColorSchemes.highContrastLight.primary,
      );
      expect(
        app.highContrastDarkTheme!.colorScheme.primary,
        BgeColorSchemes.highContrastDark.primary,
      );
      // The token extension rides the default theme, so
      // Theme.of(context).extension<BgeTokens>()! is safe everywhere.
      expect(app.theme!.extension<BgeTokens>(), same(BgeTokens.standard));
    });

    testWidgets('explicit theme overrides win over the shell defaults', (
      tester,
    ) async {
      final light = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      );
      final hcLight = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
      );

      final app = await pumpApp(
        tester,
        theme: light,
        highContrastTheme: hcLight,
      );

      expect(app.theme, same(light));
      expect(app.highContrastTheme, same(hcLight));
      // Unprovided slots still default.
      expect(app.darkTheme!.colorScheme.primary, BgeColorSchemes.dark.primary);
    });
  });

  group('BgeApp text scaling (#32, WCAG 1.4.4)', () {
    testWidgets('clamps OS text scaling to BgeTextScale.maxScaleFactor', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 3.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpApp(tester);

      final scaler = MediaQuery.textScalerOf(splashContext(tester));
      expect(scaler.scale(10), 10 * BgeTextScale.maxScaleFactor);
    });

    testWidgets('honors OS text scaling below the ceiling untouched', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpApp(tester);

      final scaler = MediaQuery.textScalerOf(splashContext(tester));
      expect(scaler.scale(10), 15);
    });
  });

  group('BgeApp high-contrast selection (#32)', () {
    testWidgets('OS "increase contrast" selects the high-contrast light '
        'theme', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(highContrast: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      await pumpApp(tester);

      expect(
        Theme.of(splashContext(tester)).colorScheme.primary,
        BgeColorSchemes.highContrastLight.primary,
      );
    });

    testWidgets('OS "increase contrast" + dark brightness selects the '
        'high-contrast dark theme', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(highContrast: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      await pumpApp(tester);

      expect(
        Theme.of(splashContext(tester)).colorScheme.primary,
        BgeColorSchemes.highContrastDark.primary,
      );
    });

    testWidgets('without the OS signal, the normal light theme applies', (
      tester,
    ) async {
      await pumpApp(tester);

      expect(
        Theme.of(splashContext(tester)).colorScheme.primary,
        BgeColorSchemes.light.primary,
      );
    });
  });
}
