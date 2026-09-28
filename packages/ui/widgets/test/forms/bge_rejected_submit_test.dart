import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _nameKey = Key('name');
const _kindKey = Key('kind');
const _notesKey = Key('notes');

/// A three-control group in the order the fields render: an already-valid
/// text field, then a required dropdown, then a required text field.
FormGroup _form({String? name = 'filled'}) => FormGroup({
  'name': FormControl<String>(value: name, validators: [Validators.required]),
  'kind': FormControl<String>(validators: [Validators.required]),
  'notes': FormControl<String>(validators: [Validators.required]),
});

/// The form a page actually hosts: fields in a [BgePage], so the rejected
/// submit has the page's own scroll view to reveal within.
Widget _page(FormGroup form, {double spacerHeight = 0}) => BgePage(
  child: ReactiveForm(
    formGroup: form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const BgeTextField(
          key: _nameKey,
          formControlName: 'name',
          label: 'Name',
        ),
        const BgeGap.md(),
        ReactiveDropdownField<String>(
          key: _kindKey,
          formControlName: 'kind',
          decoration: const InputDecoration(labelText: 'Kind'),
          items: const [
            DropdownMenuItem(value: 'a', child: Text('A')),
            DropdownMenuItem(value: 'b', child: Text('B')),
          ],
          validationMessages: {ValidationMessage.required: (_) => 'Pick one'},
        ),
        const BgeGap.md(),
        BgeTextField(
          key: _notesKey,
          formControlName: 'notes',
          label: 'Notes',
          validationMessages: {ValidationMessage.required: (_) => 'Required'},
        ),
        // Stands in for the rest of a long form, so the page can be scrolled
        // until the fields above are out of view.
        SizedBox(height: spacerHeight),
      ],
    ),
  ),
);

bool _focused(WidgetTester tester, Key fieldKey) {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || focus.context == null) return false;
  final field = find.byKey(fieldKey).evaluate().single;
  var inside = false;
  focus.context!.visitAncestorElements((element) {
    if (element == field) inside = true;
    return !inside;
  });
  return inside;
}

