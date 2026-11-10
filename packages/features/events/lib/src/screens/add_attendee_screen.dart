import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/detail/event_attendee_addition.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

/// The Add people page (#510): finds someone with an account through the
/// shared user search, takes the role they'll have, and pops its route with
/// both as an [EventAttendeeAddition]. Back pops nothing.
///
/// The page sends nothing. The event's screen beneath it opened it with
/// [args], and sends the add once it is back on top, checked against the
/// event as it shows it then; its banner says how the add went. So Add is a
/// choice made, not a request in flight.
///
/// - One person at a time, as the server takes one per add. A tap on a
///   result picks that person in place of any other, and a new search drops
///   the pick, which may not be among its results.
/// - Someone the roster already holds ([AddAttendeeArgs.rosterUserIds])
///   isn't picked. A note under the search field says they're on the event,
///   announced and brought into view, since the tap was likely made further
///   down the results. The next pick or search takes it away.
/// - The roles are the ones the viewer may give, each with a line on what it
///   lets the person do, as the household change-role dialog has them.
///   Participant, the server's default, is chosen to start.
/// - Add waits for a pick, and for a connection: the event's screen sends it
///   straight to the server (#49).
///
/// The search's label and hint are the shared search's, from
/// `UserSearchLocalizations`, so the caller registers that delegate beside
/// this package's.
class AddAttendeeScreen extends StatefulWidget {
  const AddAttendeeScreen({required this.users, required this.args, super.key});

  /// Key on the search field.
  static const Key searchKey = Key('add_attendee.search');

  /// Key on the Add button.
  static const Key addKey = Key('add_attendee.add');

  /// Key on the note that someone picked is already on the event.
  static const Key alreadyOnKey = Key('add_attendee.already_on');

  /// Key on [role]'s option.
  static Key roleKey(EventRole role) => Key('add_attendee.role_${role.name}');

  /// Key on the search result for the user with [userId].
  static Key resultKey(String userId) => Key('add_attendee.result_$userId');

  /// The per-server user search the page finds people through.
  final UserRemoteDataSource users;

  /// The roles the viewer may give, and who the roster holds.
  final AddAttendeeArgs args;

  @override
  State<AddAttendeeScreen> createState() => _AddAttendeeScreenState();
}

/// The search field's control. Not part of anything sent: the query typed so
/// far, in a group only because `BgeTextField` binds to one.
const _searchControl = 'search';

class _AddAttendeeScreenState extends State<AddAttendeeScreen> {
  late final UserSearchBloc _search = UserSearchBloc(remote: widget.users);
  final FormGroup _form = FormGroup({_searchControl: FormControl<String>()});
  StreamSubscription<Object?>? _queries;

  /// The person picked, whom Add answers with.
  UserSummary? _picked;

  /// The person last tapped who is on the event already, whom the note
  /// names.
  UserSummary? _alreadyOn;

  /// The role the person will have.
  late EventRole _role = widget.args.roles.contains(EventRole.participant)
      ? EventRole.participant
      : widget.args.roles.first;

  @override
  void initState() {
    super.initState();
    _queries = _form.control(_searchControl).valueChanges.listen((query) {
      if (!mounted) return;
      // A new search drops the pick, which may not be among its results,
      // and the note about the last tap, which may not be either.
      if (_picked != null || _alreadyOn != null) {
        setState(() {
          _picked = null;
          _alreadyOn = null;
        });
      }
      _search.add(UserSearchQueryChanged(query as String? ?? ''));
    });
  }

  @override
  void dispose() {
    unawaited(_queries?.cancel());
    _form.dispose();
    unawaited(_search.close());
    super.dispose();
  }

  void _pick(UserSummary user) {
    final alreadyOn = widget.args.rosterUserIds.contains(user.id);
    setState(() {
      // The tap was for someone else, so whoever was picked before isn't
      // left picked for Add to send instead.
      _picked = alreadyOn ? null : user;
      _alreadyOn = alreadyOn ? user : null;
    });
  }

  void _add() {
    final picked = _picked;
    // A press that lands as the connection drops.
    if (picked == null || BgeConnectivityScope.offlineOf(context)) return;
    Navigator.of(context).pop(EventAttendeeAddition(user: picked, role: _role));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final searchL10n = UserSearchLocalizations.of(context);
    final theme = Theme.of(context);
    final alreadyOn = _alreadyOn;
    final offline = BgeConnectivityScope.offlineOf(context);

    return BlocProvider.value(
      value: _search,
      child: BgePage(
        title: Text(l10n.eventsAddAttendeeTitle),
        child: ReactiveForm(
          formGroup: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              BgeTextField(
                key: AddAttendeeScreen.searchKey,
                formControlName: _searchControl,
                label: searchL10n.userSearchLabel,
                helper: searchL10n.userSearchHint,
                // Names and usernames are not prose.
                autocorrect: false,
                enableSuggestions: false,
              ),
              if (alreadyOn != null) ...[
                const BgeGap.sm(),
                // An answer to the tap, which a long list of results can
                // have taken far below here: announced, and brought into
                // view.
                BgeInlineBanner(
                  key: AddAttendeeScreen.alreadyOnKey,
                  message: l10n.eventsAddAttendeeAlreadyOn(
                    personName(
                          displayName: alreadyOn.displayName,
                          username: alreadyOn.username,
                        ) ??
                        l10n.eventsAttendeeSomeoneStart,
                  ),
                ),
              ],
              const BgeGap.sm(),
              UserSearchResultList(
                isPicked: (user) => user.id == _picked?.id,
                onPick: _pick,
                resultKey: AddAttendeeScreen.resultKey,
              ),
              const BgeGap.lg(),
              Semantics(
                header: true,
                child: Text(
                  l10n.eventsAddAttendeeRole,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const BgeGap.xs(),
              RadioGroup<EventRole>(
                groupValue: _role,
                onChanged: (role) {
                  if (role != null) setState(() => _role = role);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final role in widget.args.roles)
                      if (eventRoleLabel(l10n, role) case final label?)
                        RadioListTile<EventRole>(
                          key: AddAttendeeScreen.roleKey(role),
                          value: role,
                          contentPadding: EdgeInsets.zero,
                          title: Text(label),
                          subtitle: switch (_roleDescription(l10n, role)) {
                            final description? => Text(description),
                            null => null,
                          },
                        ),
                  ],
                ),
              ),
              const BgeGap.lg(),
              BgeOnlineOnly(
                child: BgeSubmitButton(
                  key: AddAttendeeScreen.addKey,
                  label: l10n.eventsAddAttendeeAdd,
                  onPressed: _picked == null || offline ? null : _add,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What [role] lets the person added do, under its option.
///
/// `assignableEventRoles` never offers the host, nor a role this app does
/// not recognise, so neither has one.
String? _roleDescription(EventsLocalizations l10n, EventRole role) =>
    switch (role) {
      EventRole.participant => l10n.eventsRoleDescriptionParticipant,
      EventRole.guest => l10n.eventsRoleDescriptionGuest,
      EventRole.spectator => l10n.eventsRoleDescriptionSpectator,
      EventRole.coHost => l10n.eventsRoleDescriptionCoHost,
      EventRole.organizer => l10n.eventsRoleDescriptionOrganizer,
      EventRole.moderator => l10n.eventsRoleDescriptionModerator,
      EventRole.host || EventRole.unknown => null,
    };
