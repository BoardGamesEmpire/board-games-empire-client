import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:profile/l10n/profile_localizations.dart';
import 'package:profile/src/bloc/profile_state.dart';
import 'package:profile/src/form/profile_controls.dart';
import 'package:profile/src/form/profile_reach.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The caller's own profile, to edit (#547): about them, how they play,
/// practical details only they see, who can see the profile, and whether
/// search finds it, with Save at the end.
///
/// Owns its [FormGroup] and hands [onSave] the patch of what changed
/// against [initial], the profile as the server last sent it
/// ([profilePatchOf]). Save is disabled until something has changed. Every
/// edit calls [onEdited], so the caller can retire an outcome that
/// describes the values being replaced.
///
/// ## A new profile
///
/// Handed a new [initial] instance, as after a save the server answered,
/// the form takes its values in place: the fields refill, and taking them
/// is not an edit, so the saved notice stays. The same instance again, as
/// with a failure, keeps what was typed. So its parent must not key it on
/// the profile: a new key would build a new form, and take the focus and
/// the outcome banners with the old one.
///
/// ## Can't save now
///
/// While [saving], and while offline, every field is read-only, not
/// disabled, and Save is disabled. Offline, Save says why: saving is a
/// direct write (#49).
class ProfileForm extends StatefulWidget {
  const ProfileForm({
    required this.initial,
    required this.onSave,
    required this.saving,
    required this.saved,
    this.failure,
    this.onEdited,
    super.key,
  });

  /// Keys the field bound to [control], one of [ProfileControls].
  static Key fieldKey(String control) => ValueKey('profile_form.$control');

  static const Key saveKey = Key('profile_form.save');
  static const Key savedKey = Key('profile_form.saved');
  static const Key failureKey = Key('profile_form.failure');

  /// The line under the reach menu that says who the chosen rung is.
  static const Key reachDescriptionKey = Key('profile_form.reach_description');

  /// The profile as the server last sent it. A new instance refills the
  /// form.
  final UserProfile initial;

  final void Function(ProfilePatch patch) onSave;

  /// Whether a save is in flight.
  final bool saving;

  /// Whether the last save landed, until the next edit.
  final bool saved;

  /// Why the last save didn't land, until the next edit.
  final ProfileSaveFailure? failure;

  /// Called on every edit by the user.
  final VoidCallback? onEdited;

  @override
  State<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<ProfileForm> {
  /// Built over the current [ProfileForm.initial], so the display name's
  /// check follows a new profile.
  late final FormGroup _form = profileFormGroup(() => widget.initial);

  StreamSubscription<Map<String, Object?>?>? _edits;

  /// Whether the form holds anything [ProfileForm.initial] doesn't.
  bool _changed = false;

  /// The values just taken from a new profile, until the user's first edit.
  ///
  /// reactive_forms delivers the value changes of the reset that takes them
  /// after the reset, so they are told apart by their value: those are no
  /// edit, and a change to anything else is the user's.
  Map<String, Object?>? _taken;

  @override
  void initState() {
    super.initState();
    _edits = _form.valueChanges.listen(_onValueChanged);
  }

  void _onValueChanged(Map<String, Object?>? values) {
    if (!mounted) return;
    final changed = profileHasChanges(widget.initial, _form.value);
    if (changed != _changed) setState(() => _changed = changed);
    final taken = _taken;
    if (taken != null && mapEquals(values, taken)) return;
    _taken = null;
    widget.onEdited?.call();
  }

  @override
  void didUpdateWidget(ProfileForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.initial, widget.initial)) {
      final values = _taken = profileValuesOf(widget.initial);
      _form.reset(value: values);
      _changed = false;
    }
  }

  @override
  void dispose() {
    unawaited(_edits?.cancel());
    _form.dispose();
    super.dispose();
  }

  /// Whether Save sends now: something changed, nothing is in flight, and
  /// the app is online. Save's enablement and the submit share it.
  bool _maySave(BuildContext context) =>
      _changed && !widget.saving && !BgeConnectivityScope.offlineOf(context);

  void _submit() {
    if (!_maySave(context)) return;
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final patch = profilePatchOf(widget.initial, _form.value);
    if (!patch.isEmpty) widget.onSave(patch);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ProfileLocalizations.of(context);
    final readOnly = widget.saving || BgeConnectivityScope.offlineOf(context);
    final tooLong = <String, String Function(Object)>{
      ProfileErrors.tooLong: (max) => l10n.profileFieldTooLong(max as int),
    };

    /// [semanticsHint] is read with the field, as its hint, and not shown:
    /// a `Semantics` above the field merges into the field's own node.
    Widget text(
      String control,
      String label, {
      String? helper,
      String? semanticsHint,
      bool prose = false,
      int? minLines,
      Map<String, String Function(Object)> messages = const {},
    }) {
      final field = BgeTextField(
        key: ProfileForm.fieldKey(control),
        formControlName: control,
        label: label,
        helper: helper,
        readOnly: readOnly,
        // Prose wraps, and takes a new line from Enter.
        keyboardType: prose ? TextInputType.multiline : null,
        textInputAction: prose ? TextInputAction.newline : TextInputAction.next,
        minLines: minLines,
        maxLines: prose ? null : 1,
        validationMessages: {...tooLong, ...messages},
      );
      return semanticsHint == null
          ? field
          : Semantics(hint: semanticsHint, child: field);
    }

    BgeSwitchField toggle(String control, String label, {String? subtitle}) =>
        BgeSwitchField(
          key: ProfileForm.fieldKey(control),
          formControlName: control,
          label: label,
          subtitle: subtitle,
          readOnly: readOnly,
        );

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _GroupHeading(l10n.profileAboutHeading),
          const BgeGap.sm(),
          text(
            ProfileControls.displayName,
            l10n.profileDisplayNameLabel,
            messages: {
              ProfileErrors.blank: (_) => l10n.profileDisplayNameBlank,
            },
          ),
          const BgeGap.md(),
          text(ProfileControls.pronouns, l10n.profilePronounsLabel),
          const BgeGap.md(),
          text(ProfileControls.location, l10n.profileLocationLabel),
          const BgeGap.md(),
          text(
            ProfileControls.bio,
            l10n.profileBioLabel,
            helper: l10n.profileBioHelper,
            prose: true,
            minLines: 4,
          ),
          const BgeGap.xl(),
          _GroupHeading(l10n.profilePlayingHeading),
          const BgeGap.sm(),
          toggle(
            ProfileControls.willingToTeach,
            l10n.profileWillingToTeachLabel,
          ),
          toggle(
            ProfileControls.openToNewPlayers,
            l10n.profileOpenToNewPlayersLabel,
          ),
          toggle(ProfileControls.hostingCapability, l10n.profileHostingLabel),
          const BgeGap.md(),
          BgeTextField(
            key: ProfileForm.fieldKey(ProfileControls.preferredPlayerCount),
            formControlName: ProfileControls.preferredPlayerCount,
            label: l10n.profilePlayerCountLabel,
            readOnly: readOnly,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            validationMessages: {
              ProfileErrors.playerCount: (_) => l10n.profilePlayerCountInvalid(
                UserProfileRemoteDataSource.minPlayerCount,
                UserProfileRemoteDataSource.maxPlayerCount,
              ),
            },
          ),
          const BgeGap.md(),
          text(
            ProfileControls.houseRules,
            l10n.profileHouseRulesLabel,
            prose: true,
          ),
          const BgeGap.xl(),
          _GroupHeading(l10n.profilePracticalHeading),
          const BgeGap.sm(),
          // Shown once, and read with each field rather than on its own: Tab
          // passes a note by, and a field's helper is a node of its own that
          // focus on the field doesn't read, where a hint is the field's.
          ExcludeSemantics(child: Text(l10n.profilePracticalNote)),
          const BgeGap.md(),
          text(
            ProfileControls.dietaryRestrictions,
            l10n.profileDietaryLabel,
            semanticsHint: l10n.profilePracticalNote,
            prose: true,
          ),
          const BgeGap.md(),
          text(
            ProfileControls.accessibilityNeeds,
            l10n.profileAccessibilityLabel,
            semanticsHint: l10n.profilePracticalNote,
            prose: true,
          ),
          const BgeGap.xl(),
          _GroupHeading(l10n.profileReachHeading),
          const BgeGap.sm(),
          _ReachField(readOnly: readOnly),
          const BgeGap.xl(),
          _GroupHeading(l10n.profileSearchHeading),
          const BgeGap.sm(),
          toggle(
            ProfileControls.isSearchable,
            l10n.profileSearchableLabel,
            subtitle: l10n.profileSearchableHelper,
          ),
          const BgeGap.lg(),
          ..._actions(context, l10n),
        ],
      ),
    );
  }

  /// What the last save came to, above Save: the saved notice, or the
  /// failure through [BgeFormActions], titled because some of its messages
  /// state only a cause. Offline, Save says why, as its hint and in a line
  /// under it.
  ///
  /// Save disables as a save starts, and stays disabled once it lands, as
  /// nothing then differs. A disabled button gives up keyboard focus to the
  /// control focused before it, which for a user who tabbed to Save is the
  /// search switch, so focus stays in the form rather than dropping to the
  /// page; the form's test pins it.
  List<Widget> _actions(BuildContext context, ProfileLocalizations l10n) {
    final failure = widget.failure;
    return [
      if (widget.saved) ...[
        BgeInlineBanner(
          key: ProfileForm.savedKey,
          tone: BgeBannerTone.success,
          message: l10n.profileSaved,
        ),
        const BgeGap.md(),
      ],
      BgeFormActions(
        failure: failure == null
            ? null
            : BgeFormFailure(
                key: ProfileForm.failureKey,
                title: l10n.profileNotSavedTitle,
                message: _failureMessage(l10n, failure),
              ),
        action: BgeOnlineOnly(
          child: BgeSubmitButton(
            key: ProfileForm.saveKey,
            label: l10n.profileSave,
            progressLabel: l10n.profileSaving,
            submitting: widget.saving,
            onPressed: _maySave(context) ? _submit : null,
          ),
        ),
      ),
    ];
  }
}

