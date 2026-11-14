import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:profile/profile.dart';
import 'package:profile/src/form/profile_controls.dart';
import 'package:profile/src/form/profile_form.dart';
import 'package:ui/ui.dart';

import 'support/fake_user_profile_remote.dart';
import 'support/harness.dart';

final UserProfile _profile = profileFixture(
  bio: 'Board games and tea.',
  pronouns: 'she/her',
  location: 'Leeds',
  preferredPlayerCount: 4,
);

const _saveCopy = 'Save profile';
const _savedCopy = 'Profile saved.';
const _notSavedTitle = 'Profile not saved';
const _blankNameCopy = 'Enter a display name.';
const _practicalNote = 'Only you see these for now.';

/// The ladder as the menu offers it, fewest people first.
const _rungs = [
  ('Only me', "You and this server's staff"),
  ('Friends', "People you're friends with"),
  ('Friends of friends', 'Your friends and their friends'),
  ('Extended network', 'Friends up to three steps away'),
  ('Everyone', 'Everyone signed in to this server'),
];

Key _key(String control) => ProfileForm.fieldKey(control);

void main() {
  late List<ProfilePatch> saves;
  late int edits;

  setUp(() {
    saves = [];
    edits = 0;
  });

  /// [settle] false pumps one frame only, for a save in flight, whose
  /// spinner never lets the page settle.
  Future<void> pumpForm(
    WidgetTester tester, {
    UserProfile? initial,
    bool saving = false,
    bool saved = false,
    ProfileSaveFailure? failure,
    bool offline = false,
    bool settle = true,
  }) async {
    await pumpOnPage(
      tester,
      ProfileForm(
        initial: initial ?? _profile,
        onSave: saves.add,
        saving: saving,
        saved: saved,
        failure: failure,
        onEdited: () => edits++,
      ),
      offline: offline,
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Finder field(String control) => find.descendant(
    of: find.byKey(_key(control)),
    matching: find.byType(EditableText),
  );

  EditableText editable(WidgetTester tester, String control) =>
      tester.widget<EditableText>(field(control));

  String textOf(WidgetTester tester, String control) =>
      editable(tester, control).controller.text;

  Future<void> enter(WidgetTester tester, String control, String text) async {
    await tester.ensureVisible(find.byKey(_key(control)));
    await tester.enterText(field(control), text);
    await tester.pumpAndSettle();
  }

  Future<void> tapFinder(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) =>
      tapFinder(tester, find.byKey(ProfileForm.saveKey));

  FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.descendant(
      of: find.byKey(ProfileForm.saveKey),
      matching: find.byType(FilledButton),
    ),
  );

  BgeSwitchField switchField(WidgetTester tester, String control) =>
      tester.widget<BgeSwitchField>(find.byKey(_key(control)));

  BgeDropdownField<Reach> reachField(WidgetTester tester) =>
      tester.widget<BgeDropdownField<Reach>>(
        find.byKey(_key(ProfileControls.reach)),
      );

  Future<void> openReachMenu(WidgetTester tester) =>
      tapFinder(tester, find.byKey(_key(ProfileControls.reach)));

  Future<void> pickReach(WidgetTester tester, String label) async {
    await openReachMenu(tester);
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  const textFields = [
    ProfileControls.displayName,
    ProfileControls.pronouns,
    ProfileControls.location,
    ProfileControls.bio,
    ProfileControls.preferredPlayerCount,
    ProfileControls.houseRules,
    ProfileControls.dietaryRestrictions,
    ProfileControls.accessibilityNeeds,
  ];

  const switches = [
    ProfileControls.willingToTeach,
    ProfileControls.openToNewPlayers,
    ProfileControls.hostingCapability,
    ProfileControls.isSearchable,
  ];

  group('the groups', () {
    testWidgets('come in order, each under a heading', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester);

      const headings = [
        'About you',
        'Playing',
        'Practical details',
        'Who can see your profile',
        'Search',
      ];
      double? last;
      for (final heading in headings) {
        final finder = find.text(heading);
        expect(finder, findsOneWidget, reason: heading);
        expect(
          tester.getSemantics(finder).flagsCollection.isHeader,
          isTrue,
          reason: heading,
        );
        final top = tester.getTopLeft(finder).dy;
        if (last != null) expect(top, greaterThan(last), reason: heading);
        last = top;
      }
      handle.dispose();
    });

    testWidgets('show the profile as it is', (tester) async {
      await pumpForm(tester);

      expect(textOf(tester, ProfileControls.displayName), 'Ada');
      expect(textOf(tester, ProfileControls.pronouns), 'she/her');
      expect(textOf(tester, ProfileControls.location), 'Leeds');
      expect(textOf(tester, ProfileControls.bio), 'Board games and tea.');
      expect(textOf(tester, ProfileControls.preferredPlayerCount), '4');
      expect(textOf(tester, ProfileControls.houseRules), '');
      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.reach)),
          matching: find.text('Friends'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the bio says Markdown is supported', (tester) async {
      await pumpForm(tester);

      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.bio)),
          matching: find.text('Markdown supported'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('dietary and accessibility say only you see them, once on '
        'screen and with each field to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester);

      expect(find.text(_practicalNote), findsOneWidget);
      final heading = tester.getRect(find.text('Practical details'));
      final note = tester.getRect(find.text(_practicalNote));
      final dietary = tester.getRect(
        find.byKey(_key(ProfileControls.dietaryRestrictions)),
      );
      final accessibility = tester.getRect(
        find.byKey(_key(ProfileControls.accessibilityNeeds)),
      );
      expect(note.top, greaterThan(heading.bottom));
      expect(dietary.top, greaterThan(note.bottom));
      expect(accessibility.top, greaterThan(dietary.bottom));

      // Focus on either field reads it: the hint is on the field's own node,
      // which keeps its name. The note isn't read apart as well.
      for (final (control, label) in [
        (ProfileControls.dietaryRestrictions, 'Dietary restrictions'),
        (ProfileControls.accessibilityNeeds, 'Accessibility needs'),
      ]) {
        expect(
          tester.getSemantics(field(control)),
          isSemantics(
            isTextField: true,
            label: label,
            hint: _practicalNote,
          ),
          reason: control,
        );
      }
      expect(find.bySemanticsLabel(_practicalNote), findsNothing);
      handle.dispose();
    });

    testWidgets('the searchable switch says it controls finding, not '
        'opening', (tester) async {
      await pumpForm(tester);

      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.isSearchable)),
          matching: find.text('Let people find you in search'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.isSearchable)),
          matching: find.text(
            'This controls whether search shows your profile. Who can open '
            'it is set above.',
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('who can see it', () {
    testWidgets('the reach menu offers the five rungs in ladder order with '
        'their descriptions', (tester) async {
      await pumpForm(tester);

      await openReachMenu(tester);
      final items = find.byType(MenuItemButton);
      expect(items, findsNWidgets(_rungs.length));
      double? last;
      for (final (label, _) in _rungs) {
        final item = find.descendant(of: items, matching: find.text(label));
        expect(item, findsOneWidget, reason: label);
        final top = tester.getTopLeft(item).dy;
        if (last != null) expect(top, greaterThan(last), reason: label);
        last = top;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      for (final (label, description) in _rungs) {
        await pickReach(tester, label);

        expect(
          tester.widget<Text>(find.byKey(ProfileForm.reachDescriptionKey)).data,
          description,
          reason: label,
        );
      }
    });

    testWidgets('the chosen rung is saved', (tester) async {
      await pumpForm(tester);

      await pickReach(tester, 'Extended network');
      await save(tester);

      expect(saves, [const ProfilePatch(reach: Reach.extendedNetwork)]);
    });

    for (final reach in [Reach.unknown, null]) {
      testWidgets('a reach of $reach shows no choice and is never sent', (
        tester,
      ) async {
        await pumpForm(tester, initial: profileFixture(reach: reach));

        expect(
          find.descendant(
            of: find.byKey(_key(ProfileControls.reach)),
            matching: find.text("A choice this app doesn't know"),
          ),
          findsOneWidget,
        );
        expect(find.byKey(ProfileForm.reachDescriptionKey), findsNothing);
        expect(saveButton(tester).onPressed, isNull);

        await enter(tester, ProfileControls.location, 'York');
        await save(tester);

        expect(saves, [const ProfilePatch(location: SettingValue.set('York'))]);
      });
    }
  });

  group('saving', () {
    testWidgets('Save is disabled until something changes', (tester) async {
      await pumpForm(tester);
      expect(find.text(_saveCopy), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);

      await enter(tester, ProfileControls.pronouns, 'they/them');
      expect(saveButton(tester).onPressed, isNotNull);

      await enter(tester, ProfileControls.pronouns, ' she/her ');
      expect(saveButton(tester).onPressed, isNull);

      await tapFinder(
        tester,
        find.descendant(
          of: find.byKey(_key(ProfileControls.hostingCapability)),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(saveButton(tester).onPressed, isNotNull);
    });

    testWidgets('Save sends only what changed, trimmed', (tester) async {
      await pumpForm(tester);

      await enter(tester, ProfileControls.pronouns, '  they/them ');
      await enter(tester, ProfileControls.preferredPlayerCount, '');
      await save(tester);

      expect(saves, [
        const ProfilePatch(
          pronouns: SettingValue.set('they/them'),
          preferredPlayerCount: SettingValue.clear(),
        ),
      ]);
    });

    testWidgets('the bio keeps its leading spaces', (tester) async {
      await pumpForm(tester);
      const bio = '    indented code\n\nThen prose.';

      await enter(tester, ProfileControls.bio, bio);
      await save(tester);

      expect(saves, [const ProfilePatch(bio: SettingValue.set(bio))]);
    });

    testWidgets("an untouched blank display name doesn't block saving the "
        'bio', (tester) async {
      await pumpForm(tester, initial: profileFixture(displayName: null));

      await enter(tester, ProfileControls.bio, 'Hello');
      await save(tester);

      expect(saves, [const ProfilePatch(bio: SettingValue.set('Hello'))]);
      expect(find.text(_blankNameCopy), findsNothing);
    });

    testWidgets('a display name cleared is refused beside the field', (
      tester,
    ) async {
      await pumpForm(tester);

      await enter(tester, ProfileControls.displayName, '   ');
      await save(tester);

      expect(saves, isEmpty);
      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.displayName)),
          matching: find.text(_blankNameCopy),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a too-long field shows its error beside it', (tester) async {
      await pumpForm(tester);

      await enter(
        tester,
        ProfileControls.pronouns,
        'a' * (UserProfileRemoteDataSource.maxPronounsLength + 1),
      );
      await save(tester);

      expect(saves, isEmpty);
      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.pronouns)),
          matching: find.text('Use at most 40 characters.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("a bio of 2000 emoji is the server's 2000 characters: Save "
        'sends it whole', (tester) async {
      await pumpForm(tester);
      final bio = '\u{1F3B2}' * UserProfileRemoteDataSource.maxBioLength;

      await enter(tester, ProfileControls.bio, bio);
      expect(saveButton(tester).onPressed, isNotNull);
      await save(tester);

      expect(find.text('Use at most 2000 characters.'), findsNothing);
      expect(saves, [ProfilePatch(bio: SettingValue.set(bio))]);
    });

    testWidgets('a bio of 2001 emoji is refused beside the field, and '
        'nothing is sent', (tester) async {
      await pumpForm(tester);

      await enter(
        tester,
        ProfileControls.bio,
        '\u{1F3B2}' * (UserProfileRemoteDataSource.maxBioLength + 1),
      );
      await save(tester);

      expect(saves, isEmpty);
      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.bio)),
          matching: find.text('Use at most 2000 characters.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("a stored bio past its cap, left alone, doesn't block saving "
        'pronouns; edited and still past it, it is refused', (tester) async {
      final longBio =
          '\u{1F3B2}' * (UserProfileRemoteDataSource.maxBioLength + 1);
      await pumpForm(tester, initial: profileFixture(bio: longBio));

      await enter(tester, ProfileControls.pronouns, 'they/them');
      await save(tester);

      expect(saves, [
        const ProfilePatch(pronouns: SettingValue.set('they/them')),
      ]);
      expect(find.text('Use at most 2000 characters.'), findsNothing);

      await enter(tester, ProfileControls.bio, '$longBio!');
      await save(tester);

      expect(saves, hasLength(1));
      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.bio)),
          matching: find.text('Use at most 2000 characters.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a player count out of range is refused beside the field', (
      tester,
    ) async {
      await pumpForm(tester);

      await enter(tester, ProfileControls.preferredPlayerCount, '101');
      await save(tester);

      expect(saves, isEmpty);
      expect(
        find.descendant(
          of: find.byKey(_key(ProfileControls.preferredPlayerCount)),
          matching: find.text(
            'Enter a whole number from 1 to 100, or leave it empty.',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('offline, fields are read-only and Save disabled, not '
        'hidden', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester);
      await enter(tester, ProfileControls.location, 'York');

      await pumpForm(tester, offline: true);

      for (final control in textFields) {
        expect(editable(tester, control).readOnly, isTrue, reason: control);
      }
      for (final control in switches) {
        expect(switchField(tester, control).readOnly, isTrue, reason: control);
      }
      expect(reachField(tester).readOnly, isTrue);
      expect(textOf(tester, ProfileControls.location), 'York');
      expect(find.byKey(ProfileForm.saveKey), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);
      expect(find.text(onlineOnlyCopy), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(ProfileForm.saveKey)).hint,
        onlineOnlyCopy,
      );

      await save(tester);
      expect(saves, isEmpty);
      handle.dispose();
    });

    testWidgets('while saving, the fields go read-only and Save says so', (
      tester,
    ) async {
      await pumpForm(tester);
      await enter(tester, ProfileControls.location, 'York');

      await pumpForm(tester, saving: true, settle: false);

      for (final control in textFields) {
        expect(editable(tester, control).readOnly, isTrue, reason: control);
      }
      for (final control in switches) {
        expect(switchField(tester, control).readOnly, isTrue, reason: control);
      }
      expect(reachField(tester).readOnly, isTrue);
      expect(find.text('Saving…'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);
    });

    for (final (failure, copy) in [
      (
        ProfileSaveFailure.rejected,
        "One of these values wasn't accepted. Check them and try again.",
      ),
      (
        ProfileSaveFailure.refused,
        "This server doesn't let you change your profile.",
      ),
      (
        ProfileSaveFailure.failed,
        "Couldn't reach the server. Check your connection and try again.",
      ),
    ]) {
      testWidgets('a save that failed as ${failure.name} says so above Save', (
        tester,
      ) async {
        await pumpForm(tester, failure: failure);

        final banner = find.byKey(ProfileForm.failureKey);
        expect(
          find.descendant(of: banner, matching: find.text(_notSavedTitle)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: banner, matching: find.text(copy)),
          findsOneWidget,
        );
        expect(
          tester.getRect(banner).bottom,
          lessThan(tester.getRect(find.byKey(ProfileForm.saveKey)).top),
        );
      });
    }

    testWidgets('saved shows the success banner above Save', (tester) async {
      await pumpForm(tester, saved: true);

      expect(find.text(_savedCopy), findsOneWidget);
      expect(
        tester.getRect(find.byKey(ProfileForm.savedKey)).bottom,
        lessThan(tester.getRect(find.byKey(ProfileForm.saveKey)).top),
      );
      expect(find.byKey(ProfileForm.failureKey), findsNothing);
    });

    testWidgets('a failed save keeps the edits', (tester) async {
      await pumpForm(tester);
      await enter(tester, ProfileControls.location, 'York');
      await save(tester);

      await pumpForm(tester, saving: true, settle: false);
      await pumpForm(tester, failure: ProfileSaveFailure.failed);

      expect(textOf(tester, ProfileControls.location), 'York');
      expect(saveButton(tester).onPressed, isNotNull);
    });

    testWidgets('Save pressed from the keyboard leaves focus in the form, on '
        'the control before it, once the save lands', (tester) async {
      await pumpForm(tester);
      await enter(tester, ProfileControls.location, 'York');
      final searchable = find.descendant(
        of: find.byKey(_key(ProfileControls.isSearchable)),
        matching: find.byType(SwitchListTile),
      );
      await tester.ensureVisible(find.byKey(ProfileForm.saveKey));
      await tester.pumpAndSettle();
      tester.widget<SwitchListTile>(searchable).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        Focus.of(tester.element(find.text(_saveCopy))).hasPrimaryFocus,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(saves, hasLength(1));
      await pumpForm(tester, saving: true, settle: false);
      await pumpForm(
        tester,
        initial: profileFixture(
          bio: 'Board games and tea.',
          pronouns: 'she/her',
          location: 'York',
          preferredPlayerCount: 4,
        ),
        saved: true,
      );

      expect(saveButton(tester).onPressed, isNull);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find.ancestor(
          of: find.byElementPredicate((e) => identical(e, focused)),
          matching: find.byKey(_key(ProfileControls.isSearchable)),
        ),
        findsOneWidget,
      );
    });
  });

  group('edits and a new profile', () {
    testWidgets('every edit is reported', (tester) async {
      await pumpForm(tester);

      await enter(tester, ProfileControls.location, 'York');

      expect(edits, greaterThan(0));
    });

    testWidgets('a new profile refills the fields, leaves Save disabled, and '
        'is no edit', (tester) async {
      await pumpForm(tester);
      await enter(tester, ProfileControls.bio, '  Typed bio  ');
      await save(tester);
      await pumpForm(tester, saving: true, settle: false);
      final before = edits;

      // As the server answers: trimmed and sanitized, a new instance.
      await pumpForm(
        tester,
        initial: profileFixture(
          bio: 'Typed bio',
          pronouns: 'she/her',
          location: 'Leeds',
          preferredPlayerCount: 4,
        ),
        saved: true,
      );

      expect(textOf(tester, ProfileControls.bio), 'Typed bio');
      expect(saveButton(tester).onPressed, isNull);
      expect(edits, before);
      expect(find.text(_savedCopy), findsOneWidget);

      await enter(tester, ProfileControls.bio, 'Typed bio!');
      expect(edits, greaterThan(before));
    });

    testWidgets('the same profile again keeps what was typed', (tester) async {
      await pumpForm(tester);
      await enter(tester, ProfileControls.location, 'York');

      await pumpForm(tester, failure: ProfileSaveFailure.rejected);

      expect(textOf(tester, ProfileControls.location), 'York');
    });

    testWidgets('after a new profile, the display name rule reads it', (
      tester,
    ) async {
      await pumpForm(tester);

      await pumpForm(tester, initial: profileFixture(displayName: null));
      expect(textOf(tester, ProfileControls.displayName), '');
      await enter(tester, ProfileControls.bio, 'Hello');
      await save(tester);

      expect(saves, [const ProfilePatch(bio: SettingValue.set('Hello'))]);
    });
  });

  testWidgets('fits a 320dp window at 200% text, with the reach menu open', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 480)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpForm(tester, failure: ProfileSaveFailure.rejected);
    await pickReach(tester, 'Extended network');
    expect(tester.takeException(), isNull);

    await openReachMenu(tester);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(ProfileForm.saveKey));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final save = tester.getRect(find.byKey(ProfileForm.saveKey));
    expect(save.top, greaterThanOrEqualTo(0));
    expect(save.bottom, lessThanOrEqualTo(480));
  });
}
