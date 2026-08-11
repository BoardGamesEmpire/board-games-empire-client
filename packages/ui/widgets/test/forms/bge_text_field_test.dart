import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

FormGroup _form() => FormGroup({
  'email': FormControl<String>(validators: [Validators.required]),
  'password': FormControl<String>(),
});

Widget _host(FormGroup form, Widget child, {double scale = 1}) => MediaQuery(
  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
  child: MaterialApp(
    theme: BgeTheme.light(),
    home: Scaffold(
      body: ReactiveForm(formGroup: form, child: child),
    ),
  ),
);

void main() {
  group('BgeTextField labelling', () {
    testWidgets('renders a visible label, not a hint-only field', (
      tester,
    ) async {
      final form = _form();
      await tester.pumpWidget(
        _host(
          form,
          const BgeTextField(
            formControlName: 'email',
            label: 'Email',
            hint: 'you@example.com',
          ),
        ),
      );

      // A hint vanishes as soon as the user types; a label does not.
      expect(find.text('Email'), findsOneWidget);
      form.dispose();
    });

    testWidgets('takes its border from the theme, so fields match across '
        'features', (tester) async {
      final form = _form();
      await tester.pumpWidget(
        _host(form, const BgeTextField(formControlName: 'email', label: 'E')),
      );

      // Asserting the widget's own decoration is empty would not work —
      // Flutter merges the theme defaults into it before it reaches TextField.
      // The guarantee that actually matters is user-visible: the border a
      // field renders is the THEME's, so every field in the app matches.
      // The regression this guards: household passed its own
      // OutlineInputBorder while server-onboarding did not, so the same
      // control looked like two different controls depending on the screen.
      final field = tester.widget<TextField>(find.byType(TextField));
      final themeBorder = Theme.of(
        tester.element(find.byType(TextField)),
      ).inputDecorationTheme.border;

      expect(themeBorder, isA<OutlineInputBorder>());
      expect(field.decoration!.border, themeBorder);
      form.dispose();
    });
  });

  group('BgeTextField error announcement', () {
    testWidgets('announces validation errors through a live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final form = _form();
      await tester.pumpWidget(
        _host(
          form,
          BgeTextField(
            formControlName: 'email',
            label: 'Email',
            validationMessages: {
              ValidationMessage.required: (_) => 'Email is required',
            },
          ),
        ),
      );

      // Untouched: nothing to announce yet.
      expect(find.bySemanticsLabel('Email is required'), findsNothing);

      form.control('email').markAsTouched();
      await tester.pump();

      // The node must survive semantics compilation despite having no visible
      // text — that is the whole reason it is a 1x1 box with an explicit
      // label rather than a zero-size one.
      expect(find.bySemanticsLabel('Email is required'), findsOneWidget);
      handle.dispose();
      form.dispose();
    });

    testWidgets('announces nothing while the control is valid', (tester) async {
      final handle = tester.ensureSemantics();
      final form = _form();
      await tester.pumpWidget(
        _host(
          form,
          BgeTextField(
            formControlName: 'email',
            label: 'Email',
            validationMessages: {
              ValidationMessage.required: (_) => 'Email is required',
            },
          ),
        ),
      );

      form.control('email').value = 'a@b.com';
      form.control('email').markAsTouched();
      await tester.pump();

      expect(find.bySemanticsLabel('Email is required'), findsNothing);
      handle.dispose();
      form.dispose();
    });
  });

  group('BgeTextField password toggle', () {
    testWidgets('meets the 48dp minimum touch target', (tester) async {
      final form = _form();
      await tester.pumpWidget(
        _host(
          form,
          const BgeTextField(
            formControlName: 'password',
            label: 'Password',
            isPassword: true,
            revealLabel: 'Show password',
            obscureLabel: 'Hide password',
          ),
        ),
      );

      final size = tester.getSize(find.byType(IconButton));
      expect(size.width, greaterThanOrEqualTo(BgeTokens.standard.minTapTarget));
      expect(
        size.height,
        greaterThanOrEqualTo(BgeTokens.standard.minTapTarget),
      );
      form.dispose();
    });

    testWidgets('toggles obscurity and swaps its localized label', (
      tester,
    ) async {
      final form = _form();
      await tester.pumpWidget(
        _host(
          form,
          const BgeTextField(
            formControlName: 'password',
            label: 'Password',
            isPassword: true,
            revealLabel: 'Show password',
            obscureLabel: 'Hide password',
          ),
        ),
      );

      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).tooltip,
        'Show password',
      );

      await tester.tap(find.byType(IconButton));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).tooltip,
        'Hide password',
      );
      form.dispose();
    });
  });

  group('BgeTextField read-only (in-flight) state', () {
    testWidgets('rejects edits while read-only', (tester) async {
      final form = _form();
      await tester.pumpWidget(
        _host(
          form,
          const BgeTextField(
            formControlName: 'email',
            label: 'Email',
            readOnly: true,
          ),
        ),
      );

      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      form.dispose();
    });
  });
}
