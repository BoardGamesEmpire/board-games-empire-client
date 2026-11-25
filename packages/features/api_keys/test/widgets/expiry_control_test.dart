import 'package:api_keys/src/widgets/expiry_control.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';

import '../support/harness.dart';

/// Fixed, at local noon, so the date line reads the same on any day the
/// suite runs and in any time zone.
final DateTime _today = DateTime(2026, 11, 25, 12);

/// The range the server accepts, as the error copy names it.
const _invalid = 'Enter a whole number of days from 1 to 365.';

/// Any date line: "Expires" and a month, which the label "Expires in" isn't.
final Finder _anyDate = find.textContaining(RegExp('^Expires [A-Z][a-z]{2} '));

void main() {
  /// Every value the control reported, in order.
  late List<int?> reported;

  setUp(() => reported = []);

  /// The control under a parent that keeps what it reports, as a form does.
  Future<void> pump(
    WidgetTester tester, {
    int? days = 90,
    bool readOnly = false,
    String label = 'Expires in',
    String? keepLabel,
  }) => pumpOnPage(
    tester,
    _Host(
      days: days,
      readOnly: readOnly,
      label: label,
      keepLabel: keepLabel,
      now: () => _today,
      onReported: reported.add,
    ),
  );

  Finder chip(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip));

  bool selected(WidgetTester tester, String label) =>
      tester.widget<ChoiceChip>(chip(label)).selected;

  _HostState host(WidgetTester tester) =>
      tester.state<_HostState>(find.byType(_Host));

  String? fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller?.text;

  Future<void> typeDays(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  group('ExpiryControl', () {
    testWidgets('90 days starts selected on create and shows its date', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('Expires in'), findsOneWidget);
      expect(selected(tester, '90 days'), isTrue);
      expect(selected(tester, '30 days'), isFalse);
      expect(selected(tester, '180 days'), isFalse);
      expect(selected(tester, '365 days'), isFalse);
      expect(selected(tester, 'Custom'), isFalse);
      // 2026-11-25 plus 90 days.
      expect(find.text('Expires Feb 23, 2027'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('picking a preset reports it and moves the date', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(chip('30 days'));
      await tester.pumpAndSettle();

      expect(reported, [30]);
      expect(selected(tester, '30 days'), isTrue);
      expect(selected(tester, '90 days'), isFalse);
      expect(find.text('Expires Dec 25, 2026'), findsOneWidget);
    });

    testWidgets('nothing is selected on edit until a pick', (tester) async {
      await pump(tester, days: null, label: 'Set a new expiry');

      expect(find.text('Set a new expiry'), findsOneWidget);
      for (final label in ['30 days', '90 days', '180 days', '365 days']) {
        expect(selected(tester, label), isFalse, reason: label);
      }
      expect(selected(tester, 'Custom'), isFalse);
      expect(_anyDate, findsNothing);
      expect(reported, isEmpty);

      await tester.tap(chip('180 days'));
      await tester.pumpAndSettle();

      expect(reported, [180]);
      expect(selected(tester, '180 days'), isTrue);
    });

    testWidgets('no choice to keep the expiry unless one is named', (
      tester,
    ) async {
      await pump(tester);

      expect(find.byType(ChoiceChip), findsNWidgets(5));
      expect(find.text('Keep current'), findsNothing);
    });

    testWidgets('a keep choice is chosen on edit and takes a pick back', (
      tester,
    ) async {
      await pump(
        tester,
        days: null,
        label: 'Set a new expiry',
        keepLabel: 'Keep current',
      );

      expect(selected(tester, 'Keep current'), isTrue);
      expect(_anyDate, findsNothing);

      await tester.tap(chip('30 days'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'Keep current'), isFalse);
      expect(_anyDate, findsOneWidget);

      await tester.tap(chip('Keep current'));
      await tester.pumpAndSettle();

      expect(reported, [30, null]);
      expect(selected(tester, 'Keep current'), isTrue);
      expect(selected(tester, '30 days'), isFalse);
      expect(_anyDate, findsNothing);

      // Chosen already, it reports nothing more.
      await tester.tap(chip('Keep current'));
      await tester.pumpAndSettle();
      expect(reported, [30, null]);
    });

    testWidgets('keep after a custom number ends Custom and its field', (
      tester,
    ) async {
      await pump(
        tester,
        days: null,
        label: 'Set a new expiry',
        keepLabel: 'Keep current',
      );
      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();
      await typeDays(tester, '12');

      await tester.tap(chip('Keep current'));
      await tester.pumpAndSettle();

      expect(reported, [12, null]);
      expect(find.byType(TextField), findsNothing);
      expect(selected(tester, 'Custom'), isFalse);
      expect(host(tester).form.valid, isTrue);
    });

    testWidgets('keep after an invalid custom entry makes the form valid', (
      tester,
    ) async {
      await pump(
        tester,
        days: null,
        label: 'Set a new expiry',
        keepLabel: 'Keep current',
      );
      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();
      await typeDays(tester, '400');
      expect(host(tester).form.valid, isFalse);

      await tester.tap(chip('Keep current'));
      await tester.pumpAndSettle();

      expect(host(tester).form.valid, isTrue);
      expect(selected(tester, 'Keep current'), isTrue);
      expect(find.text(_invalid), findsNothing);
    });

    testWidgets('read-only, the keep choice ignores a pick', (tester) async {
      await pump(
        tester,
        days: 30,
        label: 'Set a new expiry',
        keepLabel: 'Keep current',
        readOnly: true,
      );

      await tester.tap(chip('Keep current'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(reported, isEmpty);
      expect(selected(tester, '30 days'), isTrue);
    });

    testWidgets('custom 12 reports 12', (tester) async {
      await pump(tester);

      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'Custom'), isTrue);
      expect(selected(tester, '90 days'), isFalse);

      await typeDays(tester, '12');

      expect(reported, [12]);
      expect(find.text(_invalid), findsNothing);
      expect(find.text('Expires Dec 7, 2026'), findsOneWidget);
    });

    testWidgets('custom from a preset starts at its days', (tester) async {
      await pump(tester, days: 180);

      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();

      expect(fieldText(tester), '180');
      // A valid choice and its date stay on screen.
      expect(find.text('Expires May 24, 2027'), findsOneWidget);
      expect(reported, isEmpty);
    });

    testWidgets('custom from nothing starts empty', (tester) async {
      await pump(tester, days: null);

      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();

      expect(fieldText(tester), isEmpty);
      expect(_anyDate, findsNothing);
      expect(reported, isEmpty);
      // An empty field holds no number, so the form is not valid.
      expect(host(tester).form.valid, isFalse);
    });

    testWidgets('a non-preset value shows Custom with the number', (
      tester,
    ) async {
      await pump(tester, days: 12);

      expect(selected(tester, 'Custom'), isTrue);
      expect(selected(tester, '30 days'), isFalse);
      expect(
        fieldText(tester),
        '12',
      );
      expect(find.text('Expires Dec 7, 2026'), findsOneWidget);
      expect(reported, isEmpty);
    });

    testWidgets('custom 400 is refused with the range', (tester) async {
      await pump(tester);
      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();

      await typeDays(tester, '400');

      expect(find.text(_invalid), findsOneWidget);
      expect(reported.last, isNull);
      expect(_anyDate, findsNothing);
    });

    testWidgets('custom 0 is refused', (tester) async {
      await pump(tester);
      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();

      await typeDays(tester, '0');

      expect(find.text(_invalid), findsOneWidget);
      expect(reported.last, isNull);
    });

    testWidgets('custom text that is not a whole number is refused', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();

      for (final text in ['1.5', '-3', 'abc', '3e2', '12 days']) {
        await typeDays(tester, text);
        expect(find.text(_invalid), findsOneWidget, reason: text);
        expect(reported.last, isNull, reason: text);
      }

      await typeDays(tester, '1');
      expect(reported.last, 1);
      await typeDays(tester, '365');
      expect(reported.last, 365);
      expect(find.text(_invalid), findsNothing);
    });

    testWidgets('clearing the custom field reports nothing chosen', (
      tester,
    ) async {
      await pump(tester, days: 12);

      await typeDays(tester, '');

      expect(reported.last, isNull);
      expect(selected(tester, 'Custom'), isTrue);
      expect(_anyDate, findsNothing);
    });

    testWidgets('a preset pick after custom drops what was typed', (
      tester,
    ) async {
      await pump(tester, days: 12);

      await tester.tap(chip('180 days'));
      await tester.pumpAndSettle();

      expect(reported, [180]);
      expect(selected(tester, '180 days'), isTrue);
      expect(selected(tester, 'Custom'), isFalse);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();
      // Not the 12 typed before: the preset's days.
      expect(fieldText(tester), '180');
    });

    testWidgets('a value set from outside shows, and null clears', (
      tester,
    ) async {
      await pump(tester, days: 12);
      final host = tester.state<_HostState>(find.byType(_Host))..setDays(30);
      await tester.pumpAndSettle();
      expect(selected(tester, '30 days'), isTrue);
      expect(selected(tester, 'Custom'), isFalse);

      host.setDays(45);
      await tester.pumpAndSettle();
      expect(selected(tester, 'Custom'), isTrue);
      expect(fieldText(tester), '45');

      host.setDays(null);
      await tester.pumpAndSettle();
      expect(selected(tester, 'Custom'), isFalse);
      expect(find.byType(TextField), findsNothing);
      expect(_anyDate, findsNothing);
      // What the parent set is not reported back to it.
      expect(reported, isEmpty);
    });

    testWidgets('the date line is a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);

      final node = tester.getSemantics(find.text('Expires Feb 23, 2027'));
      expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      expect(node.label, 'Expires Feb 23, 2027');
      handle.dispose();
    });

    testWidgets('the date line keeps its node while the text is the same', (
      tester,
    ) async {
      await pump(tester);
      final before = tester.getSemantics(find.text('Expires Feb 23, 2027')).id;

      // A parent rebuild that says the same thing.
      tester.state<_HostState>(find.byType(_Host)).setDays(90);
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('Expires Feb 23, 2027')).id,
        before,
      );
    });

    testWidgets('a chosen chip is announced as selected', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);

      expect(
        tester.getSemantics(chip('90 days')),
        isSemantics(isSelected: true, isButton: true, isFocusable: true),
      );
      expect(
        tester.getSemantics(chip('30 days')),
        isSemantics(
          hasSelectedState: true,
          isSelected: false,
          isButton: true,
          isFocusable: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('read-only keeps focus and ignores a pick', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, readOnly: true);

      // Read as read-only, not as disabled.
      expect(
        tester.getSemantics(chip('30 days')),
        isSemantics(
          isReadOnly: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          isButton: true,
        ),
      );
      final data = tester.getSemantics(chip('30 days')).getSemanticsData();
      expect(data.hasAction(SemanticsAction.focus), isTrue);

      // Enabled, so each chip is in the focus order.
      for (final label in ['30 days', '90 days', 'Custom']) {
        expect(
          tester.widget<ChoiceChip>(chip(label)).onSelected,
          isNotNull,
          reason: label,
        );
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus!;
      expect(
        focused.context!.findAncestorWidgetOfExactType<ChoiceChip>(),
        isNotNull,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      // The pointer is taken: nothing is hit.
      await tester.tap(chip('30 days'), warnIfMissed: false);
      await tester.tap(chip('Custom'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(reported, isEmpty);
      expect(selected(tester, '90 days'), isTrue);
      expect(selected(tester, '30 days'), isFalse);
      expect(selected(tester, 'Custom'), isFalse);
      expect(FocusManager.instance.primaryFocus, same(focused));
      handle.dispose();
    });

    testWidgets('read-only custom field stays focusable and takes no edit', (
      tester,
    ) async {
      await pump(tester, days: 12, readOnly: true);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue);
      expect(field.enabled, isTrue);
    });

    testWidgets(
      'an invalid custom entry makes the parent form invalid and '
      'rejectSubmit focuses it',
      (tester) async {
        await pump(tester);
        expect(host(tester).form.valid, isTrue);

        await tester.tap(chip('Custom'));
        await tester.pumpAndSettle();
        await typeDays(tester, '400');

        final form = host(tester).form;
        expect(form.valid, isFalse);
        expect(form.control(_HostState.customDays).invalid, isTrue);

        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        form.rejectSubmit();
        await tester.pumpAndSettle();

        final focus = FocusManager.instance.primaryFocus;
        expect(
          focus?.context?.findAncestorWidgetOfExactType<TextField>(),
          isNotNull,
        );
        expect(find.text(_invalid), findsOneWidget);
      },
    );

    testWidgets('a preset leaves the parent form valid even with bad custom '
        'text', (tester) async {
      await pump(tester);
      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();
      await typeDays(tester, '400');
      expect(host(tester).form.valid, isFalse);

      await tester.tap(chip('30 days'));
      await tester.pumpAndSettle();

      expect(host(tester).form.valid, isTrue);
      expect(reported.last, 30);

      // The text typed before is gone, not waiting to refuse a submit.
      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), '30');
      expect(host(tester).form.valid, isTrue);
    });

    testWidgets('no choice leaves the parent form valid', (tester) async {
      await pump(tester, days: null);

      expect(host(tester).form.valid, isTrue);
      expect(
        host(tester).form.control(_HostState.customDays).disabled,
        isTrue,
      );
    });

    testWidgets('a reset to null clears an invalid custom entry', (
      tester,
    ) async {
      await pump(tester, days: 12);
      await typeDays(tester, '400');
      // The last report was already null, so the parent's days is null both
      // before and after the reset.
      expect(reported.last, isNull);
      expect(host(tester).form.valid, isFalse);

      host(tester).reset();
      await tester.pumpAndSettle();

      expect(selected(tester, 'Custom'), isFalse);
      expect(find.byType(TextField), findsNothing);
      expect(find.text(_invalid), findsNothing);
      expect(_anyDate, findsNothing);
      expect(host(tester).form.valid, isTrue);

      // And Custom starts afresh.
      await tester.tap(chip('Custom'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), isEmpty);
    });

    testWidgets('the chips are read as one group named by the label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, label: 'Set a new expiry');

      // The label is said once, as the group's name.
      final group = tester.getSemantics(
        find.bySemanticsLabel('Set a new expiry'),
      );
      expect(group.label, 'Set a new expiry');
      final names = <String>[];
      void visit(SemanticsNode node) {
        names.add(node.label);
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(group);
      expect(
        names.where((name) => name.contains('30 days')),
        isNotEmpty,
        reason: names.join(' | '),
      );
      expect(names.where((name) => name.contains('Custom')), isNotEmpty);
      handle.dispose();
    });

    testWidgets('chip labels scale down at 2.0 in 320dp', (tester) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pump(tester, days: 12, label: 'Set a new expiry');
      // The custom field and its error, the tallest the control gets.
      await typeDays(tester, '400');

      expect(tester.takeException(), isNull);
      for (final label in [
        '30 days',
        '90 days',
        '180 days',
        '365 days',
        'Custom',
      ]) {
        final box = find.ancestor(
          of: find.text(label),
          matching: find.byType(FittedBox),
        );
        expect(box, findsOneWidget, reason: label);
        expect(tester.widget<FittedBox>(box).fit, BoxFit.scaleDown);
        // Every chip is inside the 320dp screen.
        final rect = tester.getRect(chip(label));
        expect(rect.left, greaterThanOrEqualTo(0), reason: label);
        expect(rect.right, lessThanOrEqualTo(320), reason: label);
      }
      // The text really is at 2.0: a chip is taller than at 1.0's 32dp.
      expect(tester.getSize(chip('30 days')).height, greaterThan(48));
      expect(find.text(_invalid), findsOneWidget);
    });
  });
}

