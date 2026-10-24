import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

typedef _Submitted = ({
  String name,
  String? description,
  MemberInvitePolicy? memberInvitePolicy,
});

Household _household({
  String name = 'Den',
  String? description = 'Board games',
  MemberInvitePolicy? policy = MemberInvitePolicy.needsApproval,
}) => Household(
  id: 'hh_1',
  name: name,
  description: description,
  settings: policy == null
      ? null
      : HouseholdSettings(memberInvitePolicy: policy),
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

void main() {
  late List<_Submitted> submitted;

  setUp(() => submitted = []);

  Widget wrap(Widget child) => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  Widget form(Household initial, {bool submitting = false}) => wrap(
    EditHouseholdForm(
      initial: initial,
      submitting: submitting,
      onSubmit: ({required name, description, memberInvitePolicy}) =>
          submitted.add((
            name: name,
            description: description,
            memberInvitePolicy: memberInvitePolicy,
          )),
    ),
  );

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(EditHouseholdForm.submitButtonKey));
    await tester.tap(find.byKey(EditHouseholdForm.submitButtonKey));
    await tester.pump();
  }

  String fieldText(WidgetTester tester, Key key) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(EditableText),
        ),
      )
      .controller
      .text;

  RadioGroup<MemberInvitePolicy?> radioGroup(WidgetTester tester) =>
      tester.widget(find.byType(RadioGroup<MemberInvitePolicy?>));

  Future<void> tapOption(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.tap(find.byKey(key));
    await tester.pump();
  }

  group('EditHouseholdForm', () {
    testWidgets("starts from the household's values", (tester) async {
      await tester.pumpWidget(form(_household()));

      expect(fieldText(tester, EditHouseholdForm.nameFieldKey), 'Den');
      expect(
        fieldText(tester, EditHouseholdForm.descriptionFieldKey),
        'Board games',
      );
      expect(find.text('Household name'), findsOneWidget);
      expect(find.text('Description (optional)'), findsOneWidget);
      expect(find.text('Who can invite'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save changes'), findsOneWidget);
    });

    testWidgets('submitting unchanged hands back the values it opened '
        'with', (tester) async {
      await tester.pumpWidget(form(_household()));

      await submit(tester);

      expect(submitted, [
        (
          name: 'Den',
          description: 'Board games',
          memberInvitePolicy: MemberInvitePolicy.needsApproval,
        ),
      ]);
    });

    testWidgets('a whitespace-only name is refused inline', (tester) async {
      await tester.pumpWidget(form(_household()));

      await tester.enterText(find.byKey(EditHouseholdForm.nameFieldKey), '   ');
      await submit(tester);

      expect(find.text('Enter a name for your household.'), findsOneWidget);
      expect(submitted, isEmpty);
    });

    testWidgets('submits trimmed values and a null for a blank '
        'description', (tester) async {
      await tester.pumpWidget(form(_household()));

      await tester.enterText(
        find.byKey(EditHouseholdForm.nameFieldKey),
        '  Annex  ',
      );
      await tester.enterText(
        find.byKey(EditHouseholdForm.descriptionFieldKey),
        '   ',
      );
      await submit(tester);

      expect(submitted, [
        (
          name: 'Annex',
          description: null,
          memberInvitePolicy: MemberInvitePolicy.needsApproval,
        ),
      ]);
    });

    testWidgets('no policy is preselected when the cache has none', (
      tester,
    ) async {
      await tester.pumpWidget(form(_household(policy: null)));

      expect(radioGroup(tester).groupValue, isNull);
      expect(
        find.text(
          "This app doesn't know the current setting. Leave it as it is, or "
          'choose one to change it.',
        ),
        findsOneWidget,
      );

      await submit(tester);
      expect(submitted.single.memberInvitePolicy, isNull);
    });

    testWidgets('no policy is preselected when the cached one is '
        'unknown', (tester) async {
      await tester.pumpWidget(
        form(_household(policy: MemberInvitePolicy.unknown)),
      );

      expect(radioGroup(tester).groupValue, isNull);
      expect(
        find.textContaining("This app doesn't know the current setting."),
        findsOneWidget,
      );
    });

    testWidgets('leaving an unknown policy as it is can be chosen again '
        'after picking one', (tester) async {
      await tester.pumpWidget(form(_household(policy: null)));

      expect(find.byKey(EditHouseholdForm.policyUnchangedKey), findsOneWidget);
      expect(find.text('Leave it as it is'), findsOneWidget);

      await tapOption(
        tester,
        EditHouseholdForm.policyOptionKey(MemberInvitePolicy.direct),
      );
      expect(radioGroup(tester).groupValue, MemberInvitePolicy.direct);

      await tapOption(tester, EditHouseholdForm.policyUnchangedKey);
      expect(radioGroup(tester).groupValue, isNull);

      await submit(tester);
      expect(submitted.single.memberInvitePolicy, isNull);
    });

    testWidgets('a known policy offers no option to leave it as it is', (
      tester,
    ) async {
      await tester.pumpWidget(form(_household(policy: MemberInvitePolicy.off)));

      expect(find.byKey(EditHouseholdForm.policyUnchangedKey), findsNothing);
    });

    testWidgets('the cached policy is preselected', (tester) async {
      await tester.pumpWidget(form(_household(policy: MemberInvitePolicy.off)));

      expect(radioGroup(tester).groupValue, MemberInvitePolicy.off);
      expect(
        find.textContaining("This app doesn't know the current setting."),
        findsNothing,
      );
    });

    testWidgets('choosing a policy submits it', (tester) async {
      await tester.pumpWidget(form(_household()));

      await tester.ensureVisible(
        find.byKey(
          EditHouseholdForm.policyOptionKey(MemberInvitePolicy.direct),
        ),
      );
      await tester.tap(
        find.byKey(
          EditHouseholdForm.policyOptionKey(MemberInvitePolicy.direct),
        ),
      );
      await tester.pump();
      await submit(tester);

      expect(submitted.single.memberInvitePolicy, MemberInvitePolicy.direct);
    });

    testWidgets('each option says what it means', (tester) async {
      await tester.pumpWidget(form(_household()));

      expect(
        find.text(
          'Owners and admins can always invite, and guests never can. A '
          "stricter policy also reaches members' invites still waiting: one "
          'it would not allow can no longer be approved or accepted, unless '
          'an owner or admin already approved it.',
        ),
        findsOneWidget,
      );
      const options = {
        MemberInvitePolicy.direct: (
          'Members invite directly',
          "A member's invite goes straight to the person invited.",
        ),
        MemberInvitePolicy.needsApproval: (
          'Members invite with approval',
          "An owner or admin approves each member's invite before the "
              'person invited sees it.',
        ),
        MemberInvitePolicy.off: (
          'Only owners and admins invite',
          "Members can't invite.",
        ),
      };
      for (final MapEntry(key: policy, value: (title, detail))
          in options.entries) {
        final option = find.byKey(EditHouseholdForm.policyOptionKey(policy));
        expect(
          find.descendant(of: option, matching: find.text(title)),
          findsOneWidget,
          reason: '$policy title',
        );
        expect(
          find.descendant(of: option, matching: find.text(detail)),
          findsOneWidget,
          reason: '$policy detail',
        );
      }
      // Only the known policies are offered.
      expect(find.byType(RadioListTile<MemberInvitePolicy?>), findsNWidgets(3));
    });

    testWidgets('the fields and options are read-only while submitting', (
      tester,
    ) async {
      await tester.pumpWidget(form(_household(), submitting: true));

      final name = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(EditHouseholdForm.nameFieldKey),
          matching: find.byType(TextField),
        ),
      );
      expect(name.readOnly, isTrue);
      expect(find.text('Saving…'), findsOneWidget);

      // Read-only, never disabled (STYLE_GUIDE, "In-flight forms"): the
      // option stays in the focus order and ignores the change.
      final off = find.byKey(
        EditHouseholdForm.policyOptionKey(MemberInvitePolicy.off),
      );
      expect(
        tester.widget<RadioListTile<MemberInvitePolicy?>>(off).enabled,
        isNot(isFalse),
      );
      await tester.ensureVisible(off);
      await tester.tap(off);
      await tester.pump();
      expect(radioGroup(tester).groupValue, MemberInvitePolicy.needsApproval);
    });
  });
}
