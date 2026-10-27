import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

import 'package:events/l10n/events_localizations.dart';

import 'event_create_controls.dart';
import 'event_create_parts.dart';

/// The create form's *Who's invited* (#499): the people the event invites,
/// found with the shared user search.
///
/// It edits the invitees of the ambient [ReactiveForm], built by
/// [buildEventCreateForm], and searches through the [UserSearchBloc] above
/// it.
///
/// - The search field is plain, not a form control: what is typed is a
///   search, not part of the event.
/// - A tap on a result picks that person, or takes them off if they are
///   picked already, and a picked person's row is checked. The people
///   picked show as chips in the order they were picked, each with a button
///   that takes them off.
/// - At [EventDraft.maxInvitees], the most one create takes, a tap picks no
///   one new, and the section says so. The results stay tappable, since a
///   tap still takes someone off.
///
/// [readOnly] locks it while a create is on its way, as the household forms
/// lock theirs: the search takes no typing, no result can be tapped and no
/// chip taken off. The control is not disabled, since enabling it again
/// would emit a value change.
class EventInviteesSection extends StatelessWidget {
  const EventInviteesSection({this.readOnly = false, super.key});

  static const Key searchKey = Key('event_create.invitee_search');
  static const Key countKey = Key('event_create.invitees_count');
  static const Key fullKey = Key('event_create.invitees_full');

  /// A picked person's chip.
  static Key inviteeKey(String userId) => Key('event_create.invitee_$userId');

  /// A person's row among the search's results.
  static Key resultKey(String userId) => Key('event_create.result_$userId');

  /// Whether a create is on its way: nothing here takes an edit.
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final form = ReactiveForm.of(context, listen: false);
    if (form is! FormGroup) throw FormControlParentNotFoundException(this);
    final invitees = form.control(
      EventCreateControls.invitees,
    ) as FormControl<List<UserSummary>>;
    final l10n = EventsLocalizations.of(context);
    final searchL10n = UserSearchLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        EventCreateHeading(l10n.eventCreateInviteesTitle),
        const BgeGap.sm(),
        // Rebuilt for each pick, as the result list below is. The search
        // field between them is not, so it keeps its text and focus.
        ReactiveValueListenableBuilder<List<UserSummary>>(
          formControl: invitees,
          builder: (context, control, _) => _Picked(
            invitees: invitees,
            picked: control.value ?? const <UserSummary>[],
            readOnly: readOnly,
          ),
        ),
        const BgeGap.md(),
        TextField(
          key: searchKey,
          readOnly: readOnly,
          // Names and usernames are not prose.
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: searchL10n.userSearchLabel,
            helperText: searchL10n.userSearchHint,
          ),
          onChanged: (query) =>
              context.read<UserSearchBloc>().add(UserSearchQueryChanged(query)),
        ),
        ReactiveValueListenableBuilder<List<UserSummary>>(
          formControl: invitees,
          builder: (context, control, _) {
            final picked = control.value ?? const <UserSummary>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Above the results, where a tap that picked no one was
                // made, and announced the moment the list fills.
                if (picked.length >= EventDraft.maxInvitees) ...[
                  const BgeGap.sm(),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      key: fullKey,
                      l10n.eventCreateInviteesFull(EventDraft.maxInvitees),
                      style: eventCreateQuiet(Theme.of(context)),
                    ),
                  ),
                ],
                const BgeGap.sm(),
                UserSearchResultList(
                  isPicked: (user) => picked.any((p) => p.id == user.id),
                  onPick: readOnly ? null : (user) => _toggle(invitees, user),
                  resultKey: resultKey,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// How many people are picked, and a chip for each, in the order they were
/// picked.
class _Picked extends StatelessWidget {
  const _Picked({
    required this.invitees,
    required this.picked,
    required this.readOnly,
  });

  final FormControl<List<UserSummary>> invitees;
  final List<UserSummary> picked;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // A pick is otherwise silent but for its row: the count says it.
        Semantics(
          liveRegion: true,
          child: Text(
            key: EventInviteesSection.countKey,
            l10n.eventCreateInviteesCount(picked.length),
            style: eventCreateQuiet(Theme.of(context)),
          ),
        ),
        if (picked.isNotEmpty) ...[
          const BgeGap.sm(),
          Wrap(
            spacing: tokens.spaceSm,
            runSpacing: tokens.spaceSm,
            children: [
              for (final user in picked)
                InputChip(
                  key: EventInviteesSection.inviteeKey(user.id),
                  // A chip keeps to one line: a long name ends in an
                  // ellipsis, and is whole in its row and its button's name.
                  label: Text(user.label, overflow: TextOverflow.ellipsis),
                  onDeleted: readOnly ? null : () => _drop(invitees, user),
                  deleteButtonTooltipMessage: l10n.eventCreateInviteeRemove(
                    user.label,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Picks [user], or takes them off when they are picked already. At the
/// most one create takes, a new pick adds no one.
void _toggle(FormControl<List<UserSummary>> invitees, UserSummary user) {
  final picked = invitees.value ?? const <UserSummary>[];
  if (picked.any((p) => p.id == user.id)) {
    _drop(invitees, user);
  } else if (picked.length < EventDraft.maxInvitees) {
    invitees.value = [...picked, user];
  }
}

/// Takes [user] off the people picked, leaving the rest in their order.
void _drop(FormControl<List<UserSummary>> invitees, UserSummary user) {
  invitees.value = [
    for (final p in invitees.value ?? const <UserSummary>[])
      if (p.id != user.id) p,
  ];
}
