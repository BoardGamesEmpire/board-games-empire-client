import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

FormGroup _form() => FormGroup({
  'email': FormControl<String>(validators: [Validators.required]),
  'password': FormControl<String>(),
});

/// A `const` field, hoisted so that two `pumpWidget` calls hand the element the
/// **identical** widget instance. That makes `didUpdateWidget` unreachable, so
/// only the inherited dependency on the group can notice a swap (#186). A widget
/// held in a `State` field and reused across builds is the same situation;
/// `const` is just the tersest way to write it.
const BgeTextField _constField = BgeTextField(
  formControlName: 'email',
  label: 'Email',
);

Widget _host(FormGroup form, Widget child, {double scale = 1}) => MediaQuery(
  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
  child: MaterialApp(
    theme: BgeTheme.light(),
    home: Scaffold(
      body: ReactiveForm(formGroup: form, child: child),
    ),
  ),
);

/// Pumps a fresh group, then swaps in a second fresh group, returning both so a
/// test can assert against either side of the swap.
///
/// [child] is a **builder**, called once per pump, because that is what a real
/// form does — it constructs its fields inside its own `build`, so each pump
/// gets a fresh instance and `didUpdateWidget` carries the swap. Pass
/// `() => _constField` to hand both pumps the same instance instead, which
/// leaves the inherited group dependency as the only route by which the swap can
/// be noticed.
///
/// Disposal is registered here rather than at the end of each test body, so a
/// failing expectation cannot leak a group into the tests that follow.
Future<({FormGroup before, FormGroup after})> _pumpSwap(
  WidgetTester tester,
  Widget Function() child, {
  void Function(FormGroup after)? prepareAfter,
}) async {
  final before = _form();
  addTearDown(before.dispose);
  final after = _form();
  addTearDown(after.dispose);
  prepareAfter?.call(after);

  await tester.pumpWidget(_host(before, child()));
  await tester.pumpWidget(_host(after, child()));
  return (before: before, after: after);
}

