import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'event_labels.dart';

/// A start or an end: the date and time picked, read back as the
/// event's rows say it, or its label alone while it is empty. It serves the
/// create form's rows and the date dialog (#506).
///
/// A focusable form field, so a refused submit can focus it and bring it,
/// error and all, into view. While it holds the focus it draws the theme's
/// focused border, as a text field and a menu do.
class EventWhenField extends StatelessWidget {
  const EventWhenField({
    required this.control,
    required this.label,
    required this.validationMessages,
    required this.readOnly,
    required this.now,
    this.opensOn,
    super.key,
  });

  final FormControl<DateTime> control;
  final String label;
  final Map<String, ValidationMessageFunction> validationMessages;
  final bool readOnly;
  final DateTime Function() now;

  /// What the pickers open on while this is empty, before the clock: an end
  /// opens on its start.
  final FormControl<DateTime>? opensOn;

  @override
  Widget build(BuildContext context) =>
      ReactiveFocusableFormField<DateTime, DateTime>(
        formControl: control,
        validationMessages: validationMessages,
        builder: (field) {
          final value = field.value;
          final error = field.errorText;
          // One node: the label, what is picked and any error. A button
          // while a pick can be made; read-only, there is nothing to press,
          // so it only says what it holds, as a read-only text field does.
          return MergeSemantics(
            child: Semantics(
              button: !readOnly,
              child: InkWell(
                focusNode: field.focusNode,
                borderRadius: BorderRadius.circular(
                  BgeTokens.of(field.context).radiusSm,
                ),
                onTap: readOnly ? null : () => unawaited(_pick(field)),
                // Rebuilt as the field's focus comes and goes, which
                // `Focus.of` depends on: the field itself rebuilds for its
                // value, its errors and being touched, not for the focus.
                child: Builder(
                  builder: (context) => InputDecorator(
                    isFocused: Focus.of(context).hasFocus,
                    isEmpty: value == null,
                    decoration: InputDecoration(
                      labelText: label,
                      // Always on the border, where it is drawn smaller:
                      // resting inside an empty field beside the icon, "Ends
                      // (optional)" was cut short at 320dp and 2.0 text.
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      // A widget rather than errorText, which keeps to one
                      // line and cut "Ends before it starts." short there.
                      error: error == null ? null : Text(error),
                      suffixIcon: const Icon(Icons.event_outlined),
                    ),
                    child: Text(
                      value == null
                          ? ''
                          : eventWhenLabel(field.context, value, now: now()),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );

  /// The date picker, then the time picker. Either one cancelled changes
  /// nothing.
  Future<void> _pick(ReactiveFormFieldState<DateTime, DateTime> field) async {
    final context = field.context;
    final now = this.now();
    final today = DateUtils.dateOnly(now);
    // Today through two years ahead: a game night is planned weeks out,
    // and next year's convention can be more than a year out. The server
    // takes any date; this only bounds the calendar. A date past either
    // bound, being edited (#506), keeps its day: the calendar reaches it.
    final days = [
      control.value,
      opensOn?.value,
    ].nonNulls.map(DateUtils.dateOnly).toList();
    final firstDate = days.fold(
      today,
      (first, day) => day.isBefore(first) ? day : first,
    );
    final lastDate = days.fold(
      DateTime(today.year + 2, today.month, today.day),
      (last, day) => day.isAfter(last) ? day : last,
    );
    final from = control.value ?? opensOn?.value ?? now;

    final date = await showDatePicker(
      context: context,
      initialDate: _within(DateUtils.dateOnly(from), firstDate, lastDate),
      firstDate: firstDate,
      lastDate: lastDate,
      currentDate: now,
      initialEntryMode: _dateEntryMode(context),
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(from),
    );
    if (time == null || !context.mounted) return;

    field.didChange(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
    control.markAsTouched();
  }
}

/// [day], kept between [first] and [last].
DateTime _within(DateTime day, DateTime first, DateTime last) =>
    day.isBefore(first) ? first : (day.isAfter(last) ? last : day);

/// The calendar, unless text is scaled past 1.5. Past that, its two-digit
/// days no longer fit their cells on a phone (measured: from 1.75 at 320dp,
/// at 2.0 at 360dp), so the picker opens on typing the date, with the
/// calendar a tap away.
DatePickerEntryMode _dateEntryMode(BuildContext context) {
  final scale =
      MediaQuery.textScalerOf(context).scale(_fontSizeToScale) /
      _fontSizeToScale;
  return scale > _calendarMaxTextScale
      ? DatePickerEntryMode.input
      : DatePickerEntryMode.calendar;
}

const double _calendarMaxTextScale = 1.5;

/// The size the effective text scale is read at, as the date picker reads
/// its own.
const double _fontSizeToScale = 14;
