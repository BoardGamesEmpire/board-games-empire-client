import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/widgets/register_form.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthBlocState>
    implements AuthBloc {}

Widget _wrap(Widget child, MockAuthBloc bloc) => MaterialApp(
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

  group('RegisterForm', () {
    testWidgets('renders all required fields', (tester) async {
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      expect(
        find.bySemanticsLabel(RegExp('Email', caseSensitive: false)),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(RegExp('Username', caseSensitive: false)),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(RegExp('Password', caseSensitive: false)),
        findsWidgets,
      );
    });

    testWidgets('renders optional name fields', (tester) async {
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      expect(
        find.bySemanticsLabel(RegExp('First Name', caseSensitive: false)),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(RegExp('Last Name', caseSensitive: false)),
        findsWidgets,
      );
    });

    testWidgets('shows Create Account button', (tester) async {
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      expect(
        find.widgetWithText(FilledButton, 'Create Account'),
        findsOneWidget,
      );
    });

    testWidgets('does not submit when required fields empty', (tester) async {
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      await tester.tap(find.widgetWithText(FilledButton, 'Create Account'));
      await tester.pump();

      verifyNever(() => mockBloc.add(any()));
    });

    testWidgets('adds AuthRegisterRequested with valid data', (tester) async {
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      final emailFields = find.byType(TextField);

      // Enter email, username, password (skip optional name fields)
      await tester.enterText(emailFields.at(0), 'new@example.com');
      await tester.enterText(emailFields.at(1), 'newuser');
      // Skip first/last name (indices 2 and 3 in the row)
      await tester.enterText(emailFields.at(4), 'securepassword');

      await tester.tap(find.widgetWithText(FilledButton, 'Create Account'));
      await tester.pump();

      verify(
        () => mockBloc.add(
          any(
            that: isA<AuthRegisterRequested>()
                .having((e) => e.email, 'email', 'new@example.com')
                .having((e) => e.username, 'username', 'newuser'),
          ),
        ),
      ).called(1);
    });

    testWidgets('shows loading indicator during AuthLoading', (tester) async {
      when(() => mockBloc.state).thenReturn(const AuthLoading());
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('disables submit button during loading', (tester) async {
      when(() => mockBloc.state).thenReturn(const AuthLoading());
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('shows sign-in link when callback provided', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(RegisterForm(onSwitchToSignIn: () => tapped = true), mockBloc),
      );

      await tester.tap(find.text('Already have an account? Sign in'));
      expect(tapped, isTrue);
    });

    testWidgets('password has newPassword autofill hint', (tester) async {
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      final passwordField = tester
          .widgetList<TextField>(find.byType(TextField))
          .firstWhere(
            (f) =>
                f.autofillHints?.contains(AutofillHints.newPassword) ?? false,
            orElse: () => throw TestFailure('Password field not found'),
          );

      expect(passwordField.autofillHints, contains(AutofillHints.newPassword));
    });
  });
}
