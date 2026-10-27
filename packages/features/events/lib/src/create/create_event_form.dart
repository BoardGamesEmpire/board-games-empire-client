import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../bloc/create_event_state.dart';
import '../screens/create_event_screen.dart';
import '../widgets/event_labels.dart';
import 'event_create_controls.dart';
import 'event_create_dates_section.dart';
import 'event_create_parts.dart';
import 'event_invitees_section.dart';
import 'event_rules_section.dart';

/// The event create form (#499): one scrolling page of its basics, *When*,
/// *Who's invited* and *Advanced: rules*, then the submit.
///
/// It owns its [FormGroup], built by [buildEventCreateForm], as the
/// household forms own theirs. A valid submit hands [onSubmit] the draft the
/// form shows ([draftOf]). An invalid one is refused: every error shows,
/// and the first takes the focus.
///
/// The submit sits at the end of the page, not pinned below it: a submit
/// refused for too few dates reveals *Add a date* from below, and the
/// message under it shows only because the submit is lower still.
///
/// ## The household
///
/// The picker offers no household, then the households [households] last
/// listed. Until the first list arrives it offers nothing else, and takes no
/// pick. [householdId] is picked from the first list that offers it, so a
/// link opened before the households are read still lands in its household.
/// Until then it waits, and it is dropped once the user picks a household
/// or submits, so it never replaces a choice of theirs.
///
/// A later list can drop a household, as when the user's role in it, read
/// again, no longer may create events. A household picked that it drops is
/// unpicked. Otherwise the picker would show *No household* for it, while
/// the form went on sending it.
///
/// The picker is drawn anew whenever a list changes which households it
/// offers, a household added as much as one dropped, though not for a
/// rename or the same households again. Drawn anew, it closes a menu open
/// on it and loses the focus if it had it. An open menu keeps the
/// households it opened with, so after a drop a pick from it could set one
/// the list dropped. After an addition the menu closes all the same,
/// though nothing in it went stale.
///
/// ## While a create is on its way
///
/// [state] is what became of the last submit. While a create is on its way,
/// and once one succeeded and the form is about to close, every section is
/// read-only, as the household forms are: nothing takes an edit, but no
/// control is disabled, since enabling one again would emit a value change,
/// and every value change takes the outcome's banner down ([onEdited]).
class CreateEventForm extends StatefulWidget {
  const CreateEventForm({
    required this.state,
    required this.onSubmit,
    required this.onEdited,
    this.households,
    this.householdId,
    this.now,
    super.key,
  });

  /// What became of the last submit. A refusal or a failure shows directly
  /// above the submit.
  final CreateEventState state;

  /// Takes the draft of a valid form.
  final void Function(EventDraft draft) onSubmit;

  /// Called on every change to the form's values, so the caller can take
  /// down a refusal or a failure, which is about the values as they were
  /// sent.
  final VoidCallback onEdited;

  /// See [CreateEventScreen.households]. Read once.
  final Stream<List<Household>>? households;

  /// See [CreateEventScreen.householdId]. Read once.
  final String? householdId;

  /// See [CreateEventScreen.now].
  final DateTime Function()? now;

  @override
  State<CreateEventForm> createState() => _CreateEventFormState();
}

class _CreateEventFormState extends State<CreateEventForm> {
  final FormGroup _form = buildEventCreateForm();
  final BgeLogger _logger = BgeLogger('bge.events.create');

  StreamSubscription<List<Household>>? _householdsSubscription;
  StreamSubscription<Object?>? _editSubscription;
  StreamSubscription<String?>? _pickSubscription;

  /// [CreateEventForm.householdId], until a list offers it, or the user
  /// picks a household or submits first.
  late String? _prefill = widget.householdId;

  /// The households the picker offers, or null until the first list
  /// arrives.
  List<Household>? _offered;

  /// Counts each change to which households [_offered] holds. The picker is
  /// keyed on it, so it is drawn anew for each.
  int _offerVersion = 0;

  /// The draft last handed to [CreateEventForm.onSubmit]: the one a refusal
  /// is about.
  EventDraft? _sent;

  FormControl<String> get _household =>
      _form.control(EventCreateControls.household) as FormControl<String>;

  FormControl<List<UserSummary>> get _invitees =>
      _form.control(EventCreateControls.invitees)
          as FormControl<List<UserSummary>>;

  /// Whether a create is on its way, or done with the form about to close.
  bool get _busy => switch (widget.state) {
    CreateEventSubmitting() || CreateEventSuccess() => true,
    CreateEventInitial() ||
    CreateEventRefused() ||
    CreateEventFailure() => false,
  };

