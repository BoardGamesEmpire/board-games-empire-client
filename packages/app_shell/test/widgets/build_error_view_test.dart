import 'package:app_shell/app_shell.dart';
import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The view replaces Flutter's default in-build failure UI (debug red
/// screen / release grey box) via `ErrorWidget.builder`. Design pinned
/// here:
///
/// - **Localized, reassuring copy** from `ShellLocalizations`; never raw
///   exception text in release configuration.
/// - **Debug diagnostics** (decision 1a): the exception summary is
///   appended below the friendly message when [BuildErrorView.showDiagnostics]
///   is true; the parameter defaults to `kDebugMode`.
/// - **Live-region semantics** so screen readers announce the failure
///   when it appears mid-session, not only on focus.
/// - **Total function**: the view must never throw — it renders inside an
///   already-failing subtree, and a throw here cascades into
///   error-widget-inside-error-widget. When `ShellLocalizations` isn't in
///   scope (failure high in the tree), it falls back to the English
///   string.
/// - **Self-sufficient surface**: the view provides its own `Material`
///   background from the ambient theme, so it renders correctly whether
///   it replaces a tile or a whole screen. (The official sample's
///   Scaffold-sniffing wrap is dead code under `MaterialApp.router`,
///   whose builder child is a `Router`.)
///
/// Capture of the underlying failure is #34's job (`FlutterError.onError`
/// fires for the same error); this view is presentation only.
const String _enBody =
    "Board Games Empire couldn't display this part of the screen. "
    'The app is still running — going back or restarting usually clears it.';

void main() {
  FlutterErrorDetails details({Object? exception}) =>
      FlutterErrorDetails(exception: exception ?? StateError('kaboom'));

  Widget localizedHarness(Widget child) => MaterialApp(
    localizationsDelegates: ShellLocalizations.localizationsDelegates,
    supportedLocales: ShellLocalizations.supportedLocales,
    home: child,
  );

  group('BuildErrorView', () {
    testWidgets('renders the localized body', (tester) async {
      await tester.pumpWidget(
        localizedHarness(
          BuildErrorView(details: details(), showDiagnostics: false),
        ),
      );

      expect(find.text(_enBody), findsOneWidget);
    });

    testWidgets('announces via a live region so screen readers pick up '
        'the failure when it appears, not only on focus', (tester) async {
      await tester.pumpWidget(
        localizedHarness(
          BuildErrorView(details: details(), showDiagnostics: false),
        ),
      );

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('provides its own Material surface so it renders correctly '
        'at any subtree size', (tester) async {
      await tester.pumpWidget(
        localizedHarness(
          BuildErrorView(details: details(), showDiagnostics: false),
        ),
      );

      expect(
        find.ancestor(of: find.text(_enBody), matching: find.byType(Material)),
        findsWidgets,
      );
    });

    testWidgets('hides exception text when diagnostics are off '
        '(release behaviour)', (tester) async {
      await tester.pumpWidget(
        localizedHarness(
          BuildErrorView(details: details(), showDiagnostics: false),
        ),
      );

      expect(find.textContaining('kaboom'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);
    });

    testWidgets('appends the exception summary when diagnostics are on '
        '(debug behaviour, decision 1a)', (tester) async {
      await tester.pumpWidget(
        localizedHarness(
          BuildErrorView(details: details(), showDiagnostics: true),
        ),
      );

      expect(find.text(_enBody), findsOneWidget);
      expect(find.textContaining('Bad state: kaboom'), findsOneWidget);
    });

    testWidgets('showDiagnostics defaults to kDebugMode — diagnostics are '
        'visible under flutter_test without an explicit flag', (tester) async {
      // The coupling to kDebugMode is the assertion: the default IS
      // kDebugMode, and flutter_test always runs debug. The false branch
      // is covered by the explicit showDiagnostics: false tests above.
      await tester.pumpWidget(
        localizedHarness(BuildErrorView(details: details())),
      );

      expect(find.textContaining('Bad state: kaboom'), findsOneWidget);
    });

    testWidgets('excludes the diagnostics text from semantics — screen '
        'readers get the friendly message, not a raw exception string', (
      tester,
    ) async {
      await tester.pumpWidget(
        localizedHarness(
          BuildErrorView(details: details(), showDiagnostics: true),
        ),
      );

      expect(
        find.ancestor(
          of: find.textContaining('Bad state: kaboom'),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
    });

    testWidgets('centers content vertically — not pinned to the top', (
      tester,
    ) async {
      await tester.pumpWidget(
        localizedHarness(
          BuildErrorView(details: details(), showDiagnostics: false),
        ),
      );

      final bodyCenter = tester.getCenter(find.text(_enBody));
      final viewCenter = tester.getCenter(find.byType(BuildErrorView));
      expect(bodyCenter.dy, closeTo(viewCenter.dy, 1.0));
    });

    testWidgets('falls back to the English body when ShellLocalizations is '
        'not in scope — the view must be total, never a second failure', (
      tester,
    ) async {
      // MaterialApp WITHOUT the shell delegates: Localizations exists (the
      // Material defaults) but ShellLocalizations lookup yields null.
      await tester.pumpWidget(
        MaterialApp(
          home: BuildErrorView(details: details(), showDiagnostics: false),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(_enBody), findsOneWidget);
    });

    testWidgets('renders with ZERO ancestors — a failure at or above '
        'MaterialApp leaves no Directionality, Theme, or Localizations, '
        'and the view must still not cascade', (tester) async {
      await tester.pumpWidget(
        BuildErrorView(details: details(), showDiagnostics: false),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(_enBody), findsOneWidget);
    });
  });

  group('installBuildErrorView', () {
    // ErrorWidget.builder is a process global that flutter_test verifies
    // is restored at the end of every testWidgets — a check that runs
    // BEFORE tearDown callbacks. Restores therefore happen inside the
    // test body (try/finally), never in tearDown.

    test('replaces the default builder with one producing a BuildErrorView '
        'carrying the failure details', () {
      final saved = ErrorWidget.builder;
      try {
        installBuildErrorView();

        expect(ErrorWidget.builder, isNot(same(saved)));
        final failure = details();
        final widget = ErrorWidget.builder(failure);
        expect(widget, isA<BuildErrorView>());
        expect((widget as BuildErrorView).details, same(failure));
      } finally {
        ErrorWidget.builder = saved;
      }
    });

    test('re-installation is idempotent by replacement — no chaining', () {
      final saved = ErrorWidget.builder;
      try {
        installBuildErrorView();
        installBuildErrorView();

        expect(ErrorWidget.builder(details()), isA<BuildErrorView>());
      } finally {
        ErrorWidget.builder = saved;
      }
    });

    testWidgets('end to end: a widget that throws in build renders the '
        'localized error view instead of the stock ErrorWidget', (
      tester,
    ) async {
      final saved = ErrorWidget.builder;
      try {
        installBuildErrorView();

        await tester.pumpWidget(localizedHarness(const _ThrowsInBuild()));

        expect(tester.takeException(), isA<StateError>());
        expect(find.byType(BuildErrorView), findsOneWidget);
        expect(find.text(_enBody), findsOneWidget);
      } finally {
        ErrorWidget.builder = saved;
      }
    });
  });
}

/// Throws during build — the canonical trigger for `ErrorWidget.builder`.
class _ThrowsInBuild extends StatelessWidget {
  const _ThrowsInBuild();

  @override
  Widget build(BuildContext context) =>
      throw StateError('deliberate build failure');
}
