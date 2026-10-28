import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../widgets/event_labels.dart';
import '../widgets/event_when_field.dart';
import 'event_create_controls.dart';
import 'event_create_parts.dart';

/// The create form's *When* (#499): how the date is settled, and the dates.
///
/// It edits the mode and the dates of the ambient [ReactiveForm], built by
/// [buildEventCreateForm], which also holds the check they answer to.
///
/// - *One date* shows the first row. *Several days* and *Poll* show every
///   row, with *Add a date*, and a remove button on each while there is
///   more than one. Rows are kept through a switch of mode, so switching
///   back shows them again.
/// - Only *Several days* labels its rows ("Day 1"). A poll says what it is
///   under the mode picker instead.
/// - A start or an end is picked with the date picker, then the time
///   picker, and read back the way the event's own rows will say it
///   ([eventWhenLabel]). Cancelling either picker leaves the row as it was.
///   An end can be cleared, which no picker can do.
/// - The mode picker stacks its segments. Side by side, a third of the
///   form's width broke "Several days" mid-word at 320dp, and on every
///   phone width at 2.0 text (measured).
/// - Too few dates for the mode is shown under *Add a date*, which takes
///   the focus when a submit is refused for it.
///
/// [readOnly] locks it while a create is on its way, as the household forms
/// lock theirs: nothing here responds, but no control is disabled, since
/// enabling one again would emit a value change.
///
/// Named for the create form: the event's own page has an `EventDatesSection`
/// of its own.
class EventCreateDatesSection extends StatelessWidget {
  const EventCreateDatesSection({this.readOnly = false, this.now, super.key});

  static const Key modeKey = Key('event_create.mode');
  static const Key pollHintKey = Key('event_create.poll_hint');
  static const Key addDateKey = Key('event_create.add_date');
  static const Key tooFewKey = Key('event_create.dates_too_few');

  /// A shown row's label field, by its position among the dates.
  static Key labelKey(int index) => Key('event_create.label_$index');

  /// A shown row's start field.
  static Key startKey(int index) => Key('event_create.start_$index');

  /// A shown row's end field.
  static Key endKey(int index) => Key('event_create.end_$index');

  /// A shown row's clear button for its end, there while the end is set.
  static Key clearEndKey(int index) => Key('event_create.clear_end_$index');

  /// A shown row's remove button.
  static Key removeKey(int index) => Key('event_create.remove_$index');

  /// Whether a create is on its way: nothing here takes an edit.
  final bool readOnly;

  /// The clock the pickers open on and count their range from, and the
  /// year a date is read against. Defaults to the device's.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final form = ReactiveForm.of(context, listen: false);
    if (form is! FormGroup) throw FormControlParentNotFoundException(this);
    final mode = form.control(
      EventCreateControls.mode,
    ) as FormControl<EventSchedulingMode>;
    final dates = form.control(
      EventCreateControls.dates,
    ) as FormArray<Map<String, Object?>>;

    // Rebuilt for a switch of mode and for a row added or removed, not for
    // every value change in the form: each field follows its own control.
    return ReactiveValueListenableBuilder<EventSchedulingMode>(
      formControl: mode,
      builder: (context, _, _) => StreamBuilder<Object?>(
        stream: dates.collectionChanges,
        builder: (context, _) => _When(
          mode: mode,
          dates: dates,
          readOnly: readOnly,
          now: now ?? DateTime.now,
        ),
      ),
    );
  }
}

class _When extends StatelessWidget {
  const _When({
    required this.mode,
    required this.dates,
    required this.readOnly,
    required this.now,
  });

  final FormControl<EventSchedulingMode> mode;
  final FormArray<Map<String, Object?>> dates;
  final bool readOnly;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final current = mode.value ?? EventSchedulingMode.fixed;
    final several = showsEveryEventDate(current);
    final rows = dates.controls.cast<FormGroup>();
    // The modes offered, in order. `unknown` never is.
    final modes = {
      EventSchedulingMode.fixed: l10n.eventCreateModeFixed,
      EventSchedulingMode.multiDay: l10n.eventCreateModeMultiDay,
      EventSchedulingMode.poll: l10n.eventCreateModePoll,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        EventCreateHeading(l10n.eventCreateWhenTitle),
        const BgeGap.sm(),
        SegmentedButton<EventSchedulingMode>(
          key: EventCreateDatesSection.modeKey,
          direction: Axis.vertical,
          segments: [
            for (final MapEntry(key: value, value: label) in modes.entries)
              ButtonSegment(value: value, label: Text(label)),
          ],
          selected: {current},
          onSelectionChanged: readOnly
              ? null
              : (selected) => mode.value = selected.single,
        ),
        if (current == EventSchedulingMode.poll) ...[
          const BgeGap.sm(),
          Text(
            key: EventCreateDatesSection.pollHintKey,
            l10n.eventCreatePollHint,
            style: eventCreateQuiet(Theme.of(context)),
          ),
        ],
        for (final (index, row) in (several ? rows : rows.take(1)).indexed) ...[
          if (index == 0) const BgeGap.md() else const BgeGap.lg(),
          _DateRow(
            // By the row, so a row keeps its fields when one above it goes.
            key: ObjectKey(row),
            index: index,
            row: row,
            labelled: current == EventSchedulingMode.multiDay,
            onRemove: several && rows.length > 1
                ? () => dates.remove(row)
                : null,
            readOnly: readOnly,
            now: now,
          ),
        ],
        if (several) ...[
          const BgeGap.sm(),
          _AddDate(
            mode: mode,
            readOnly: readOnly,
            onAdd: () => dates.add(buildEventDateRow()),
          ),
        ],
      ],
    );
  }
}

