import 'package:app_shell/app_shell.dart';
import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: ShellLocalizations.localizationsDelegates,
  supportedLocales: ShellLocalizations.supportedLocales,
  home: child,
);

void main() {
  group('SplashScreen', () {
    testWidgets('shows a progress indicator with a screen-reader label', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(const SplashScreen()));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.bySemanticsLabel('Loading Board Games Empire'),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });

  group('NotYetAvailableScreen', () {
    testWidgets('shows the localized title and body', (tester) async {
      await tester.pumpWidget(_wrap(const NotYetAvailableScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Not yet available'), findsOneWidget);
      expect(find.textContaining("isn't available yet"), findsOneWidget);
    });
  });

  group('ShellPlaceholderScreen', () {
    for (final (kind, title) in const [
      (ShellPlaceholderKind.serverAdd, 'Add a server'),
      (ShellPlaceholderKind.auth, 'Sign in'),
      (ShellPlaceholderKind.home, 'Home'),
    ]) {
      testWidgets('renders the localized title for $kind', (tester) async {
        await tester.pumpWidget(_wrap(ShellPlaceholderScreen(kind: kind)));
        await tester.pumpAndSettle();

        expect(find.text(title), findsOneWidget);
        expect(find.textContaining('under construction'), findsOneWidget);
      });
    }
  });

  group('BootstrapErrorScreen', () {
    Widget buildScreen({
      bool canOfferReset = false,
      VoidCallback? onRetry,
      VoidCallback? onReset,
    }) => _wrap(
      BootstrapErrorScreen(
        canOfferReset: canOfferReset,
        onRetry: onRetry ?? () {},
        onReset: onReset ?? () {},
      ),
    );

    testWidgets('announces the failure to screen readers as a live region', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      expect(find.text('Startup failed'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Startup failed')),
        containsSemantics(isLiveRegion: true),
      );
      semantics.dispose();
    });

    testWidgets('retry button meets the 48dp tap-target minimum and fires '
        'its callback', (tester) async {
      var retried = 0;
      await tester.pumpWidget(buildScreen(onRetry: () => retried++));
      await tester.pumpAndSettle();

      final retry = find.byKey(BootstrapErrorScreen.retryButtonKey);
      expect(retry, findsOneWidget);
      final size = tester.getSize(retry);
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));

      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(retried, 1);
    });

    testWidgets('hides the destructive reset action until it is offered', (
      tester,
    ) async {
      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      expect(find.byKey(BootstrapErrorScreen.resetButtonKey), findsNothing);
    });

    testWidgets('reset requires explicit confirmation before firing', (
      tester,
    ) async {
      var resets = 0;
      await tester.pumpWidget(
        buildScreen(canOfferReset: true, onReset: () => resets++),
      );
      await tester.pumpAndSettle();

      final reset = find.byKey(BootstrapErrorScreen.resetButtonKey);
      expect(reset, findsOneWidget);

      await tester.tap(reset);
      await tester.pumpAndSettle();

      // Confirmation dialog spells out exactly what is deleted.
      expect(find.text('Delete local data?'), findsOneWidget);
      expect(
        find.textContaining('Data on your servers is not affected'),
        findsOneWidget,
      );
      expect(resets, 0);

      await tester.tap(find.byKey(BootstrapErrorScreen.resetConfirmButtonKey));
      await tester.pumpAndSettle();

      expect(resets, 1);
      expect(find.text('Delete local data?'), findsNothing);
    });

    testWidgets('cancelling the confirmation performs no reset', (
      tester,
    ) async {
      var resets = 0;
      await tester.pumpWidget(
        buildScreen(canOfferReset: true, onReset: () => resets++),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(BootstrapErrorScreen.resetButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(BootstrapErrorScreen.resetCancelButtonKey));
      await tester.pumpAndSettle();

      expect(resets, 0);
      expect(find.text('Delete local data?'), findsNothing);
    });
  });
}