/// A parent that holds what the control reports, as a form does, and the
/// form that owns the custom field's control.
class _Host extends StatefulWidget {
  const _Host({
    required this.days,
    required this.readOnly,
    required this.label,
    required this.keepLabel,
    required this.now,
    required this.onReported,
  });

  final int? days;
  final bool readOnly;
  final String label;
  final String? keepLabel;
  final DateTime Function() now;
  final ValueChanged<int?> onReported;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  static const String customDays = 'customDays';

  late int? _days;
  final FormGroup form = FormGroup({
    'name': FormControl<String>(),
    customDays: expiryCustomDaysControl(),
  });

  @override
  void initState() {
    super.initState();
    _days = widget.days;
  }

  @override
  void dispose() {
    form.dispose();
    super.dispose();
  }

  void setDays(int? days) => setState(() => _days = days);

  /// What a form does after a save: resets, and clears the choice.
  void reset() {
    form.reset();
    setState(() => _days = null);
  }

  @override
  Widget build(BuildContext context) => ReactiveForm(
    formGroup: form,
    child: ExpiryControl(
      days: _days,
      label: widget.label,
      keepLabel: widget.keepLabel,
      customDaysName: customDays,
      now: widget.now,
      readOnly: widget.readOnly,
      onChanged: (days) {
        widget.onReported(days);
        setState(() => _days = days);
      },
    ),
  );
}
