import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _wrap(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme,
  localizationsDelegates: ShellLocalizations.localizationsDelegates,
  supportedLocales: ShellLocalizations.supportedLocales,
  home: child,
);

/// Scrolls the page to its end, for what a state leaves below the fold at
/// 320dp × 2.0, which the audit can't see from the top (#50).
Future<void> _scrollToEnd(WidgetTester tester) async {
  final position = pageScrollOf(tester).position;
  position.jumpTo(position.maxScrollExtent);
}

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

    group('accessibility audit', () {
      // The spinner never settles.
      auditScreen(
        'loading',
        settle: false,
        build: (theme) => _wrap(const SplashScreen(), theme: theme),
      );
    });
  });

  group('NotYetAvailableScreen', () {
    testWidgets('shows the localized title and body', (tester) async {
      await tester.pumpWidget(_wrap(const NotYetAvailableScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Not yet available'), findsOneWidget);
      expect(find.textContaining("isn't available yet"), findsOneWidget);
    });

    testWidgets('titles its app bar, and says the title once (#308)', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const NotYetAvailableScreen()));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Not yet available'),
        ),
        findsOneWidget,
      );
      // Not repeated as a heading in the body under it.
      expect(find.text('Not yet available'), findsOneWidget);
    });

    testWidgets('pushed over another screen, has a way back to it (#308)', (
      tester,
    ) async {
      // Most routes that fall back to this screen are pushed (feedback,
      // settings) or have a parent beneath them (the household routes).
      // With no app bar there was no back button to imply, and on desktop
      // nothing else to press.
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => const NotYetAvailableScreen(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(NotYetAvailableScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    group('accessibility audit', () {
      // Pushed, as most routes that fall back to it are, so the app bar's
      // back button is audited too.
      auditScreen(
        'ready, pushed over another screen',
        build: (theme) => _wrap(const SizedBox.shrink(), theme: theme),
        arrange: (tester) async {
          tester
              .state<NavigatorState>(find.byType(Navigator))
              .push<void>(
                MaterialPageRoute(
                  builder: (_) => const NotYetAvailableScreen(),
                ),
              );
        },
      );
    });
  });

  group('ShellPlaceholderScreen', () {
    for (final (kind, title) in const [
      (ShellPlaceholderKind.serverAdd, 'Add a server'),
      (ShellPlaceholderKind.auth, 'Sign in'),
    ]) {
      testWidgets('renders the localized title for $kind', (tester) async {
        await tester.pumpWidget(_wrap(ShellPlaceholderScreen(kind: kind)));
        await tester.pumpAndSettle();

        expect(find.text(title), findsOneWidget);
        expect(find.textContaining('under construction'), findsOneWidget);
      });
    }

    group('accessibility audit', () {
      for (final kind in ShellPlaceholderKind.values) {
        auditScreen(
          'ready (${kind.name})',
          build: (theme) =>
              _wrap(ShellPlaceholderScreen(kind: kind), theme: theme),
        );
      }
    });
  });

  group('BootstrapErrorScreen', () {
    Widget buildScreen({
      bool canOfferReset = false,
      VoidCallback? onRetry,
      VoidCallback? onReset,
      ThemeData? theme,
    }) => _wrap(
      BootstrapErrorScreen(
        canOfferReset: canOfferReset,
        onRetry: onRetry ?? () {},
        onReset: onReset ?? () {},
      ),
      theme: theme,
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
        isSemantics(isLiveRegion: true),
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

    group('reset confirmation width', () {
      /// Opens the confirmation at [window] and returns the dialog's size.
      ///
      /// Under `BgeTheme`, because the width comes from the theme (#207). The
      /// size is the dialog's `Material`, not the `AlertDialog`: the route
      /// widget fills the window, so measuring it measures nothing.
      Future<Size> openAt(WidgetTester tester, Size window) async {
        useViewSize(tester, window);
        await tester.pumpWidget(
          _wrap(
            BootstrapErrorScreen(
              canOfferReset: true,
              onRetry: () {},
              onReset: () {},
            ),
            theme: BgeTheme.light(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(BootstrapErrorScreen.resetButtonKey));
        await tester.pumpAndSettle();

        return tester.getSize(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Material),
              )
              .first,
        );
      }

      testWidgets('stops at the reading measure on a wide window', (
        tester,
      ) async {
        // Unthemed, this dialog grew to the window minus Flutter's 40dp
        // insets: 2480 wide, with its whole warning on one line.
        final size = await openAt(tester, const Size(2560, 1440));

        expect(
          size.width,
          lessThanOrEqualTo(BgeTokens.standard.contentMaxWidth),
        );
      });

      testWidgets('still lays out in a 320-wide window', (tester) async {
        // The theme restates a 280 minimum, which is wider than the 240 left
        // inside the 40dp insets here. A minimum must yield to the window,
        // not overflow it, so the dialog takes exactly the 240 and not the
        // window's 320.
        final size = await openAt(tester, const Size(320, 640));

        expect(tester.takeException(), isNull);
        expect(size.width, 240);
      });
    });

    group('accessibility audit', () {
      Widget failure(ThemeData theme) => buildScreen(theme: theme);
      Widget resetOffered(ThemeData theme) =>
          buildScreen(canOfferReset: true, theme: theme);

      auditScreen('failure', build: failure);

      auditScreen(
        'failure, scrolled to the end',
        build: failure,
        arrange: _scrollToEnd,
      );

      auditScreen('failure, reset offered', build: resetOffered);

      auditScreen(
        'failure, reset offered, scrolled to the end',
        build: resetOffered,
        arrange: _scrollToEnd,
      );

      auditScreen(
        'reset confirmation',
        build: resetOffered,
        arrange: (tester) async {
          final reset = find.byKey(BootstrapErrorScreen.resetButtonKey);
          await tester.ensureVisible(reset);
          await tester.pumpAndSettle();
          await tester.tap(reset);
        },
      );
    });
  });

  group('RouteNotFoundScreen', () {
    group('accessibility audit', () {
      auditScreen(
        'ready',
        build: (theme) => _wrap(const RouteNotFoundScreen(), theme: theme),
      );
    });
  });
}
