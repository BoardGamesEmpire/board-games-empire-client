import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:server_settings/src/widgets/settings_group_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The Invitations group of the server settings (#894): who can be invited
/// to a household and who can be added to an event.
///
/// A [SettingsGroupForm], which says how it takes new values from the server
/// and what a role that may not save sees. The patch [binding] gets is what
/// changed, against the settings the form last took: each policy only when it
/// changed, and not at all while it is one this app doesn't offer and no other
/// was picked.
///
/// Under each menu, what the chosen policy means, and that a user's own
/// preference can narrow it, never widen it.
class InvitationsSettingsForm extends StatelessWidget {
  const InvitationsSettingsForm({
    required this.binding,
    super.key,
  });

  static const Key householdFieldKey = Key(
    'invitations_settings_form.household',
  );
  static const Key eventFieldKey = Key('invitations_settings_form.event');
  static const Key householdDescriptionKey = Key(
    'invitations_settings_form.householdDescription',
  );
  static const Key eventDescriptionKey = Key(
    'invitations_settings_form.eventDescription',
  );
  static const Key saveKey = Key('invitations_settings_form.save');
  static const Key savedKey = Key('invitations_settings_form.saved');
  static const Key failureKey = Key('invitations_settings_form.failure');

  static const String _household = 'household';
  static const String _event = 'event';

  final SettingsGroupBinding binding;

  static FormGroup _buildForm(Map<String, Object?> values) => FormGroup({
    _household: FormControl<Reach>(value: values[_household] as Reach?),
    _event: FormControl<Reach>(value: values[_event] as Reach?),
  });

  /// A policy the menus don't offer shows as their hint, and a save leaves
  /// it alone unless another is picked.
  static Reach? _offered(Reach policy) =>
      SystemSettingsRemoteDataSource.inviteePolicies.contains(policy)
      ? policy
      : null;

  static Map<String, Object?> _valuesOf(SystemSettings settings) => {
    _household: _offered(settings.householdInviteePolicy),
    _event: _offered(settings.eventInviteePolicy),
  };

  static SystemSettingsPatch _patchOf(SystemSettings base, FormGroup form) {
    Reach? changed(String name, Reach stored) {
      final pick = form.control(name).value as Reach?;
      return pick == null || pick == stored ? null : pick;
    }

    return SystemSettingsPatch(
      householdInviteePolicy: changed(_household, base.householdInviteePolicy),
      eventInviteePolicy: changed(_event, base.eventInviteePolicy),
    );
  }

  static String _lastField(FormGroup _) => _event;

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);

    return SettingsGroupForm(
      binding: binding,
      buildForm: _buildForm,
      valuesOf: _valuesOf,
      patchOf: _patchOf,
      lastField: _lastField,
      labels: SettingsGroupLabels(
        saveKey: saveKey,
        saveLabel: l10n.invitationsSave,
        savingLabel: l10n.invitationsSaving,
        savedKey: savedKey,
        savedMessage: l10n.invitationsSaved,
        failureKey: failureKey,
        failureTitle: l10n.invitationsNotSavedTitle,
      ),
      fields: _fields,
    );
  }

  Widget _fields(
    BuildContext context, {
    required bool readOnly,
    required VoidCallback submit,
  }) {
    final l10n = ServerSettingsLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _policyField(
          l10n,
          fieldKey: householdFieldKey,
          descriptionKey: householdDescriptionKey,
          name: _household,
          label: l10n.invitationsHouseholdLabel,
          readOnly: readOnly,
          describe: (reach) => switch (reach) {
            Reach.public => l10n.invitationsHouseholdPublicDescription,
            Reach.friendsOfFriends =>
              l10n.invitationsHouseholdFriendsOfFriendsDescription,
            Reach.friends => l10n.invitationsHouseholdFriendsDescription,
            _ => null,
          },
        ),
        const BgeGap.md(),
        _policyField(
          l10n,
          fieldKey: eventFieldKey,
          descriptionKey: eventDescriptionKey,
          name: _event,
          label: l10n.invitationsEventLabel,
          readOnly: readOnly,
          describe: (reach) => switch (reach) {
            Reach.public => l10n.invitationsEventPublicDescription,
            Reach.friendsOfFriends =>
              l10n.invitationsEventFriendsOfFriendsDescription,
            Reach.friends => l10n.invitationsEventFriendsDescription,
            _ => null,
          },
        ),
      ],
    );
  }

  Widget _policyField(
    ServerSettingsLocalizations l10n, {
    required Key fieldKey,
    required Key descriptionKey,
    required String name,
    required String label,
    required bool readOnly,
    required String? Function(Reach? reach) describe,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BgeDropdownField<Reach>(
          key: fieldKey,
          formControlName: name,
          label: label,
          hint: l10n.invitationsReachNotOffered,
          readOnly: readOnly,
          items: [
            BgeDropdownItem(
              value: Reach.public,
              label: l10n.invitationsReachPublic,
            ),
            BgeDropdownItem(
              value: Reach.friendsOfFriends,
              label: l10n.invitationsReachFriendsOfFriends,
            ),
            BgeDropdownItem(
              value: Reach.friends,
              label: l10n.invitationsReachFriends,
            ),
          ],
        ),
        // Nothing to describe for a policy the menu doesn't offer: its hint
        // says so.
        BgeFieldNote<Reach>(
          formControlName: name,
          textKey: descriptionKey,
          noteFor: describe,
        ),
      ],
    );
  }
}
