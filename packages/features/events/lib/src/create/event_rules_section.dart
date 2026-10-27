import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import 'event_create_controls.dart';
import 'event_create_parts.dart';
import 'event_policy_labels.dart';

/// The create form's *Advanced: rules* (#499): how games get added to the
/// event, and while attendees vote on them, how a vote is decided and how
/// long it stays open.
///
/// It edits the rules of the ambient [ReactiveForm], built by
/// [buildEventCreateForm], which keeps what follows what: the voting
/// settings show while attendees vote, a number while its type takes one
/// ([thresholdNumberOf], [quorumNumberOf]), and a switch of type starts its
/// number over.
///
/// - Collapsed at first, since most events keep the server's rules. The note
///   that rules can't be changed once the event exists shows under the title
///   all the same: the server's rules, left as they are, are just as final.
/// - How games get added starts untouched, and reads as *Direct*, the
///   server's own default, so an untouched form sends no rules ([policyOf]).
/// - A rule with an error keeps the rules open, and says what is wrong.
///   Collapsed, its field would be gone, so a submit refused for it would
///   have nothing to focus or show.
/// - It opens and closes over `motionShort`, and at once where the platform
///   asks for reduced motion (STYLE_GUIDE §5). Left to itself, the tile
///   takes 200ms either way (measured).
///
/// [readOnly] locks it while a create is on its way, as the household forms
/// lock theirs: the menus don't open and the numbers take no typing, though
/// the rules still open and close, to be read. No control is disabled for
/// it, since enabling one again would emit a value change.
class EventRulesSection extends StatefulWidget {
  const EventRulesSection({this.readOnly = false, super.key});

  static const Key tileKey = Key('event_create.rules');
  static const Key lockedKey = Key('event_create.rules_locked');
  static const Key gameAdditionKey = Key('event_create.game_addition');
  static const Key thresholdKey = Key('event_create.threshold');
  static const Key thresholdValueKey = Key('event_create.threshold_value');
  static const Key quorumKey = Key('event_create.quorum');
  static const Key quorumValueKey = Key('event_create.quorum_value');
  static const Key windowKey = Key('event_create.window');

  /// Whether a create is on its way: nothing here takes an edit.
  final bool readOnly;

  @override
  State<EventRulesSection> createState() => _EventRulesSectionState();
}

class _EventRulesSectionState extends State<EventRulesSection> {
  final ExpansibleController _tile = ExpansibleController();

  @override
  void dispose() {
    _tile.dispose();
    super.dispose();
  }

  /// Opens the rules again if one of them has an error, and marks it
  /// touched, so it says what is wrong.
  void _onExpansionChanged(bool expanded) {
    final form = ReactiveForm.of(context, listen: false);
    if (expanded || form is! FormGroup) return;
    final wrong = [for (final name in _rules) form.control(name)]
        .where((control) => control.invalid)
        .toList();
    if (wrong.isEmpty) return;
    for (final control in wrong) {
      control.markAsTouched();
    }
    _tile.expand();
  }

