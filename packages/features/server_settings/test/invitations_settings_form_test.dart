import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/src/widgets/invitations_settings_form.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:ui/ui.dart';

import 'support/fake_system_settings_remote.dart';
import 'support/harness.dart';

SystemSettings _settings({
  Reach household = Reach.public,
  Reach event = Reach.public,
}) => settingsFixture(
  householdInviteePolicy: household,
  eventInviteePolicy: event,
);

const _householdPublic =
    "Anyone can be invited. A user's own preference can narrow this, never "
    'widen it.';
const _householdFriendsOfFriends =
    "The inviter's friends and their friends, unless a block stands between "
    'them. Each is invited from their account, and invites by email address '
    'are refused. Whether an invite goes through shows the inviter whether '
    "that user shares a friend with them. A user's own preference can narrow "
    'this, never widen it.';
const _householdFriends =
    "Only the inviter's friends. Each is invited from their account, and "
    "invites by email address are refused. A user's own preference can narrow "
    'this, never widen it.';
const _eventPublic =
    'Anyone can be added, when the event is created or later. '
    "A user's own preference can narrow this, never widen it.";
const _eventFriendsOfFriends =
    "The inviter's friends and their friends, unless a block stands between "
    'them. Whether an addition goes through shows the inviter whether that '
    "user shares a friend with them. A user's own preference can narrow this, "
    'never widen it.';
const _eventFriends =
    "Only the inviter's friends. A user's own preference can narrow this, "
    'never widen it.';
const _notOfferedCopy = "A setting this app doesn't offer";