  @override
  void initState() {
    super.initState();
    _householdsSubscription = widget.households?.listen(
      _onHouseholds,
      // The picker keeps what it offers. Before a first list, the event
      // joins no household.
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Could not read the households an event can be created in',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    // A refusal or a failure is about the form as it was sent, so any
    // change takes it down. The bloc drops the event unless one is showing.
    _editSubscription = _form.valueChanges.listen((_) {
      if (mounted) widget.onEdited();
    });
    // Whoever set the household, the prefill has nothing left to do.
    _pickSubscription = _household.valueChanges.listen((_) => _prefill = null);
  }

  @override
  void dispose() {
    unawaited(_householdsSubscription?.cancel());
    unawaited(_editSubscription?.cancel());
    unawaited(_pickSubscription?.cancel());
    _form.dispose();
    super.dispose();
  }

  /// Offers [households], picking the prefill from the first list that
  /// offers it, and unpicking what a list no longer offers: see
  /// [CreateEventForm]'s "The household".
  void _onHouseholds(List<Household> households) {
    if (!mounted) return;
    final offered = {for (final household in households) household.id};
    final before = {
      for (final household in _offered ?? const <Household>[]) household.id,
    };
    final picked = _household.value;
    final prefill = _prefill;
    if (prefill != null && offered.contains(prefill)) {
      _prefill = null;
      _household.value = prefill;
    } else if (picked != null && !offered.contains(picked)) {
      // In the same turn as the list below, so the picker is never drawn
      // without the household the form would send.
      _household.value = null;
    }
    setState(() {
      if (!setEquals(offered, before)) _offerVersion++;
      _offered = households;
    });
  }

  void _submit() {
    if (_busy) return;
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final draft = draftOf(_form);
    // The user submitted the household they saw.
    _prefill = null;
    _sent = draft;
    widget.onSubmit(draft);
  }

  /// The outcome of the last submit, while it shows.
  ///
  /// Titled (#211), as the household invite send's is: some of its messages
  /// give only a cause, such as an invitee who can't be invited, and never
  /// say that the event wasn't created. One title for every refusal and the
  /// failure here, which is true of each of them. Under it, each message
  /// gives only why, since one that named the create as well would say it
  /// twice.
  BgeFormFailure? _failure(EventsLocalizations l10n) => switch (widget.state) {
    CreateEventRefused(:final inviteeId) => BgeFormFailure(
      key: CreateEventScreen.refusedKey,
      title: l10n.eventCreateFailedTitle,
      message: _refusal(l10n, inviteeId),
    ),
    CreateEventFailure() => BgeFormFailure(
      key: CreateEventScreen.errorKey,
      title: l10n.eventCreateFailedTitle,
      message: l10n.eventCreateError,
    ),
    CreateEventInitial() ||
    CreateEventSubmitting() ||
    CreateEventSuccess() => null,
  };

  /// What a refusal of the create [_sent] says: the invitee it names, when
  /// it names one, by the name the form shows them by; else who's invited,
  /// the likeliest cause, when the create invited anyone; else the
  /// household, when it was in one; else no cause, since it had neither.
  ///
  /// The invitees the form holds are the ones sent: the form takes no edit
  /// while a create is on its way, and an edit takes the refusal down.
  String _refusal(EventsLocalizations l10n, String? inviteeId) {
    final invitees = _invitees.value ?? const <UserSummary>[];
    final named = invitees.where((user) => user.id == inviteeId).firstOrNull;
    if (named != null) return l10n.eventCreateRefusedInvitee(named.label);

    final sent = _sent;
    if (sent == null || sent.inviteUserIds.isNotEmpty) {
      return l10n.eventCreateRefused;
    }
    return sent.householdId != null
        ? l10n.eventCreateRefusedHousehold
        : l10n.eventCreateRefusedOther;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final busy = _busy;

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Basics(
            offersHouseholds: widget.households != null,
            offered: _offered,
            offerVersion: _offerVersion,
            readOnly: busy,
          ),
          const BgeGap.xl(),
          EventCreateDatesSection(readOnly: busy, now: widget.now),
          const BgeGap.xl(),
          EventInviteesSection(readOnly: busy),
          const BgeGap.xl(),
          EventRulesSection(readOnly: busy),
          const BgeGap.lg(),
          BgeFormActions(
            failure: _failure(l10n),
            action: BgeSubmitButton(
              key: CreateEventScreen.submitKey,
              label: l10n.eventCreateSubmit,
              progressLabel: l10n.eventCreateSubmitting,
              submitting: busy,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }
}

/// Who can see an event, as the menu offers it: from the fewest people to
/// the most. The enum's own order is the backend's alphabetical one, which
/// says nothing about reach.
final List<Reach> _reaches = [
  for (final reach in Reach.values)
    if (_breadth(reach) != null) reach,
]..sort((a, b) => _breadth(a)!.compareTo(_breadth(b)!));

/// Where [reach] falls among those offered, from the fewest people to the
/// most, or null for `unknown`, which isn't offered. A switch, so a new
/// value doesn't compile until it has its place.
int? _breadth(Reach reach) => switch (reach) {
  Reach.private => 0,
  Reach.friends => 1,
  Reach.friendsOfFriends => 2,
  Reach.public => 3,
  Reach.unknown => null,
};

/// The form's basics: the event's title, its household, what kind it is
/// and who can see it, then its description, place and link.
///
/// The type and who can see it start untouched, and read as the server's
/// defaults, which is what an untouched one gets. `unknown` is never
/// offered: it has no label, and nothing to send. Each menu is an
/// [EventCreateMenu], as the rules' are.
class _Basics extends StatelessWidget {
  const _Basics({
    required this.offersHouseholds,
    required this.offered,
    required this.offerVersion,
    required this.readOnly,
  });

  /// Whether there is a household picker: false where there are no
  /// households to read.
  final bool offersHouseholds;

  /// What the household picker offers besides no household, or null until
  /// the first list arrives.
  final List<Household>? offered;

  /// Changes each time [offered] changes which households it holds.
  final int offerVersion;

  /// Whether a create is on its way: nothing here takes an edit.
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final offered = this.offered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        EventCreateHeading(l10n.eventCreateBasicsTitle),
        const BgeGap.sm(),
        BgeTextField(
          key: CreateEventScreen.titleKey,
          formControlName: EventCreateControls.title,
          label: l10n.eventCreateName,
          readOnly: readOnly,
          validationMessages: {
            ValidationMessage.required: (_) => l10n.eventCreateNameRequired,
          },
        ),
        if (offersHouseholds) ...[
          const BgeGap.md(),
          // Drawn anew when the households offered change, which closes a
          // menu open on the ones offered before.
          KeyedSubtree(
            key: ValueKey(offerVersion),
            child: EventCreateMenu<String?>(
              key: CreateEventScreen.householdKey,
              formControlName: EventCreateControls.household,
              label: l10n.eventCreateHousehold,
              items: [
                // Its value is null: the event joins no household.
                DropdownMenuItem(child: Text(l10n.eventCreateNoHousehold)),
                for (final household in offered ?? const <Household>[])
                  DropdownMenuItem(
                    value: household.id,
                    child: Text(household.name),
                  ),
              ],
              // Nothing to pick until the households answer.
              readOnly: readOnly || offered == null,
            ),
          ),
        ],
        const BgeGap.md(),
        EventCreateMenu<EventType>(
          key: CreateEventScreen.typeKey,
          formControlName: EventCreateControls.type,
          label: l10n.eventCreateType,
          hint: l10n.eventsTypeCasualGathering,
          items: eventCreateMenuItems(
            EventType.values,
            (type) => eventTypeLabel(l10n, type),
          ),
          readOnly: readOnly,
        ),
        const BgeGap.md(),
        EventCreateMenu<Reach>(
          key: CreateEventScreen.reachKey,
          formControlName: EventCreateControls.reach,
          label: l10n.eventCreateReach,
          hint: l10n.eventsReachFriends,
          items: eventCreateMenuItems(
            _reaches,
            (reach) => eventReachLabel(l10n, reach),
          ),
          readOnly: readOnly,
        ),
        const BgeGap.md(),
        BgeTextField(
          key: CreateEventScreen.descriptionKey,
          formControlName: EventCreateControls.description,
          label: l10n.eventCreateDescription,
          readOnly: readOnly,
          textInputAction: TextInputAction.newline,
          keyboardType: TextInputType.multiline,
          minLines: 2,
          maxLines: 5,
        ),
        const BgeGap.md(),
        BgeTextField(
          key: CreateEventScreen.locationKey,
          formControlName: EventCreateControls.location,
          label: l10n.eventCreateLocation,
          readOnly: readOnly,
        ),
        const BgeGap.md(),
        BgeTextField(
          key: CreateEventScreen.urlKey,
          formControlName: EventCreateControls.url,
          label: l10n.eventCreateUrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          readOnly: readOnly,
          validationMessages: {
            EventCreateErrors.fullLink: (_) => l10n.eventCreateUrlInvalid,
          },
        ),
      ],
    );
  }
}
