import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/widgets/register_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

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
final SemanticsFinder _liveRegions = find.semantics.byPredicate(
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

  // #583: a provider sign-in is open in the browser. This form's submission
  // isn't what is running, so it shows no progress and announces nothing,
  // and its fields stay as they are at rest. Its submit is disabled, with its
  // label: it is unavailable for a press that isn't its own, so it has no
  // focus to keep (STYLE_GUIDE §5).
  group('while a provider sign-in is open (#583)', () {
    const providerOpen = AuthLoading(providerId: 'authentik');
    final submit = find.widgetWithText(FilledButton, 'Create Account');

    testWidgets('the submit is disabled with its label, shows no busy copy, '
        'and announces nothing', (tester) async {
      final handle = tester.ensureSemantics();
      when(() => mockBloc.state).thenReturn(providerOpen);
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Creating account, please wait'), findsNothing);
      expect(
        find.semantics.byLabel('Creating account, please wait'),
        findsNothing,
      );
      expect(_liveRegions, findsNothing);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(
        tester.getSemantics(submit),
        isSemantics(
          label: 'Create Account',
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
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields, hasLength(5));
      for (final field in fields) {
        expect(field.readOnly, isFalse);
      }

      await tester.enterText(find.byType(TextField).at(0), 'new@example.com');
      await tester.enterText(find.byType(TextField).at(1), 'newuser');
      await tester.enterText(find.byType(TextField).at(4), 'securepassword');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      verifyNever(() => mockBloc.add(any()));

      // The control: once the attempt is over, the same action submits.
      // `done` closed the field's input connection, so open it again.
      when(() => mockBloc.state).thenReturn(const AuthUnauthenticated());
      await tester.showKeyboard(find.byType(TextField).at(4));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      verify(() => mockBloc.add(any(that: isA<AuthRegisterRequested>())))
          .called(1);
    });

    testWidgets('the switch to sign-in is off until the attempt ends', (
      tester,
    ) async {
      var switched = 0;
      when(() => mockBloc.state).thenReturn(providerOpen);
      await tester.pumpWidget(
        _wrap(RegisterForm(onSwitchToSignIn: () => switched++), mockBloc),
      );
      final link = find.widgetWithText(
        TextButton,
        'Already have an account? Sign in',
      );

      expect(tester.widget<TextButton>(link).onPressed, isNull);
      await tester.tap(link, warnIfMissed: false);
      await tester.pump();
      expect(switched, 0);
    });
  });

  group('while an email sign-in is in flight', () {
    testWidgets('the form is as before: busy submit, read-only fields', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      when(() => mockBloc.state).thenReturn(const AuthLoading());
      await tester.pumpWidget(_wrap(const RegisterForm(), mockBloc));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Creating account, please wait'), findsOneWidget);
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
