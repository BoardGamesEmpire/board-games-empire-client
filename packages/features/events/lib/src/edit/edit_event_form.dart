import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/edit_event_state.dart';
import 'package:events/src/create/event_basics_section.dart';
import 'package:events/src/create/event_create_controls.dart';
import 'package:events/src/create/event_create_parts.dart';
import 'package:events/src/create/event_rules_section.dart';
import 'package:events/src/edit/event_edit_controls.dart';
import 'package:events/src/screens/edit_event_screen.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The event edit form (#500): one scrolling page of the event's basics,
/// as the create form has them, then its rules, then Save.
///
/// It owns its [FormGroup], built by [buildEventEditForm] from [event] and
/// [policy], as the create form owns its own. A valid submit hands
/// [onSubmit] what the form holds ([editValuesOf]). An invalid one is
/// refused: every error shows, and the first takes the focus.
///
/// [event], [policy] and [editsRules] are read once, in `initState`. A
/// later read of the event never replaces what was typed.
///
/// ## The rules
///
/// - **Changed here** by a viewer who [editsRules], when the form can show
///   them ([rulesEditable]).
/// - **Read-only** for one who may edit the event but not its rules, with a
///   note saying who may. Not disabled, nor hidden (STYLE_GUIDE §4, §5). A
///   stored rule the form's own ranges refuse, such as a share the server
///   took below the form's 51%, is not checked: it can't be changed here,
///   so it must neither stop a save of the details nor show an error under
///   a field the viewer can't touch. Their submit sends no rules.
/// - **Not shown** when there are none on this device, or one is a setting
///   this app doesn't know: a heading and a line saying why, and no
///   controls. Nothing about them is sent.
///
/// ## While a save is on its way
///
/// [state] is what became of the last submit. While a save is on its way,
/// and once one is saved and the page is about to close, every section is
/// read-only, as on the create form: nothing takes an edit, but no control
/// is disabled, since enabling one again would emit a value change, and
/// every value change takes the outcome's banner down ([onEdited]).
///
/// Save is a direct write (#49): offline it is disabled, and says why.
class EditEventForm extends StatefulWidget {
  const EditEventForm({
    required this.event,
    required this.policy,
    required this.editsRules,
    required this.state,
    required this.onSubmit,
    required this.onEdited,
    super.key,
  });

  /// The event the form opens with. Read once.
  final Event event;

  /// The event's rules as this device holds them, or null for none. Read
  /// once.
  final EventPolicy? policy;

  /// Whether the viewer may change the rules (`EventAction.editRules`).
  /// Read once.
  final bool editsRules;

  /// What became of the last submit. A failure shows directly above Save.
  final EditEventState state;

  /// Takes what a valid form holds, with no rules where the viewer can't
  /// change them.
  final void Function(EventEditValues values) onSubmit;

  /// Called on every change to the form's values, so the caller can take
  /// down a failure, which is about the values as they were sent.
  final VoidCallback onEdited;

  @override
  State<EditEventForm> createState() => _EditEventFormState();
}

class _EditEventFormState extends State<EditEventForm> {
  late final FormGroup _form;

  /// Whether the form can show the rules: there are some, and this app
  /// knows each of their settings.
  late final bool _rulesShown;

  /// Whether the rules are shown and the viewer may change them.
  late final bool _mayChangeRules;

  StreamSubscription<Object?>? _editSubscription;

  /// Whether a save is on its way, or done with the page about to close.
  bool get _busy => switch (widget.state) {
    EditEventSaving() || EditEventSaved() => true,
    EditEventEditing() || EditEventFailed() => false,
  };

  @override
  void initState() {
    super.initState();
    _form = buildEventEditForm(widget.event, widget.policy);
    _rulesShown = rulesEditable(widget.policy);
    _mayChangeRules = _rulesShown && widget.editsRules;
    if (_rulesShown && !_mayChangeRules) _readOnlyRules(_form);
    // A failure is about the form as it was sent, so any change takes it
    // down. The bloc drops the event unless one is showing.
    _editSubscription = _form.valueChanges.listen((_) {
      if (mounted) widget.onEdited();
    });
  }

  @override
  void dispose() {
    unawaited(_editSubscription?.cancel());
    _form.dispose();
    super.dispose();
  }

  void _submit() {
    // Saving is a direct write (#49). Returning before the validity check
    // keeps an offline press from marking the form touched, which would
    // show errors the user has not caused.
    if (_busy || BgeConnectivityScope.offlineOf(context)) return;
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final values = editValuesOf(_form);
    widget.onSubmit(_mayChangeRules ? values : values.withoutRules());
  }