void main() {
  late List<SystemSettingsPatch> saves;
  late int edits;

  setUp(() {
    saves = [];
    edits = 0;
  });

  Future<void> pumpForm(
    WidgetTester tester, {
    SystemSettings? settings,
    int revision = 1,
    bool maySave = true,
    bool saving = false,
    bool settle = true,
  }) async {
    await pumpOnPage(
      tester,
      InvitationsSettingsForm(
        binding: SettingsGroupBinding(
          settings: settings ?? _settings(),
          revision: revision,
          maySave: maySave,
          saving: saving,
          otherGroupSaving: false,
          onSave: saves.add,
          onEdited: () => edits++,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Finder household() => find.byKey(InvitationsSettingsForm.householdFieldKey);
  Finder event() => find.byKey(InvitationsSettingsForm.eventFieldKey);

  Finder inField(Finder field, String text) =>
      find.descendant(of: field, matching: find.text(text));

  BgeDropdownField<Reach> field(WidgetTester tester, Finder finder) =>
      tester.widget<BgeDropdownField<Reach>>(finder);

  Future<void> pick(WidgetTester tester, Finder finder, String label) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    final key = find.byKey(InvitationsSettingsForm.saveKey);
    await tester.ensureVisible(key);
    await tester.pumpAndSettle();
    await tester.tap(key);
    await tester.pumpAndSettle();
  }

  bool focusIsIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    return find
        .ancestor(
          of: find.byElementPredicate((e) => identical(e, focused)),
          matching: finder,
        )
        .evaluate()
        .isNotEmpty;
  }

  testWidgets('shows each saved policy and what it means', (tester) async {
    await pumpForm(
      tester,
      settings: _settings(household: Reach.friendsOfFriends),
    );

    expect(find.text('Who can be invited to a household'), findsOneWidget);
    expect(find.text('Who can be added to an event'), findsOneWidget);
    expect(inField(household(), 'Friends of friends'), findsOneWidget);
    expect(inField(event(), 'Everyone'), findsOneWidget);
    expect(find.text(_householdFriendsOfFriends), findsOneWidget);
    expect(find.text(_eventPublic), findsOneWidget);
  });

  testWidgets('offers Everyone, Friends of friends and Friends, in order', (
    tester,
  ) async {
    await pumpForm(tester);

    expect(field(tester, household()).items.map((i) => i.value), [
      Reach.public,
      Reach.friendsOfFriends,
      Reach.friends,
    ]);
    expect(field(tester, event()).items.map((i) => i.label), [
      'Everyone',
      'Friends of friends',
      'Friends',
    ]);
  });

  testWidgets('friends of friends says it shows a shared friend', (
    tester,
  ) async {
    await pumpForm(
      tester,
      settings: _settings(
        household: Reach.friendsOfFriends,
        event: Reach.friendsOfFriends,
      ),
    );

    expect(find.text(_householdFriendsOfFriends), findsOneWidget);
    expect(find.text(_eventFriendsOfFriends), findsOneWidget);
    expect(
      find.textContaining('shares a friend with them'),
      findsNWidgets(2),
    );
  });

  testWidgets('household friends of friends and friends say email invites '
      'are refused', (tester) async {
    var revision = 0;
    for (final (policy, copy) in [
      (Reach.friendsOfFriends, _householdFriendsOfFriends),
      (Reach.friends, _householdFriends),
    ]) {
      await pumpForm(
        tester,
        settings: _settings(household: policy),
        revision: ++revision,
      );
      expect(find.text(copy), findsOneWidget);
      expect(
        find.textContaining('invites by email address are refused'),
        findsOneWidget,
      );
    }
  });

  testWidgets('no event description says anything about email', (
    tester,
  ) async {
    var revision = 0;
    for (final (policy, copy) in [
      (Reach.public, _eventPublic),
      (Reach.friendsOfFriends, _eventFriendsOfFriends),
      (Reach.friends, _eventFriends),
    ]) {
      await pumpForm(
        tester,
        settings: _settings(event: policy),
        revision: ++revision,
      );
      expect(find.text(copy), findsOneWidget, reason: '$policy');
      expect(find.textContaining('email'), findsNothing, reason: '$policy');
    }
  });

  testWidgets('every description says a user can narrow it', (tester) async {
    for (final copy in [
      _householdPublic,
      _householdFriendsOfFriends,
      _householdFriends,
      _eventPublic,
      _eventFriendsOfFriends,
      _eventFriends,
    ]) {
      expect(copy, contains('can narrow this, never widen it'));
    }
    final policies = {
      Reach.public: (_householdPublic, _eventPublic),
      Reach.friendsOfFriends: (
        _householdFriendsOfFriends,
        _eventFriendsOfFriends,
      ),
      Reach.friends: (_householdFriends, _eventFriends),
    };
    var revision = 0;
    for (final MapEntry(key: policy, value: (h, e)) in policies.entries) {
      await pumpForm(
        tester,
        settings: _settings(household: policy, event: policy),
        revision: ++revision,
      );
      expect(find.text(h), findsOneWidget);
      expect(find.text(e), findsOneWidget);
      expect(
        find.textContaining('can narrow this, never widen it'),
        findsNWidgets(2),
      );
    }
  });

  testWidgets('the description is a live region', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpForm(tester);

    await pick(tester, household(), 'Friends');

    expect(
      tester.getSemantics(
        find.byKey(InvitationsSettingsForm.householdDescriptionKey),
      ),
      isSemantics(isLiveRegion: true, label: _householdFriends),
    );
    handle.dispose();
  });

  testWidgets('a pick is saved alone', (tester) async {
    await pumpForm(tester);

    await pick(tester, household(), 'Friends');
    await save(tester);

    expect(saves, [
      const SystemSettingsPatch(householdInviteePolicy: Reach.friends),
    ]);
    expect(edits, greaterThan(0));
  });

  // One test each: the pick below is an unsaved edit, which a later
  // revision's settings would not replace.
  for (final policy in [Reach.private, Reach.extendedNetwork, Reach.unknown]) {
    testWidgets('a household policy of ${policy.name}, which the dropdown '
        'does not offer, shows as not offered and is not sent', (tester) async {
      await pumpForm(tester, settings: _settings(household: policy));

      expect(inField(household(), _notOfferedCopy), findsOneWidget);
      expect(find.text(_householdPublic), findsNothing);

      await pick(tester, event(), 'Friends');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(eventInviteePolicy: Reach.friends),
      ]);
    });
  }

  testWidgets('Save with nothing changed sends an empty patch', (
    tester,
  ) async {
    await pumpForm(tester);

    await save(tester);

    expect(saves, [const SystemSettingsPatch()]);
  });

  testWidgets('a role that may not save sees both read-only and no Save', (
    tester,
  ) async {
    await pumpForm(tester, maySave: false);

    expect(field(tester, household()).readOnly, isTrue);
    expect(field(tester, event()).readOnly, isTrue);
    expect(find.text(_householdPublic), findsOneWidget);
    expect(find.byKey(InvitationsSettingsForm.saveKey), findsNothing);
  });

  testWidgets('while saving, both go read-only and Save says so', (
    tester,
  ) async {
    await pumpForm(tester, saving: true, settle: false);

    expect(field(tester, household()).readOnly, isTrue);
    expect(field(tester, event()).readOnly, isTrue);
    expect(find.text('Saving…'), findsOneWidget);
  });

  testWidgets('Save with focus hands it to the event policy, the last field, '
      'when the role may no longer save', (tester) async {
    await pumpForm(tester);
    Focus.of(
      tester.element(find.text('Save invitation settings')),
      createDependency: false,
    ).requestFocus();
    await tester.pump();
    expect(focusIsIn(find.byKey(InvitationsSettingsForm.saveKey)), isTrue);

    await pumpForm(tester, maySave: false);

    expect(focusIsIn(event()), isTrue);
  });

  testWidgets("another group's save landing keeps an unsaved pick", (
    tester,
  ) async {
    await pumpForm(tester);
    await pick(tester, event(), 'Friends');

    await pumpForm(tester, revision: 2);

    expect(inField(event(), 'Friends'), findsOneWidget);
    expect(find.text(_eventFriends), findsOneWidget);
  });
}