  @override
  Widget build(BuildContext context) {
    final form = ReactiveForm.of(context, listen: false);
    if (form is! FormGroup) throw FormControlParentNotFoundException(widget);
    final gameAddition = form.control(
      EventCreateControls.gameAddition,
    ) as FormControl<GameAdditionMode>;
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final readOnly = widget.readOnly;

    return ExpansionTile(
      key: EventRulesSection.tileKey,
      controller: _tile,
      title: Text(
        l10n.eventCreateRulesTitle,
        style: theme.textTheme.titleMedium,
      ),
      // Under the title, so it shows while the rules are collapsed. Read
      // with the title, as part of the form rather than an outcome, so it
      // announces nothing. The server takes no change to an event's rules
      // yet: remove this once it does
      // (BoardGamesEmpire/board-games-empire-backend#796).
      subtitle: Text(
        key: EventRulesSection.lockedKey,
        l10n.eventCreateRulesLocked,
        style: eventCreateQuiet(theme),
      ),
      // Flush with the sections above it, rather than inset as a list row.
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.only(bottom: tokens.spaceMd),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      expansionAnimationStyle: AnimationStyle(
        duration: BgeMotion.durationOf(context, tokens.motionShort),
        curve: BgeMotion.standard,
      ),
      onExpansionChanged: _onExpansionChanged,
      children: [
        // Room for the menu's label, which floats above the menu's edge:
        // the tile clips what it opens at the bottom of its header, and cut
        // the label's top off there, by 11.5dp at 2.0 text (measured).
        const BgeGap.md(),
        EventCreateMenu<GameAdditionMode>(
          key: EventRulesSection.gameAdditionKey,
          formControl: gameAddition,
          label: l10n.eventCreateGameAddition,
          // While it is untouched, the server's default applies.
          hint: l10n.gameAdditionDirect,
          items: eventCreateMenuItems(
            GameAdditionMode.values,
            (mode) => gameAdditionLabel(l10n, mode),
          ),
          readOnly: readOnly,
        ),
        ReactiveValueListenableBuilder<GameAdditionMode>(
          formControl: gameAddition,
          builder: (context, control, _) =>
              control.value == GameAdditionMode.requiresVote
              ? _Voting(form: form, readOnly: readOnly)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// The controls a rule is set in, for finding one with an error.
const _rules = [
  EventCreateControls.gameAddition,
  EventCreateControls.threshold,
  EventCreateControls.thresholdValue,
  EventCreateControls.quorum,
  EventCreateControls.quorumValue,
  EventCreateControls.windowHours,
];

/// The settings of a vote: how many votes a game needs, how many people
/// must vote, and how long voting stays open.
///
/// A threshold or quorum shows a field for its number only where the form's
/// own rule gives its type one, so the two can't disagree.
class _Voting extends StatelessWidget {
  const _Voting({required this.form, required this.readOnly});

  final FormGroup form;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final threshold = form.control(
      EventCreateControls.threshold,
    ) as FormControl<VoteThresholdType>;
    final quorum =
        form.control(EventCreateControls.quorum) as FormControl<VoteQuorumType>;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const BgeGap.md(),
        EventCreateMenu<VoteThresholdType>(
          key: EventRulesSection.thresholdKey,
          formControl: threshold,
          label: l10n.eventCreateThreshold,
          items: eventCreateMenuItems(
            VoteThresholdType.values,
            (type) => voteThresholdLabel(l10n, type),
          ),
          readOnly: readOnly,
        ),
        ReactiveValueListenableBuilder<VoteThresholdType>(
          formControl: threshold,
          builder: (context, control, _) =>
              switch (thresholdNumberOf(control.value)) {
                final number? => _NumberField(
                  key: EventRulesSection.thresholdValueKey,
                  controlName: EventCreateControls.thresholdValue,
                  label: number.percent
                      ? l10n.eventCreateThresholdPercent
                      : l10n.eventCreateThresholdCount,
                  readOnly: readOnly,
                ),
                // Its type takes no number.
                null => const SizedBox.shrink(),
              },
        ),
        const BgeGap.md(),
        EventCreateMenu<VoteQuorumType>(
          key: EventRulesSection.quorumKey,
          formControl: quorum,
          label: l10n.eventCreateQuorum,
          items: eventCreateMenuItems(
            VoteQuorumType.values,
            (type) => voteQuorumLabel(l10n, type),
          ),
          readOnly: readOnly,
        ),
        ReactiveValueListenableBuilder<VoteQuorumType>(
          formControl: quorum,
          builder: (context, control, _) =>
              switch (quorumNumberOf(control.value)) {
                final number? => _NumberField(
                  key: EventRulesSection.quorumValueKey,
                  controlName: EventCreateControls.quorumValue,
                  label: number.percent
                      ? l10n.eventCreateQuorumPercent
                      : l10n.eventCreateQuorumCount,
                  readOnly: readOnly,
                ),
                // Its type takes no number.
                null => const SizedBox.shrink(),
              },
        ),
        _NumberField(
          key: EventRulesSection.windowKey,
          controlName: EventCreateControls.windowHours,
          label: l10n.eventCreateWindow,
          helper: l10n.eventCreateWindowHint,
          readOnly: readOnly,
        ),
      ],
    );
  }
}

/// One of the rules' numbers, with the space above it.
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controlName,
    required this.label,
    required this.readOnly,
    this.helper,
    super.key,
  });

  final String controlName;
  final String label;
  final String? helper;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const BgeGap.md(),
        BgeTextField(
          formControlName: controlName,
          label: label,
          helper: helper,
          keyboardType: TextInputType.number,
          autocorrect: false,
          enableSuggestions: false,
          readOnly: readOnly,
          validationMessages: {
            EventCreateErrors.wholeNumber: (range) =>
                _rangeMessage(l10n, range as WholeNumberRange),
          },
        ),
      ],
    );
  }
}

/// What a number out of [range] is told to be instead.
String _rangeMessage(EventsLocalizations l10n, WholeNumberRange range) =>
    switch (range.max) {
      final max? => l10n.eventCreateNumberRange(range.min, max),
      null => l10n.eventCreateNumberMin(range.min),
    };