/// One row of the dates: its label for several days, then when it starts
/// and when it ends.
class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.index,
    required this.row,
    required this.labelled,
    required this.onRemove,
    required this.readOnly,
    required this.now,
    super.key,
  });

  /// Its position among the dates, for its keys and its label's path.
  final int index;
  final FormGroup row;
  final bool labelled;

  /// Removes the row, or null where it is the only one shown.
  final VoidCallback? onRemove;
  final bool readOnly;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final start =
        row.control(EventCreateControls.start) as FormControl<DateTime>;
    final end = row.control(EventCreateControls.end) as FormControl<DateTime>;
    final remove = onRemove;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (labelled) ...[
          BgeTextField(
            key: EventCreateDatesSection.labelKey(index),
            formControlName: [
              EventCreateControls.dates,
              index,
              EventCreateControls.label,
            ].join('.'),
            label: l10n.eventCreateDayLabel,
            readOnly: readOnly,
          ),
          const BgeGap.md(),
        ],
        EventWhenField(
          key: EventCreateDatesSection.startKey(index),
          control: start,
          label: l10n.eventCreateStart,
          validationMessages: {
            ValidationMessage.required: (_) => l10n.eventCreateDateRequired,
          },
          readOnly: readOnly,
          now: now,
        ),
        const BgeGap.md(),
        ReactiveValueListenableBuilder<DateTime>(
          formControl: end,
          // Always a row, so the field keeps its place in the tree when the
          // clear button comes and goes.
          builder: (context, control, _) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: EventWhenField(
                  key: EventCreateDatesSection.endKey(index),
                  control: end,
                  opensOn: start,
                  label: l10n.eventCreateEnd,
                  validationMessages: {
                    EventCreateErrors.endBeforeStart: (_) =>
                        l10n.eventCreateEndBeforeStart,
                  },
                  readOnly: readOnly,
                  now: now,
                ),
              ),
              if (control.value != null)
                IconButton(
                  key: EventCreateDatesSection.clearEndKey(index),
                  tooltip: l10n.eventCreateClearEnd,
                  icon: const Icon(Icons.clear),
                  onPressed: readOnly ? null : () => end.value = null,
                ),
            ],
          ),
        ),
        if (remove != null)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              key: EventCreateDatesSection.removeKey(index),
              onPressed: readOnly ? null : remove,
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.eventCreateRemoveDate),
            ),
          ),
      ],
    );
  }
}

/// *Add a date*, and under it the form's too-few error when it shows.
///
/// Bound to the mode control, which carries that error, so a submit refused
/// for it focuses *Add a date* and brings it into view, as it does a field.
class _AddDate extends StatelessWidget {
  const _AddDate({
    required this.mode,
    required this.readOnly,
    required this.onAdd,
  });

  final FormControl<EventSchedulingMode> mode;
  final bool readOnly;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);

    return ReactiveFocusableFormField<EventSchedulingMode, EventSchedulingMode>(
      formControl: mode,
      validationMessages: {
        EventCreateErrors.tooFewDates: (_) => l10n.eventCreateDatesTooFew,
      },
      builder: (field) {
        final error = field.errorText;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              key: EventCreateDatesSection.addDateKey,
              focusNode: field.focusNode,
              onPressed: readOnly ? null : onAdd,
              icon: const Icon(Icons.add),
              label: Text(l10n.eventCreateAddDate),
            ),
            // Under the button, so revealing the button from below, where
            // the submit is, shows it too. Not a field, so it has no field's
            // error line: announced the way one is.
            if (error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  key: EventCreateDatesSection.tooFewKey,
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