  /// The outcome of the last submit, while it shows.
  ///
  /// Titled (#211): each message gives only why, such as no connection, and
  /// never says what wasn't saved. The title says that: nothing, or, when
  /// the details were saved first, the rules alone. A save of an event that
  /// is gone shows nothing here, as the page leaves.
  BgeFormFailure? _failure(EventsLocalizations l10n) => switch (widget.state) {
    EditEventFailed(reason: EditEventFailure.gone) => null,
    final EditEventFailed failed => BgeFormFailure(
      key: EditEventScreen.failureKey,
      title: editEventFailureTitle(l10n, failed),
      message: _failureMessage(l10n, failed.reason),
    ),
    EditEventEditing() || EditEventSaving() || EditEventSaved() => null,
  };

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
          // An untouched type or reach keeps what the event has, so no
          // server default is hinted: one this app doesn't know shows
          // empty, and the default would misname it.
          EventBasicsSection(readOnly: busy, hintsDefaults: false),
          const BgeGap.xl(),
          if (!_rulesShown)
            _RulesNotShown(policy: widget.policy)
          else if (_mayChangeRules)
            EventRulesSection(readOnly: busy)
          else
            EventRulesSection(
              readOnly: true,
              note: widget.event.householdId == null
                  ? l10n.eventEditRulesHostOnly
                  : l10n.eventEditRulesHostOrHousehold,
            ),
          const BgeGap.lg(),
          BgeFormActions(
            failure: _failure(l10n),
            // Its reason shows under it only while offline.
            action: BgeOnlineOnly(
              child: BgeSubmitButton(
                key: EditEventScreen.saveKey,
                label: l10n.eventEditSave,
                progressLabel: l10n.eventEditSaving,
                submitting: busy,
                onPressed: BgeConnectivityScope.offlineOf(context)
                    ? null
                    : _submit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// *Rules* where the form can't show them: the section's heading, and a
/// line saying why, with nothing to change.
class _RulesNotShown extends StatelessWidget {
  const _RulesNotShown({required this.policy});

  /// The rules this device holds, or null for none.
  final EventPolicy? policy;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        EventCreateHeading(l10n.eventCreateRulesTitle),
        const BgeGap.sm(),
        Text(
          key: EditEventScreen.rulesNoteKey,
          policy == null
              ? l10n.eventEditRulesUnavailable
              : l10n.eventEditRulesUnknown,
          style: eventCreateQuiet(Theme.of(context)),
        ),
      ],
    );
  }
}

/// Takes the checks off [form]'s rules, for a viewer who may only read them
/// (#500).
///
/// Nothing they can't change may stop a save of the details, or show an
/// error under a field they can't touch. The stored numbers already pass
/// their ranges ([buildEventEditForm]), as the server takes a share the
/// form doesn't; with no checks at all, no rule they can only read is held
/// to any, and none is sent. Disabling the controls would do the same for
/// the form's validity, but draws them as disabled, which read-only
/// controls aren't (STYLE_GUIDE §4, §5).
///
/// Silently: nothing has been edited, so nothing is emitted.
void _readOnlyRules(FormGroup form) {
  for (final name in EventCreateControls.rules) {
    form.control(name)
      ..clearValidators()
      ..updateValueAndValidity(emitEvent: false);
  }
}

/// The heading of [failed]: that nothing was saved, or, when the details
/// were saved first, that the rules weren't. Where the server may hold
/// them all the same, it says they may not have been. The form's banner
/// shows it above Save, and the page says it alone of a save that failed
/// once the user had left (#464).
String editEventFailureTitle(
  EventsLocalizations l10n,
  EditEventFailed failed,
) => switch ((failed.detailsSaved, failed.unsettled)) {
  (true, true) => l10n.eventEditRulesUnsettledTitle,
  (true, false) => l10n.eventEditRulesNotSavedTitle,
  (false, true) => l10n.eventEditUnsettledTitle,
  (false, false) => l10n.eventEditFailedTitle,
};

/// What a failed save's banner says under its title: only why.
String _failureMessage(EventsLocalizations l10n, EditEventFailure reason) =>
    switch (reason) {
      EditEventFailure.offline => l10n.eventEditOffline,
      EditEventFailure.refused => l10n.eventEditRefused,
      EditEventFailure.invalid => l10n.eventEditInvalid,
      EditEventFailure.rulesInvalid => l10n.eventEditRulesInvalid,
      EditEventFailure.unexpected => l10n.eventEditError,
      // Never shown: a save of an event that is gone leaves the page.
      EditEventFailure.gone => l10n.eventEditError,
    };
