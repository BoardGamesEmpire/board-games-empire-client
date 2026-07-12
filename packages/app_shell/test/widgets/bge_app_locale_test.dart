import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_platform_bootstrap.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// Pins the #33 capture + fallback behaviour at the widget layer:
///
/// - The controller ends up holding the **negotiated** locale, whatever
///   it was seeded with — the seed is only a pre-frame best effort.
/// - An OS locale the app does not support resolves to `en` via
///   Flutter's default resolution (en is first in `supportedLocales`),
///   with no custom resolution callback — and the capture reflects that
///   fallback, not the raw OS preference.
/// - Controller lifecycle ownership mirrors the root-container pattern.
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

  Future<void> pumpApp(
    WidgetTester tester, {
    ActiveLocaleController? controller,
    bool disposeController = false,
  }) async {
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        activeLocaleController: controller,
        disposeActiveLocaleControllerOnDispose: disposeController,
      ),
    );
    // Not pumpAndSettle: the mock cubit stays in Initializing, so the
    // splash spinner animates indefinitely and would never settle.
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  group('BgeApp — active locale capture (#33)', () {
    testWidgets('corrects the seeded value to the negotiated locale at '
        'the first frame', (tester) async {
      // Seeded with a locale the app does not even support — the raw OS
      // seed must never survive negotiation.
      final controller = ActiveLocaleController(const Locale('fr', 'FR'));
      addTearDown(controller.dispose);

      await pumpApp(tester, controller: controller);

      expect(controller.value, const Locale('en'));
      expect(controller.languageTag, 'en');
    });

    testWidgets('an unsupported OS locale falls back to en — first '
        'supported locale wins under default resolution', (tester) async {
      tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final controller = ActiveLocaleController(const Locale('de', 'DE'));
      addTearDown(controller.dispose);

      await pumpApp(tester, controller: controller);

      expect(
        controller.value.languageCode,
        'en',
        reason:
            'the capture reflects what the UI renders in, not the raw '
            'OS preference',
      );
    });

    testWidgets('no controller (default) wires no capture and builds '
        'normally', (tester) async {
      await pumpApp(tester);

      expect(find.byType(ActiveLocaleCapture), findsNothing);
      expect(find.byType(SplashScreen), findsOneWidget);
    });
  });

  group('BgeApp — active locale controller lifecycle', () {
    testWidgets('disposes an owned controller on unmount '
        '(disposeActiveLocaleControllerOnDispose: true)', (tester) async {
      final controller = ActiveLocaleController(const Locale('en'));
      final ownedCubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(),
        hydratedStorageInitializer: (_) async {},
      );

      await tester.pumpWidget(
        BgeApp(
          bootstrapCubit: ownedCubit,
          closeBootstrapCubitOnDispose: true,
          activeLocaleController: controller,
          disposeActiveLocaleControllerOnDispose: true,
        ),
      );
      await tester.pump();
      await unmount(tester);

      expect(
        () => controller.addListener(() {}),
        throwsFlutterError,
        reason: 'a disposed ChangeNotifier rejects new listeners',
      );
    });

    testWidgets('does not dispose an externally owned controller '
        '(default)', (tester) async {
      final controller = ActiveLocaleController(const Locale('en'));
      addTearDown(controller.dispose);

      await pumpApp(tester, controller: controller);
      await unmount(tester);

      void listener() {}
      controller.addListener(listener);
      controller.removeListener(listener);
    });
  });
}
