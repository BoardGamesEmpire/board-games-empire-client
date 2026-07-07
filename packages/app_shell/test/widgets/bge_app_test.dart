import 'package:app_shell/app_shell.dart';
import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_platform_bootstrap.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _ProbeLocalizations {}

class _ProbeDelegate extends LocalizationsDelegate<_ProbeLocalizations> {
  const _ProbeDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<_ProbeLocalizations> load(Locale locale) =>
      SynchronousFuture(_ProbeLocalizations());

  @override
  bool shouldReload(covariant _ProbeDelegate old) => false;
}

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
    List<LocalizationsDelegate<dynamic>> additionalDelegates = const [],
  }) async {
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        theme: theme,
        darkTheme: darkTheme,
        additionalLocalizationsDelegates: additionalDelegates,
      ),
    );
    // Not pumpAndSettle: the mock cubit stays in Initializing, so the
    // splash spinner animates indefinitely and would never settle.
    await tester.pump();
    return tester.widget<MaterialApp>(find.byType(MaterialApp));
  }

  group('BgeApp', () {
    testWidgets('boots into the router — splash visible while initializing', (
      tester,
    ) async {
      await pumpApp(tester);

      expect(find.byType(SplashScreen), findsOneWidget);
    });

    testWidgets('applies the provided light and dark themes (seam for #32)', (
      tester,
    ) async {
      final light = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      );
      final dark = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      );

      final app = await pumpApp(tester, theme: light, darkTheme: dark);

      expect(app.theme, same(light));
      expect(app.darkTheme, same(dark));
    });

    testWidgets('registers the shell localization delegates and appends '
        'additional ones (seam for #33/#37)', (tester) async {
      const probe = _ProbeDelegate();

      final app = await pumpApp(tester, additionalDelegates: const [probe]);

      expect(
        app.localizationsDelegates,
        containsAll(<Object>[ShellLocalizations.delegate, probe]),
      );
      expect(app.supportedLocales, ShellLocalizations.supportedLocales);
    });

    testWidgets('produces a localized application title', (tester) async {
      final app = await pumpApp(tester);

      expect(app.onGenerateTitle, isNotNull);
      final title = app.onGenerateTitle!(
        tester.element(find.byType(SplashScreen)),
      );
      expect(title, 'Board Games Empire');
    });
  });

  group('BgeApp lifecycle', () {
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('closes the cubit on unmount when it owns it '
        '(closeBootstrapCubitOnDispose: true)', (tester) async {
      final ownedCubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(),
        hydratedStorageInitializer: (_) async {},
      );

      await tester.pumpWidget(
        BgeApp(bootstrapCubit: ownedCubit, closeBootstrapCubitOnDispose: true),
      );
      await tester.pump();
      await unmount(tester);

      expect(ownedCubit.isClosed, isTrue);
    });

    testWidgets('does not close an externally owned cubit (default)', (
      tester,
    ) async {
      final externalCubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(),
        hydratedStorageInitializer: (_) async {},
      );
      addTearDown(externalCubit.close);

      await tester.pumpWidget(BgeApp(bootstrapCubit: externalCubit));
      await tester.pump();
      await unmount(tester);

      expect(externalCubit.isClosed, isFalse);
    });
  });
}
