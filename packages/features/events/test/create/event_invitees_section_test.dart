import 'package:bge_test_support/widgets.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/create/event_create_controls.dart';
import 'package:events/src/create/event_invitees_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

import '../support/fake_user_remote.dart';

/// Pins the create form's *Who's invited* (#499): people found through the
/// shared user search are picked and taken off again, at most
/// [EventDraft.maxInvitees] of them, and the draft invites them in the order
/// they were picked.
void main() {
  const ana = UserSummary(id: 'u_1', username: 'ana', displayName: 'Ana B');
  const bo = UserSummary(id: 'u_2', username: 'bo');
  const cy = UserSummary(id: 'u_3', username: 'cy', displayName: 'Cy D');
  const full = "That's the most an event can invite at once (50).";

  late FakeUserRemote remote;
  late FormGroup form;

  setUp(() {
    remote = FakeUserRemote()
      ..onSearchUsers = (_) async => pageOf([ana, bo, cy]);
    form = buildEventCreateForm();
  });

  FormControl<List<UserSummary>> inviteesOf(FormGroup form) =>
      form.control(EventCreateControls.invitees)
          as FormControl<List<UserSummary>>;

  /// [count] people, none of them [ana], [bo] or [cy].
  List<UserSummary> others(int count) => [
    for (var n = 0; n < count; n++)
      UserSummary(id: 'other_$n', username: 'other$n'),
  ];

  Widget host({
    bool readOnly = false,
    TextScaler textScaler = TextScaler.noScaling,
  }) => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: [
      ...EventsLocalizations.localizationsDelegates,
      UserSearchLocalizations.delegate,
    ],
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: BgePage(
      // Made in the tree, inside the test's clock, as the screen makes it.
      // Kept through a pump of the same tree, so its results are too.
      child: BlocProvider(
        create: (_) => UserSearchBloc(remote: remote, debounce: Duration.zero),
        child: ReactiveForm(
          formGroup: form,
          child: EventInviteesSection(readOnly: readOnly),
        ),
      ),
    ),
  );

  /// Types [query] into the search, and waits for what it finds.
  Future<void> searchFor(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(EventInviteesSection.searchKey), query);
    await tester.pumpAndSettle();
  }

  /// Taps [user]'s row among the results.
  Future<void> tapResult(WidgetTester tester, UserSummary user) async {
    final row = find.byKey(EventInviteesSection.resultKey(user.id));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pump();
  }

  ListTile row(WidgetTester tester, UserSummary user) => tester
      .widget<ListTile>(find.byKey(EventInviteesSection.resultKey(user.id)));

  Finder chipOf(UserSummary user) =>
      find.byKey(EventInviteesSection.inviteeKey(user.id));

  testWidgets('picking a result adds them as a chip', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('No one yet'), findsOneWidget);
    expect(find.byType(InputChip), findsNothing);

    await searchFor(tester, 'an');
    expect(remote.calls, ['searchUsers(an)']);
    await tapResult(tester, ana);

    expect(inviteesOf(form).value, [ana]);
    expect(
      find.descendant(of: chipOf(ana), matching: find.text('Ana B')),
      findsOneWidget,
    );
    expect(find.text('1 person'), findsOneWidget);
    expect(row(tester, ana).selected, isTrue);
    expect(row(tester, bo).selected, isFalse);
  });

  testWidgets('picking them again takes them off', (tester) async {
    await tester.pumpWidget(host());
    await searchFor(tester, 'an');
    await tapResult(tester, ana);
    await tapResult(tester, bo);
    expect(find.text('2 people'), findsOneWidget);

    await tapResult(tester, ana);

    expect(inviteesOf(form).value, [bo]);
    expect(chipOf(ana), findsNothing);
    expect(chipOf(bo), findsOneWidget);
    expect(row(tester, ana).selected, isFalse);
    expect(find.text('1 person'), findsOneWidget);
  });

  testWidgets("a chip's delete takes them off", (tester) async {
    inviteesOf(form).value = [ana, bo];
    await tester.pumpWidget(host());

    await tester.tap(find.byTooltip('Remove Ana B'));
    await tester.pump();

    expect(inviteesOf(form).value, [bo]);
    expect(chipOf(ana), findsNothing);
    expect(chipOf(bo), findsOneWidget);
  });

  testWidgets('the 51st pick adds no one and says the list is full', (
    tester,
  ) async {
    final seeded = others(EventDraft.maxInvitees);
    inviteesOf(form).value = seeded;
    remote.onSearchUsers = (_) async => pageOf([ana, seeded.first]);
    await tester.pumpWidget(host());
    expect(find.text('50 people'), findsOneWidget);
    expect(find.text(full), findsOneWidget);

    await searchFor(tester, 'an');
    await tapResult(tester, ana);

    expect(inviteesOf(form).value, seeded);
    expect(chipOf(ana), findsNothing);
    expect(row(tester, ana).selected, isFalse);
    expect(find.text(full), findsOneWidget);

    // Taking someone off still works, and makes room for one more.
    await tapResult(tester, seeded.first);
    expect(inviteesOf(form).value, seeded.skip(1).toList());
    expect(find.text(full), findsNothing);
    await tapResult(tester, ana);
    expect(inviteesOf(form).value, [...seeded.skip(1), ana]);
    expect(find.text(full), findsOneWidget);
  });

  testWidgets('the draft sends the picked ids in pick order', (tester) async {
    await tester.pumpWidget(host());
    await searchFor(tester, 'an');

    await tapResult(tester, cy);
    await tapResult(tester, ana);
    await tapResult(tester, bo);

    expect(inviteeIdsOf(form), ['u_3', 'u_1', 'u_2']);
    // The chips are in the same order.
    final chips = tester.widgetList<InputChip>(find.byType(InputChip));
    expect(chips.map((chip) => chip.key), [
      EventInviteesSection.inviteeKey('u_3'),
      EventInviteesSection.inviteeKey('u_1'),
      EventInviteesSection.inviteeKey('u_2'),
    ]);
  });

  testWidgets('a read-only section changes nothing', (tester) async {
    inviteesOf(form).value = [ana];
    await tester.pumpWidget(host());
    await searchFor(tester, 'bo');

    // A create goes on its way with the results still showing. The chip's
    // delete button fades out.
    await tester.pumpWidget(host(readOnly: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EventInviteesSection.resultKey('u_2')));
    await tester.pump();

    expect(inviteesOf(form).value, [ana]);
    expect(row(tester, bo).onTap, isNull);
    expect(tester.widget<InputChip>(chipOf(ana)).onDeleted, isNull);
    expect(find.byTooltip('Remove Ana B'), findsNothing);
    final field = tester.widget<TextField>(
      find.byKey(EventInviteesSection.searchKey),
    );
    expect(field.readOnly, isTrue);
  });

  testWidgets('the section fits at 320dp wide at 2.0 text scale', (
    tester,
  ) async {
    useViewSize(tester, const Size(320, 568));
    const long = UserSummary(
      id: 'u_9',
      username: 'alexandria',
      displayName: 'Alexandria Montgomery-Featherstonehaugh',
    );
    // Full, so the note shows too.
    inviteesOf(form).value = [long, ...others(EventDraft.maxInvitees - 1)];
    remote.onSearchUsers = (_) async => pageOf([long, ana]);
    await tester.pumpWidget(
      host(textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor)),
    );
    await searchFor(tester, 'al');

    expect(tester.takeException(), isNull);
    expect(find.text(full), findsOneWidget);
    expect(find.byKey(EventInviteesSection.resultKey('u_9')), findsOneWidget);
  });
}