String _failureMessage(
  ProfileLocalizations l10n,
  ProfileSaveFailure failure,
) => switch (failure) {
  ProfileSaveFailure.rejected => l10n.profileSaveRejected,
  ProfileSaveFailure.refused => l10n.profileSaveRefused,
  ProfileSaveFailure.failed => l10n.profileSaveFailed,
};

/// Who can see the profile: the ladder's rungs, and under the menu what the
/// chosen one means.
///
/// The menu's items carry a label only, so the chosen rung's description
/// sits under the field, as a [BgeFieldNote]. With no rung chosen,
/// as for a reach this app doesn't know, the menu shows its hint and there
/// is no line.
class _ReachField extends StatelessWidget {
  const _ReachField({required this.readOnly});

  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = ProfileLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BgeDropdownField<Reach>(
          key: ProfileForm.fieldKey(ProfileControls.reach),
          formControlName: ProfileControls.reach,
          label: l10n.profileReachLabel,
          hint: l10n.profileReachUnknown,
          readOnly: readOnly,
          items: [
            for (final reach in Reach.ladder)
              BgeDropdownItem(
                value: reach,
                label: profileReachCopy(l10n, reach)!.label,
              ),
          ],
        ),
        BgeFieldNote<Reach>(
          formControlName: ProfileControls.reach,
          textKey: ProfileForm.reachDescriptionKey,
          noteFor: (reach) =>
              reach == null ? null : profileReachCopy(l10n, reach)?.description,
        ),
      ],
    );
  }
}

/// A group's heading, read as a heading.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
