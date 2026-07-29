import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

/// Exercises the #120 settings wiring that lives inside [BgeApp] —
/// `_createSettingsControllers`, `_buildSettingsRoute`, and the reactive
/// theme/locale binding — which the whole-`runBgeApp` bootstrap test can't
/// reach (it stubs hydrated storage to a no-op, so the controllers never
/// get created). These drive a mock cubit to a storage-ready state with a
/// real (mocked) `HydratedBloc.storage`, which is what makes the
/// controllers materialize.
void main() {
  late _MockAppBootstrapCubit cubit;
  late StreamController<AppBootstrapState> states;
  late Storage storage;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    states = StreamController<AppBootstrapState>();
    storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  tearDown(() => states.close());

  /// Pumps [BgeApp] starting at [AppBootstrapInitializing] (production's
  /// first frame — `initialize()` suspends before `runApp`).
  Future<void> pumpBooting(
    WidgetTester tester, {
    ThemeMode themeMode = ThemeMode.system,
    Locale? locale,
  }) async {
    whenListen(
      cubit,
      states.stream,
      initialState: const AppBootstrapInitializing(),
    );
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, themeMode: themeMode, locale: locale),
    );
    // Splash animates at Initializing, so a single frame (not settle).
    await tester.pump();
  }

  MaterialApp materialApp(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp));

  group('BgeApp settings wiring (#120)', () {
    testWidgets('resolves the settings route through _buildSettingsRoute once '
        'the controllers exist', (tester) async {
      await pumpBooting(tester);

      states.add(const AppBootstrapReady());
      await tester.pumpAndSettle();

      final router = materialApp(tester).routerConfig! as GoRouter;
      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(NotYetAvailableScreen), findsNothing);
    });

    testWidgets('honors the themeMode seed and does not discard it once '
        'storage is ready (regression)', (tester) async {
      await pumpBooting(tester, themeMode: ThemeMode.dark);
      expect(materialApp(tester).themeMode, ThemeMode.dark);

      states.add(const AppBootstrapReady());
      await tester.pumpAndSettle();

      // Nothing persisted (read → null), so the seed stands — it must NOT
      // flip to ThemeMode.system when the controller is created.
      expect(materialApp(tester).themeMode, ThemeMode.dark);
    });

    testWidgets('a persisted theme-mode overrides the seed', (tester) async {
      when(
        () => storage.read('ThemeModeCubit'),
      ).thenReturn({'themeMode': 'light'});

      await pumpBooting(tester, themeMode: ThemeMode.dark);

      states.add(const AppBootstrapReady());
      await tester.pumpAndSettle();

      expect(materialApp(tester).themeMode, ThemeMode.light);
    });

    testWidgets('creating the controllers does not remount MaterialApp — the '
        'element is preserved across Initializing → Ready (regression)', (
      tester,
    ) async {
      await pumpBooting(tester);
      final before = tester.element(find.byType(MaterialApp));

      states.add(const AppBootstrapReady());
      await tester.pumpAndSettle();

      final after = tester.element(find.byType(MaterialApp));
      expect(identical(before, after), isTrue);
    });
  });
}