void main() {
  group('FormGroup.rejectSubmit', () {
    testWidgets('moves focus to the first invalid control in declaration '
        'order, passing over a valid one', (tester) async {
      final form = _form();
      addTearDown(form.dispose);
      await tester.pumpWidget(hostAtSize(tester, _page(form)));

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(_focused(tester, _kindKey), isTrue);
      expect(_focused(tester, _nameKey), isFalse);
      expect(_focused(tester, _notesKey), isFalse);
    });

    testWidgets('picks the first invalid field in reading order, whatever '
        'order the controls are declared in', (tester) async {
      // Declared bottom to top. Register's controls were declared out of
      // their render order when this landed, which is why the order is taken
      // from the screen rather than from the group.
      final form = FormGroup({
        'notes': FormControl<String>(validators: [Validators.required]),
        'kind': FormControl<String>(validators: [Validators.required]),
        'name': FormControl<String>(validators: [Validators.required]),
      });
      addTearDown(form.dispose);
      await tester.pumpWidget(hostAtSize(tester, _page(form)));

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(_focused(tester, _nameKey), isTrue);
    });

    testWidgets('passes over an invalid control with no field, to the first '
        'one that has a field', (tester) async {
      final form = FormGroup({
        // Invalid, and rendered nowhere.
        'unbound': FormControl<String>(validators: [Validators.required]),
        'name': FormControl<String>(value: 'filled'),
        'kind': FormControl<String>(validators: [Validators.required]),
        'notes': FormControl<String>(validators: [Validators.required]),
      });
      addTearDown(form.dispose);
      await tester.pumpWidget(hostAtSize(tester, _page(form)));

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(_focused(tester, _kindKey), isTrue);
      expect(
        (form.control('unbound') as FormControl<String>).hasFocus,
        isFalse,
        reason:
            'focusing a control with no field marks it focused for good: '
            'reactive_forms never clears the flag, so a later focus() on it '
            'would do nothing',
      );
    });

    testWidgets('brings the field back on a second rejected submit that '
        'changes nothing else', (tester) async {
      // The second time, every control is already touched and the field
      // already has focus, so neither step asks for a frame. Without one the
      // reveal would wait for whatever frame came next.
      final form = _form();
      addTearDown(form.dispose);
      await tester.pumpWidget(
        hostAtSize(
          tester,
          _page(form, spacerHeight: 1200),
          size: const Size(320, 480),
          textScale: 2,
        ),
      );
      final position = pageScrollOf(tester).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      form.rejectSubmit();
      await tester.pumpAndSettle();
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(_focused(tester, _kindKey), isTrue, reason: 'sanity');
      expect(topInViewport(tester, find.byKey(_kindKey)), lessThan(0));

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(
        topInViewport(tester, find.byKey(_kindKey)),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
      );
    });

    testWidgets('brings a first invalid dropdown back into view, which '
        'focusing it alone does not', (tester) async {
      // Measured on compose before this existed: `control.focus()` on its
      // severity dropdown moved focus and left the page where it was, with
      // the field 157dp above the viewport. A text field scrolls itself into
      // view when focused; a dropdown does not.
      final form = _form();
      addTearDown(form.dispose);
      await tester.pumpWidget(
        hostAtSize(
          tester,
          _page(form, spacerHeight: 1200),
          size: const Size(320, 480),
          textScale: 2,
        ),
      );
      final position = pageScrollOf(tester).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        topInViewport(tester, find.byKey(_kindKey)),
        lessThan(0),
        reason: 'sanity: the dropdown starts above the viewport',
      );

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(
        topInViewport(tester, find.byKey(_kindKey)),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
        reason:
            'the whole field, label included, one spacing step below the '
            'viewport start — the same room a revealed banner is given',
      );
    });

    testWidgets('brings a first invalid text field into view whole, its '
        'floating label included', (tester) async {
      // A focused text field scrolls itself into view, but only as far as its
      // caret needs. Measured here at 200% text, focus alone left the field's
      // floating label 7dp above the viewport — the one line that says which
      // field is wrong.
      final form = _form(name: null);
      addTearDown(form.dispose);
      await tester.pumpWidget(
        hostAtSize(
          tester,
          _page(form, spacerHeight: 1200),
          size: const Size(320, 480),
          textScale: 2,
        ),
      );
      final position = pageScrollOf(tester).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(
        topInViewport(
          tester,
          find.descendant(
            of: find.byKey(_nameKey),
            matching: find.byType(InputDecorator),
          ),
        ),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
        reason:
            'the decorated field, one spacing step below the viewport start',
      );
      expect(
        topInViewport(tester, find.text('Name')),
        greaterThanOrEqualTo(0),
        reason: 'the floating label is on screen',
      );
    });

    testWidgets('does not move a page on which the field is already in view', (
      tester,
    ) async {
      final form = _form();
      addTearDown(form.dispose);
      await tester.pumpWidget(
        hostAtSize(
          tester,
          _page(form, spacerHeight: 1200),
          size: const Size(320, 480),
        ),
      );
      final position = pageScrollOf(tester).position;
      final before = topInViewport(tester, find.byKey(_kindKey));

      form.rejectSubmit();
      await tester.pumpAndSettle();

      expect(position.pixels, 0);
      expect(topInViewport(tester, find.byKey(_kindKey)), before);
    });

    testWidgets('jumps rather than animating under reduced motion', (
      tester,
    ) async {
      final form = _form();
      addTearDown(form.dispose);
      useViewSize(tester, const Size(320, 480));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 480),
            textScaler: TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: MaterialApp(
            theme: BgeTheme.light(),
            home: _page(form, spacerHeight: 1200),
          ),
        ),
      );
      final position = pageScrollOf(tester).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();

      form.rejectSubmit();
      // Two frames and no elapsed time: one runs the post-frame reveal, the
      // next lays out the jump. An animated reveal would not have moved yet.
      await tester.pump();
      await tester.pump();

      expect(
        topInViewport(tester, find.byKey(_kindKey)),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
      );
    });
  });
}
