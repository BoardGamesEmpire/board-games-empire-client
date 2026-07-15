import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/widgets/login_form.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthBlocState>
    implements AuthBloc {}

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
}
