import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';

const _switchKey = Key('switch');

Widget _host(FormGroup form, {bool readOnly = false, String? subtitle}) =>
    MaterialApp(
      home: Scaffold(
        body: ReactiveForm(
          formGroup: form,
          child: BgeSwitchField(
            formControlName: 'on',
            label: 'Let people reset',
            readOnly: readOnly,
            switchKey: _switchKey,
            subtitle: subtitle,
          ),
        ),
      ),
    );

FormGroup _form({bool value = false}) {
  final form = FormGroup({'on': FormControl<bool>(value: value)});
  addTearDown(form.dispose);
  return form;
}

void main() {
  group('BgeSwitchField', () {
    testWidgets('a tap toggles the bound control', (tester) async {
      final form = _form();
      await tester.pumpWidget(_host(form));

      await tester.tap(find.byKey(_switchKey));
      await tester.pumpAndSettle();

      expect(form.control('on').value, isTrue);
      expect(form.control('on').touched, isTrue);
    });

    testWidgets("shows the control's value", (tester) async {
      await tester.pumpWidget(_host(_form(value: true)));

      expect(
        tester.widget<SwitchListTile>(find.byKey(_switchKey)).value,
        isTrue,
      );
    });

    testWidgets('a tap changes nothing while read-only', (tester) async {
      final form = _form();
      await tester.pumpWidget(_host(form, readOnly: true));

      await tester.tap(find.byKey(_switchKey), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(form.control('on').value, isFalse);
    });

    testWidgets(
      'reads as focusable and read-only, with no tap, when read-only',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_host(_form(), readOnly: true));

        final node = tester.getSemantics(find.text('Let people reset'));

        expect(node.flagsCollection.isReadOnly, isTrue);
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.focus),
          isTrue,
        );
        expect(node.flagsCollection.isEnabled, isNot(Tristate.isFalse));
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
        handle.dispose();
      },
    );

    testWidgets('follows read-only as it flips, keeping value and focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final form = _form(value: true);
      await tester.pumpWidget(_host(form));
      Focus.of(tester.element(find.text('Let people reset'))).requestFocus();
      await tester.pump();

      SemanticsNode node() =>
          tester.getSemantics(find.text('Let people reset'));

      expect(node().flagsCollection.isReadOnly, isFalse);
      expect(
        node().getSemanticsData().flagsCollection.isFocused,
        Tristate.isTrue,
      );

      // A save starts.
      await tester.pumpWidget(_host(form, readOnly: true));

      expect(node().flagsCollection.isReadOnly, isTrue);
      expect(node().getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      expect(
        node().getSemanticsData().flagsCollection.isToggled,
        Tristate.isTrue,
      );
      expect(
        node().getSemanticsData().flagsCollection.isFocused,
        Tristate.isTrue,
      );
      await tester.tap(find.byKey(_switchKey), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(form.control('on').value, isTrue);

      // The save ends.
      await tester.pumpWidget(_host(form));

      expect(node().flagsCollection.isReadOnly, isFalse);
      expect(node().getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        node().getSemanticsData().flagsCollection.isFocused,
        Tristate.isTrue,
      );
      await tester.tap(find.byKey(_switchKey));
      await tester.pumpAndSettle();
      expect(form.control('on').value, isFalse);
      expect(
        node().getSemanticsData().flagsCollection.isToggled,
        Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('offers a tap when it is not read-only', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_form()));

      final node = tester.getSemantics(find.text('Let people reset'));

      expect(node.flagsCollection.isReadOnly, isFalse);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });

    testWidgets('renders the subtitle under the label', (tester) async {
      await tester.pumpWidget(_host(_form(), subtitle: 'Needs mail set up'));

      expect(find.text('Needs mail set up'), findsOneWidget);
    });

    testWidgets("reads the subtitle in the switch's one node", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_form(), subtitle: 'Needs mail set up'));

      final node = tester.getSemantics(find.text('Let people reset'));

      expect(tester.getSemantics(find.text('Needs mail set up')), same(node));
      expect(node.getSemanticsData().label, contains('Let people reset'));
      expect(node.getSemanticsData().label, contains('Needs mail set up'));
      expect(
        node.getSemanticsData().flagsCollection.isToggled,
        Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('has no subtitle by default', (tester) async {
      await tester.pumpWidget(_host(_form()));

      expect(
        tester.widget<SwitchListTile>(find.byKey(_switchKey)).subtitle,
        isNull,
      );
    });
  });
}
