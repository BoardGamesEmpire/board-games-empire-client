import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';

const _noteKey = Key('note');

Widget _host(FormGroup form) => MaterialApp(
  home: Scaffold(
    body: ReactiveForm(
      formGroup: form,
      child: Column(
        children: [
          BgeFieldNote<int>(
            formControlName: 'n',
            textKey: _noteKey,
            noteFor: (n) => n == null || n.isEven ? null : '$n is odd',
          ),
        ],
      ),
    ),
  ),
);

FormGroup _form(int? value) {
  final form = FormGroup({'n': FormControl<int>(value: value)});
  addTearDown(form.dispose);
  return form;
}

void main() {
  group('BgeFieldNote', () {
    testWidgets('shows the line for the value, in a live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_form(3)));

      expect(tester.widget<Text>(find.byKey(_noteKey)).data, '3 is odd');
      expect(
        tester.getSemantics(find.byKey(_noteKey)),
        isSemantics(label: '3 is odd', isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('draws nothing, gap included, without a line', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_form(2)));

      expect(find.byKey(_noteKey), findsNothing);
      expect(
        tester.getSize(find.byType(BgeFieldNote<int>)).height,
        0,
      );
    });

    testWidgets('follows the control', (tester) async {
      final form = _form(2);
      await tester.pumpWidget(_host(form));

      form.control('n').value = 5;
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(_noteKey)).data, '5 is odd');

      form.control('n').value = null;
      await tester.pumpAndSettle();
      expect(find.byKey(_noteKey), findsNothing);
    });
  });
}
