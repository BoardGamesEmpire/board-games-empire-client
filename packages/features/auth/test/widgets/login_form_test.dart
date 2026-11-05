import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/widgets/login_form.dart';

import '../support/auth_test_fixtures.dart';

// #37 i18n: the form resolves all copy from AuthLocalizations, so the
// harness must provide the delegates; assertions keep matching the
// English template values.
Widget _wrap(Widget child, MockAuthBloc bloc) => MaterialApp(
  localizationsDelegates: AuthLocalizations.localizationsDelegates,
  supportedLocales: AuthLocalizations.supportedLocales,
  home: Scaffold(
    body: BlocProvider<AuthBloc>.value(value: bloc, child: child),
  ),
);

/// Every live region on screen. Needs semantics on.
final _liveRegions = find.semantics.byPredicate(
  (node) => node.flagsCollection.isLiveRegion,
);

void main() {
  setUpAll(() {
    registerFallbackValue(const AuthSessionCheckRequested());
    registerFallbackValue(const AuthInitial());
  });

  late MockAuthBloc mockBloc;

  setUp(() {
    mockBloc = MockAuthBloc();
    when(() => mockBloc.state).thenReturn(const AuthInitial());
  });

  group('LoginForm', () {
    testWidgets('renders email and password fields', (tester) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      expect(
        find.bySemanticsLabel(RegExp('Email', caseSensitive: false)),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(RegExp('Password', caseSensitive: false)),
        findsWidgets,
      );
    });

    testWidgets('shows sign-in button', (tester) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      expect(find.widgetWithText(FilledButton, 'Sign In'), findsOneWidget);
    });

    testWidgets('shows loading indicator when AuthLoading state', (
      tester,
    ) async {
      when(() => mockBloc.state).thenReturn(const AuthLoading());
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('disables inputs during AuthLoading', (tester) async {
      when(() => mockBloc.state).thenReturn(const AuthLoading());
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('does not submit when fields are empty', (tester) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
      await tester.pump();

      verifyNever(() => mockBloc.add(any()));
    });

    testWidgets('adds AuthSignInRequested with valid credentials', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      await tester.enterText(
        find.bySemanticsLabel(RegExp('Email', caseSensitive: false)).first,
        'user@example.com',
      );
      await tester.enterText(
        find.bySemanticsLabel(RegExp('Password', caseSensitive: false)).first,
        'securepassword',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
      await tester.pump();

      verify(
        () => mockBloc.add(
          const AuthSignInRequested(
            email: 'user@example.com',
            password: 'securepassword',
          ),
        ),
      ).called(1);
    });

    // ── #187: sign-in must not enforce a length policy ──────────────
    //
    // Length policy is a registration rule. At sign-in the server is the
    // only authority on whether a credential is valid, and this product is
    // self-hosted: a hoster running a shorter minimum, an older policy or
    // an admin-provisioned account must still be able to sign in.

    testWidgets('submits a password shorter than the registration minimum', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      await tester.enterText(
        find.bySemanticsLabel(RegExp('Email', caseSensitive: false)).first,
        'user@example.com',
      );
      await tester.enterText(
        find.bySemanticsLabel(RegExp('Password', caseSensitive: false)).first,
        'short',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
      await tester.pump();

      verify(
        () => mockBloc.add(
          const AuthSignInRequested(
            email: 'user@example.com',
            password: 'short',
          ),
        ),
      ).called(1);
    });

    testWidgets('never shows a too-short message on the password field', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      await tester.enterText(
        find.bySemanticsLabel(RegExp('Email', caseSensitive: false)).first,
        'user@example.com',
      );
      await tester.enterText(
        find.bySemanticsLabel(RegExp('Password', caseSensitive: false)).first,
        'a',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
      await tester.pumpAndSettle();

      expect(find.textContaining('at least', findRichText: true), findsNothing);
    });

    testWidgets('still requires a non-empty password', (tester) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      await tester.enterText(
        find.bySemanticsLabel(RegExp('Email', caseSensitive: false)).first,
        'user@example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
      await tester.pump();

      verifyNever(() => mockBloc.add(any()));
    });

    testWidgets('shows switch-to-register link when callback provided', (
      tester,
    ) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(LoginForm(onSwitchToRegister: () => tapped = true), mockBloc),
      );

      await tester.tap(find.text("Don't have an account? Register"));
      expect(tapped, isTrue);
    });

    testWidgets('does not show switch link when callback is null', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      expect(find.text("Don't have an account? Register"), findsNothing);
    });

    testWidgets('password field has obscured text by default', (tester) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      final textFields = tester.widgetList<EditableText>(
        find.descendant(
          of: find.byType(LoginForm),
          matching: find.byType(EditableText),
        ),
      );

      // Password field (second editable text) should be obscured
      final fields = textFields.toList();
      expect(fields.length, greaterThanOrEqualTo(2));
      expect(fields[1].obscureText, isTrue);
    });

    testWidgets('password visibility toggle shows/hides text', (tester) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      // Find the visibility toggle
      final toggle = find.byIcon(Icons.visibility);
      expect(toggle, findsOneWidget);

      await tester.tap(toggle);
      await tester.pump();

      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('email field has email autofill hint', (tester) async {
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      final emailField = tester
          .widgetList<TextField>(find.byType(TextField))
          .firstWhere(
            (f) => f.autofillHints?.contains(AutofillHints.email) ?? false,
            orElse: () => throw TestFailure('Email field not found'),
          );

      expect(emailField.autofillHints, contains(AutofillHints.email));
    });

    group('accessibility', () {
      testWidgets('all interactive elements have semantic labels', (
        tester,
      ) async {
        await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pump();

        // Verify the submit button has a useful semantic label
        expect(
          find.bySemanticsLabel(RegExp('Sign In', caseSensitive: false)),
          findsWidgets,
        );

        handle.dispose();
      });

      testWidgets('loading state semantic label is announced', (tester) async {
        when(() => mockBloc.state).thenReturn(const AuthLoading());
        await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

        final handle = tester.ensureSemantics();

        expect(
          find.bySemanticsLabel(RegExp('please wait', caseSensitive: false)),
          findsWidgets,
        );

        handle.dispose();
      });
    });
  });

  // #583: a provider sign-in is open in the browser. This form's submission
  // isn't what is running, so it shows no progress and announces nothing,
  // and its fields stay as they are at rest. Its submit is disabled, with its
  // label: it is unavailable for a press that isn't its own, so it has no
  // focus to keep (STYLE_GUIDE §5).
  group('while a provider sign-in is open (#583)', () {
    const providerOpen = AuthLoading(providerId: 'authentik');
    final submit = find.widgetWithText(FilledButton, 'Sign In');

    testWidgets('the submit is disabled with its label, shows no busy copy, '
        'and announces nothing', (tester) async {
      final handle = tester.ensureSemantics();
      when(() => mockBloc.state).thenReturn(providerOpen);
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Signing in, please wait'), findsNothing);
      expect(find.semantics.byLabel('Signing in, please wait'), findsNothing);
      expect(_liveRegions, findsNothing);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(
        tester.getSemantics(submit),
        isSemantics(
          label: 'Sign In',
          isButton: true,
          isFocusable: false,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );

      await tester.tap(submit, warnIfMissed: false);
      await tester.pump();
      verifyNever(() => mockBloc.add(any()));
      handle.dispose();
    });

    testWidgets('the fields stay editable, and the done action starts '
        'nothing until the attempt ends', (tester) async {
      when(() => mockBloc.state).thenReturn(providerOpen);
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields, hasLength(2));
      for (final field in fields) {
        expect(field.readOnly, isFalse);
      }

      await tester.enterText(find.byType(TextField).at(0), 'user@example.com');
      await tester.enterText(find.byType(TextField).at(1), 'securepassword');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      verifyNever(() => mockBloc.add(any()));

      // The control: once the attempt is over, the same action submits.
      // `done` closed the field's input connection, so open it again.
      when(() => mockBloc.state).thenReturn(const AuthUnauthenticated());
      await tester.showKeyboard(find.byType(TextField).at(1));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      verify(() => mockBloc.add(any(that: isA<AuthSignInRequested>())))
          .called(1);
    });
  });

  group('while an email sign-in is in flight', () {
    testWidgets('the form is as before: busy submit, read-only fields', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      when(() => mockBloc.state).thenReturn(const AuthLoading());
      await tester.pumpWidget(_wrap(const LoginForm(), mockBloc));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Signing in, please wait'), findsOneWidget);
      // The control for the provider case's "announces nothing".
      expect(_liveRegions, findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.readOnly, isTrue);
      }
      handle.dispose();
    });
  });
}