/// Runs [body] with semantics enabled, disposing the handle even if [body]
/// throws.
///
/// `addTearDown(handle.dispose)` cannot be used for this: flutter_test runs its
/// end-of-test semantics-handle verification *before* teardown callbacks, so a
/// deferred dispose fails with "A SemanticsHandle was active at the end of the
/// test". A `finally` is what keeps cleanup off the happy path only.
Future<void> _withSemantics(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final handle = tester.ensureSemantics();
  try {
    await body();
  } finally {
    handle.dispose();
  }
}

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

    testWidgets('exposes its name once, not twice', (tester) async {
      // Regression: an enclosing `Semantics(label:, textField:)` on top of
      // `InputDecoration.labelText` produced two nested nodes carrying the
      // same label, which reads out as "Email, Email". It looked like
      // belt-and-braces accessibility and was a stutter.
      final handle = tester.ensureSemantics();
      final form = _form();
      await tester.pumpWidget(
        _host(form, const BgeTextField(formControlName: 'email', label: 'E')),
      );

      expect(
        find.bySemanticsLabel('E'),
        findsOneWidget,
        reason: 'exactly one semantics node should carry the field name',
      );

      handle.dispose();
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

  group('BgeTextField across a FormGroup swap', () {
    // #186. Replacing the enclosing group — the idiomatic reactive_forms way
    // to reset a form — used to strand this widget on the control of the group
    // it was swapped away from. Nothing in the subtree registered an inherited
    // dependency on the group, so the swap went unnoticed.
    //
    // `ReactiveTextField` does not rebind on its own, which is why these tests
    // assert on the field and not only on the announcer. Its
    // `didChangeDependencies` does re-resolve the control (reactive_forms
    // 18.2.2, `reactive_form_field.dart:167-177`); what is missing is the
    // notification, because `_resolveFormControl` looks the group up with
    // `listen: false` and so registers no inherited dependency.
    BgeTextField field() => BgeTextField(
      formControlName: 'email',
      label: 'Email',
      validationMessages: {
        ValidationMessage.required: (_) => 'Email is required',
      },
    );

    // Two pumps, not one: the first settles the swap, the second lets the
    // semantics tree pick up the announcement. One pump suffices without a
    // swap, and here it reports "nothing announced" for a passing widget.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    testWidgets('announces an error raised on the group it swapped to', (
      tester,
    ) async {
      await _withSemantics(tester, () async {
        final forms = await _pumpSwap(tester, field);

        forms.after.control('email').markAsTouched();
        await settle(tester);

        expect(find.bySemanticsLabel('Email is required'), findsOneWidget);
      });
    });

    testWidgets('stays silent about the group it swapped away from', (
      tester,
    ) async {
      // The failure that is worse than silence: announcing a validation error
      // for a form the user is no longer looking at.
      await _withSemantics(tester, () async {
        final forms = await _pumpSwap(tester, field);

        forms.before.control('email').markAsTouched();
        await settle(tester);

        expect(find.bySemanticsLabel('Email is required'), findsNothing);
      });
    });

    testWidgets('renders the error of the group it swapped to', (tester) async {
      final forms = await _pumpSwap(tester, field);

      forms.after.control('email').markAsTouched();
      await settle(tester);

      // The visible error text, distinct from the announcement above: the
      // original report assumed this half still worked, and it did not.
      expect(find.text('Email is required'), findsOneWidget);
    });

    testWidgets('sends edits to the group it swapped to', (tester) async {
      final forms = await _pumpSwap(tester, field);

      await tester.enterText(find.byType(TextField), 'new@example.com');
      await tester.pump();

      expect(forms.after.control('email').value, 'new@example.com');
      expect(
        forms.before.control('email').value,
        isNull,
        reason: 'the swapped-away group must not receive the user\'s input',
      );
    });

    testWidgets('rebinds even when the child widget instance is unchanged', (
      tester,
    ) async {
      // The swap arrives with no widget update at all: `_constField` is the same
      // instance both times, so `didUpdateWidget` never fires. Only the
      // inherited dependency on the group can see it, which is why that
      // dependency is registered despite firing on every keystroke — the cache
      // in `_BgeTextFieldState.build` is what pays for it (#186, D2).
      final forms = await _pumpSwap(tester, () => _constField);

      await tester.enterText(find.byType(TextField), 'const@example.com');
      await tester.pump();

      expect(forms.after.control('email').value, 'const@example.com');
      expect(forms.before.control('email').value, isNull);
    });

    testWidgets('returns focus to the autofocused field when it rebinds', (
      tester,
    ) async {
      // Rebinding inflates a fresh field state, so `autofocus` runs again. The
      // caret moves back and the soft keyboard re-opens — acceptable for a
      // deliberate reset, but a focus *movement* rather than a focus loss, so
      // it is pinned rather than left to be discovered on a device.
      final before = _form();
      addTearDown(before.dispose);
      final after = _form();
      addTearDown(after.dispose);

      Widget host(FormGroup form) => _host(
        form,
        Column(
          children: [
            BgeTextField(
              formControlName: 'email',
              label: 'Email',
              autofocus: true,
            ),
            // Not `const`: a const sibling would not rebind, would keep its
            // focus, and the scope would then skip the autofocus request —
            // which is the pinned case above, not the one under test.
            BgeTextField(formControlName: 'password', label: 'Password'),
          ],
        ),
      );

      await tester.pumpWidget(host(before));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField).last);
      await tester.pumpAndSettle();

      int focusedIndex() => tester
          .widgetList<TextField>(find.byType(TextField))
          .toList()
          .indexWhere((field) => field.focusNode?.hasFocus ?? false);

      expect(focusedIndex(), 1, reason: 'focus moved off the email field');

      await tester.pumpWidget(host(after));
      await tester.pumpAndSettle();

      expect(
        focusedIndex(),
        0,
        reason: 'the rebound field re-applies autofocus',
      );
    });

    testWidgets('displays the value the group it swapped to already holds', (
      tester,
    ) async {
      await _pumpSwap(
        tester,
        field,
        prepareAfter: (after) =>
            after.control('email').value = 'prefilled@example.com',
      );
      await settle(tester);

      expect(find.text('prefilled@example.com'), findsOneWidget);
    });
  });

  group('BgeTextField build caching', () {
    // The group dependency that makes swaps visible (#186, D2) fires on every
    // value change anywhere in the form, so `build` serves a cached subtree
    // unless the resolved control changed. These pin both halves: the cache
    // holds when nothing relevant moved, and it is dropped when it must be.

    testWidgets('a keystroke in one field does not rebuild its siblings', (
      tester,
    ) async {
      final form = FormGroup({
        'email': FormControl<String>(validators: [Validators.required]),
        'password': FormControl<String>(),
      });
      addTearDown(form.dispose);

      await tester.pumpWidget(
        _host(
          form,
          const Column(
            children: [
              BgeTextField(formControlName: 'email', label: 'Email'),
              BgeTextField(formControlName: 'password', label: 'Password'),
            ],
          ),
        ),
      );

      // Widget *instances*, not element identity: reusing the instance is what
      // makes Flutter skip the subtree, so this is the thing being asserted.
      final before = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      await tester.enterText(find.byType(TextField).first, 'a');
      await tester.pump();
      final after = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();

      expect(
        identical(before[1], after[1]),
        isTrue,
        reason:
            'the untouched sibling must be served from cache; without it every '
            'field in a form rebuilds on every keystroke in any of them',
      );
    });

    testWidgets('a changed configuration is not served from cache', (
      tester,
    ) async {
      // didUpdateWidget is one of the three invalidation points. Losing it
      // would strand the field on whatever it was first built with, which a
      // swap test cannot catch because a swap changes the control as well.
      final form = _form();
      addTearDown(form.dispose);

      await tester.pumpWidget(
        _host(
          form,
          const BgeTextField(formControlName: 'email', label: 'Email'),
        ),
      );
      expect(find.text('Email'), findsOneWidget);

      await tester.pumpWidget(
        _host(
          form,
          const BgeTextField(formControlName: 'email', label: 'Email address'),
        ),
      );

      expect(find.text('Email address'), findsOneWidget);
      expect(find.text('Email'), findsNothing);
    });
  });

  group('BgeTextField binding failures', () {
    // This pins the answer to "should a missing control be asserted or logged
    // so it fails loudly in development?" — it already does, from upstream,
    // with a more specific message than this widget could add. Resolution
    // failing is deliberately not softened into a silent no-op field (#186,
    // D3): a field bound to nothing the form holds would take the user's input
    // and drop it.
    //
    // The sibling case — a control removed from the group while its field is
    // mounted — behaves the same way and is deliberately *not* pinned here. It
    // was verified by hand (`FormControlNotFoundException` from
    // `ReactiveFormFieldState._resolveFormControl`, via `initState` on the
    // re-keyed field), but the teardown mid-build also trips a framework
    // assertion in `_FocusInheritedScope`, so a test around it asserts on
    // Flutter's error cascade rather than on this widget. Don't re-attempt it
    // without a way to isolate that.

    testWidgets('fails loudly with no enclosing ReactiveForm', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: const Scaffold(
            body: BgeTextField(formControlName: 'email', label: 'Email'),
          ),
        ),
      );

      expect(tester.takeException(), isA<FormControlParentNotFoundException>());
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
