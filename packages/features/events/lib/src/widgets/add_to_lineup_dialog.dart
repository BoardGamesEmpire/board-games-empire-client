import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_event.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/create/event_create_controls.dart'
    show trimmedOrNull;
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:events/src/widgets/pool_row_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the add dialog answers (#519): the date the game is for, or null
/// for the whole event; what it is played as; the note, trimmed, or null for
/// none; and a Filler's longest play in minutes, null for a Primary and for
/// a Filler given none.
typedef AddToLineupChoice = ({
  String? occurrenceId,
  ScheduledGameRole role,
  String? notes,
  int? maxPlayTime,
});

/// Asks how the game named [title], as its pool row names it, with its
/// subtitle where it has one (#851), goes into the lineup (#519), and
/// answers the choice, or null when cancelled.
///
/// - **The date**, only where [scopes] holds more than one: a radio button
///   each, in order, named for the whole event or the date as [now] names
///   it, the first chosen as it opens. That is an event with no row of
///   dates, where the add can be for the whole event or its one date. Under
///   a row the view's choice is the add's (#1042), so with one scope it asks
///   nothing.
/// - **What it is played as**: Primary or Filler, Primary as it opens.
/// - **A Filler's longest play**, shown only once Filler is chosen: a whole
///   number of minutes, at least one, filled in with the rules' one for the
///   scope chosen ([fillerMaxPlayTimeOf]), where they set one. Choosing
///   another scope fills in that one's, while the field still holds what was
///   filled in; once the host has changed it, it is theirs. It may be left
///   empty for none.
///   Anything else is refused as Add to lineup is pressed, with the error
///   under the field and focus on it ([BgeRejectedSubmit]). Back on
///   Primary it is neither checked nor sent.
/// - **A note**, which may be left empty.
///
/// Where the scope chosen has started ([startedOf]), a game added to it
/// can't then be taken out of the lineup (#520), so a line under the date,
/// ahead of everything else it asks, says so, and a screen reader hears it
/// as the choice changes it.
///
/// Scrollable, since at 2.0 text a long title and the fields can outgrow a
/// phone's height. Adding takes nothing away, so Add to lineup is drawn as an
/// ordinary button, not a destructive one.
Future<AddToLineupChoice?> showAddToLineupDialog(
  BuildContext context, {
  required String title,
  required List<NominateScope> scopes,
  required DateTime now,
  int? Function(NominationScope scope)? fillerMaxPlayTimeOf,
  bool Function(NominationScope scope)? startedOf,
}) => showDialog<AddToLineupChoice>(
  context: context,
  builder: (_) => _AddToLineupDialog(
    title: title,
    scopes: scopes,
    now: now,
    fillerMaxPlayTimeOf: fillerMaxPlayTimeOf,
    startedOf: startedOf,
  ),
);

class _AddToLineupDialog extends StatefulWidget {
  const _AddToLineupDialog({
    required this.title,
    required this.scopes,
    required this.now,
    this.fillerMaxPlayTimeOf,
    this.startedOf,
  });

  final String title;
  final List<NominateScope> scopes;
  final DateTime now;

  /// The longest a filler should run for a scope, by the rules (#519).
  final int? Function(NominationScope scope)? fillerMaxPlayTimeOf;

  /// Whether a game added for a scope could no longer be taken out of the
  /// lineup, as its date has started (#520). None has where it is null.
  final bool Function(NominationScope scope)? startedOf;

  @override
  State<_AddToLineupDialog> createState() => _AddToLineupDialogState();
}

class _AddToLineupDialogState extends State<_AddToLineupDialog> {
  late NominationScope? _scope = widget.scopes.firstOrNull?.scope;
  ScheduledGameRole _role = ScheduledGameRole.primary;

  /// The minutes last filled in from the rules, as the field holds them: ''
  /// for none.
  late String _filledIn = _minutesFor(_scope);

  late final FormGroup _form = FormGroup({
    // Checked only while Filler is chosen, when it is shown: disabled until
    // then, so the form's validity leaves it out.
    _minutes: FormControl<String>(
      value: _filledIn.isEmpty ? null : _filledIn,
      validators: [Validators.delegate(_checkMinutes)],
      disabled: true,
    ),
    _notes: FormControl<String>(),
  });

  /// The rules' longest filler for [scope], as the field holds it.
  String _minutesFor(NominationScope? scope) =>
      switch (scope == null ? null : widget.fillerMaxPlayTimeOf?.call(scope)) {
        final minutes? when minutes > 0 => '$minutes',
        _ => '',
      };

  /// Chooses [scope], and fills in its rules' longest filler where the field
  /// still holds what was filled in, not what the host typed.
  void _setScope(NominationScope scope) {
    final minutes = _form.control(_minutes);
    if (((minutes.value as String?) ?? '') == _filledIn) {
      _filledIn = _minutesFor(scope);
      minutes.value = _filledIn.isEmpty ? null : _filledIn;
    }
    setState(() => _scope = scope);
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _setRole(ScheduledGameRole role) {
    final minutes = _form.control(_minutes);
    if (role == ScheduledGameRole.filler) {
      minutes.markAsEnabled();
    } else {
      minutes.markAsDisabled();
    }
    setState(() => _role = role);
  }

  void _submit() {
    if (!_form.valid) return _form.rejectSubmit();
    final filler = _role == ScheduledGameRole.filler;
    Navigator.of(context).pop<AddToLineupChoice>((
      occurrenceId: switch (_scope) {
        DateScope(:final occurrenceId) => occurrenceId,
        WholeEventScope() || null => null,
      },
      role: _role,
      notes: trimmedOrNull(_form.control(_notes).value),
      maxPlayTime: filler
          ? _wholeNumberOf(_form.control(_minutes).value as String?)
          : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final title = l10n.eventsLineupAddTitle(widget.title);
    final scopes = widget.scopes;
    final scope = _scope;
    // What can't then come out of the lineup (#520), said up front.
    final started = scope != null && (widget.startedOf?.call(scope) ?? false)
        ? switch (scope) {
            DateScope() => l10n.eventsLineupAddDateStarted,
            WholeEventScope() => l10n.eventsLineupAddEventStarted,
          }
        : null;

    return ReactiveForm(
      formGroup: _form,
      child: AlertDialog(
        scrollable: true,
        // Without it the dialog has no name on iOS and macOS (#762).
        semanticLabel: title,
        title: Text(title),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Only where there is no row of dates to give it (#1042).
            if (scopes.length > 1) ...[
              RadioGroup<NominationScope>(
                groupValue: _scope,
                onChanged: (scope) {
                  if (scope != null) _setScope(scope);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final choice in scopes)
                      BgeRowFocusRing(
                        outsideSides: true,
                        builder: (context, tile) =>
                            RadioListTile<NominationScope>(
                              key: EventDetailScreen.addToLineupScopeKey(
                                choice.date?.id,
                              ),
                              focusNode: tile.focusNode,
                              onFocusChange: tile.onFocusChange,
                              value: choice.scope,
                              contentPadding: EdgeInsets.zero,
                              title: Text(switch (choice.date) {
                                null => l10n.eventsNominationWholeEvent,
                                final date => l10n.eventsNominationForDate(
                                  eventDateName(context, date, now: widget.now),
                                ),
                              }),
                            ),
                      ),
                  ],
                ),
              ),
              const BgeGap.md(),
            ],
            if (started != null) ...[
              // A live region, as the choice above changes it.
              Semantics(
                container: true,
                liveRegion: true,
                child: Text(started),
              ),
              const BgeGap.md(),
            ],
            Text(l10n.eventsLineupRoleLabel, style: theme.textTheme.labelLarge),
            const BgeGap.sm(),
            SegmentedButton<ScheduledGameRole>(
              segments: [
                for (final (role, label) in [
                  (
                    ScheduledGameRole.primary,
                    l10n.eventsLineupRolePrimaryChoice,
                  ),
                  (ScheduledGameRole.filler, l10n.eventsLineupRoleFillerChoice),
                ])
                  ButtonSegment(
                    value: role,
                    label: Text(
                      label,
                      key: EventDetailScreen.addToLineupRoleKey(role),
                    ),
                  ),
              ],
              selected: {_role},
              onSelectionChanged: (selected) => _setRole(selected.single),
            ),
            if (_role == ScheduledGameRole.filler) ...[
              const BgeGap.md(),
              // A short label, since a field's is one line; the note says the
              // rest, and is read as the field's hint, since a helper isn't
              // read as the field takes focus.
              Semantics(
                hint: l10n.eventsLineupMaxMinutesNote,
                child: BgeTextField(
                  key: EventDetailScreen.addToLineupMinutesKey,
                  formControlName: _minutes,
                  label: l10n.eventsLineupMaxMinutesLabel,
                  keyboardType: TextInputType.number,
                  autocorrect: false,
                  enableSuggestions: false,
                  validationMessages: {
                    _minutesInvalid: (_) => l10n.eventsLineupMaxMinutesInvalid,
                  },
                ),
              ),
              const BgeGap.xs(),
              ExcludeSemantics(
                child: Text(
                  l10n.eventsLineupMaxMinutesNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const BgeGap.md(),
            BgeTextField(
              key: EventDetailScreen.addToLineupNotesKey,
              formControlName: _notes,
              label: l10n.eventsLineupNotesLabel,
              textInputAction: TextInputAction.done,
              minLines: 1,
              maxLines: 4,
              onSubmitted: _submit,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.eventsLineupAddCancel),
          ),
          TextButton(
            key: EventDetailScreen.addToLineupConfirmKey,
            onPressed: _submit,
            child: Text(l10n.eventsLineupAddToLineup),
          ),
        ],
      ),
    );
  }
}

const _minutes = 'minutes';
const _notes = 'notes';

/// The error key of a Filler's longest play that isn't a whole number of
/// minutes it may be.
const _minutesInvalid = 'minutesInvalid';

/// The longest play the server keeps: it stores it in a Postgres integer, so
/// a larger number would pass its checks and fail to store.
const _largestMinutes = 2147483647;

/// [_minutesInvalid] unless [control] holds a whole number of minutes from 1
/// to [_largestMinutes], or nothing.
Map<String, dynamic>? _checkMinutes(AbstractControl<dynamic> control) {
  final text = (control.value as String?)?.trim() ?? '';
  if (text.isEmpty) return null;
  final minutes = _wholeNumberOf(text);
  return minutes != null && minutes >= 1 && minutes <= _largestMinutes
      ? null
      : {_minutesInvalid: true};
}

/// The whole number [text] says once trimmed, or null when it says none:
/// digits alone, so no sign, point or exponent, which `int.tryParse` would
/// take.
int? _wholeNumberOf(String? text) {
  final trimmed = text?.trim() ?? '';
  return _digits.hasMatch(trimmed) ? int.tryParse(trimmed) : null;
}

final _digits = RegExp(r'^[0-9]+$');

/// Opens the list Add a game picks from on the Lineup sub-tab (#519): every
/// copy the pool holds, in its order, as it holds them while the list is
/// open, each named as its pool row names it, the title with its subtitle
/// ([gameName], #851), with who brings it under it, by the viewer's roster
/// row and the roster's names. Answers the copy picked, or null when it is
/// closed with none.
///
/// Where the pool holds no games, it says what the Pool sub-tab says, by the
/// same rule ([eventPoolBody]): a spinner while the first read is out; that
/// the games couldn't be loaded, with Try again, which reads the pool, or the
/// event where no roster was read; that the games aren't shown; or that none
/// are offered. Where the event leaves the screen while it is open, it says
/// so in place of the list, as a quick look whose entry has left does, with
/// nothing to pick: that the event can't be found, as the screen beneath
/// now says, or, where it can't be shown, that there is nothing to pick from.
/// A wait for an answer that can still come keeps the spinner, and the list
/// follows that answer.
///
/// A copy whose supplier has answered Not going ([supplierNotGoing]) can't
/// be picked: the server refuses to add it. Its row is disabled and says
/// why under who brings it, as part of its name to a screen reader, rather
/// than leaving the pool's rows out (STYLE_GUIDE §5).
///
/// A pop-up ([showBgePopup]), on the root navigator, named by its heading:
/// a sheet at `compact`, as `showModalBottomSheet` with `useRootNavigator`
/// gives one, and a dialog from `medium` up. The root navigator is outside
/// the screen, so it is given the detail's and the pool's blocs and the
/// tab's controller from [context], as the quick look is. Scrollable, so a
/// long pool at 200% text stays reachable. It hands focus back to Add a game
/// as it closes.
Future<OfferedGame?> showLineupGamePicker(BuildContext context) {
  final detail = context.read<EventDetailBloc>();
  final games = context.read<EventGamesBloc>();
  final controller = EventGamesTabScope.of(context);
  return showBgePopup<OfferedGame>(
    context,
    semanticLabel: EventsLocalizations.of(context).eventsLineupPickTitle,
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider<EventDetailBloc>.value(value: detail),
        BlocProvider<EventGamesBloc>.value(value: games),
      ],
      child: EventGamesTabScope.value(
        controller: controller,
        child: const _LineupGamePicker(),
      ),
    ),
  );
}

class _LineupGamePicker extends StatelessWidget {
  const _LineupGamePicker();

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);

    return SingleChildScrollView(
      key: EventDetailScreen.lineupPickerKey,
      padding: EdgeInsets.all(tokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.eventsLineupPickTitle,
              style: theme.textTheme.titleLarge,
            ),
          ),
          const BgeGap.md(),
          BlocBuilder<EventDetailBloc, EventDetailState>(
            builder: (context, detail) =>
                BlocBuilder<EventGamesBloc, EventGamesState>(
                  builder: (context, games) => switch (detail) {
                    final EventDetailReady ready => _pool(
                      context,
                      l10n,
                      ready,
                      games,
                    ),
                    // Opened from a ready event, so the event has left the
                    // screen beneath: said, as a quick look says its entry
                    // left, and nothing to pick.
                    EventDetailNotFound() => BgeEmptyState(
                      icon: Icons.event_busy_outlined,
                      title: l10n.eventsDetailNotFoundTitle,
                      body: l10n.eventsDetailNotFoundBody,
                    ),
                    EventDetailError() => BgeEmptyState(
                      icon: Icons.cloud_off_outlined,
                      title: l10n.eventsLineupPickUnavailable,
                    ),
                    // An answer can still come, and the list follows it.
                    EventDetailLoading() => BgeLoadingState(
                      label: l10n.eventsGamesLoading,
                    ),
                  },
                ),
          ),
        ],
      ),
    );
  }

  /// The pool's games, or the state its read is in, as the Pool sub-tab
  /// draws it ([eventPoolBody]).
  Widget _pool(
    BuildContext context,
    EventsLocalizations l10n,
    EventDetailReady detail,
    EventGamesState games,
  ) {
    final viewerId = detail.detail.attendance?.id;
    final names = poolNames(detail.detail);
    return switch (eventPoolBody(
      detail,
      games,
      EventGamesTabScope.of(context),
    )) {
      EventPoolBody.hidden => BgeEmptyState(
        icon: Icons.visibility_off_outlined,
        title: l10n.eventsGamesHiddenTitle,
      ),
      EventPoolBody.loading => BgeLoadingState(label: l10n.eventsGamesLoading),
      EventPoolBody.failed => BgeErrorState(
        icon: Icons.cloud_off_outlined,
        title: l10n.eventsGamesFailedTitle,
        body: l10n.eventsGamesFailedBody,
        retryLabel: l10n.eventsRefreshRetry,
        retryProgressLabel: l10n.eventsRefreshInProgress,
        retryKey: EventDetailScreen.lineupPickerRetryKey,
        retrying: games.refreshing,
        onRetry: () => retryEventGamesPool(context),
      ),
      EventPoolBody.rosterFailed => BgeErrorState(
        icon: Icons.cloud_off_outlined,
        title: l10n.eventsGamesFailedTitle,
        body: l10n.eventsGamesFailedBody,
        retryLabel: l10n.eventsRefreshRetry,
        retryProgressLabel: l10n.eventsRefreshInProgress,
        retryKey: EventDetailScreen.lineupPickerRetryKey,
        retrying: detail.refreshing,
        // The event's read brings the roster, whose end reads the pool.
        onRetry: () => context.read<EventDetailBloc>().add(
          const EventDetailRetryRequested(),
        ),
      ),
      EventPoolBody.empty => BgeEmptyState(
        icon: Icons.casino_outlined,
        title: l10n.eventsGamesEmptyTitle,
        body: l10n.eventsLineupPickEmpty,
      ),
      // It has no filter, so it holds every game the pool does.
      EventPoolBody.noMatches || EventPoolBody.rows => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final game in games.games)
            _PickRow(
              key: ValueKey<String>(game.id),
              game: game,
              who: game.attendeeId == viewerId
                  ? l10n.eventsGamesYours
                  : l10n.eventsGamesTheirs(
                      names[game.attendeeId] ?? l10n.eventsAttendeeSomeoneStart,
                    ),
              // In the second person on the viewer's own, as the pool's
              // rows say it.
              notGoing: !supplierNotGoing(detail.detail, game)
                  ? null
                  : game.attendeeId == viewerId
                  ? l10n.eventsNominateYouNotGoingHint
                  : l10n.eventsNominateSupplierNotGoingHint,
            ),
        ],
      ),
    };
  }
}

/// One copy the picker offers: its cover, its name, who brings it and, where
/// it can't be picked, why, as one tile that picks it. The reason is drawn
/// as legibly as the pool row's note is, not greyed with the tile.
class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.game,
    required this.who,
    this.notGoing,
    super.key,
  });

  final OfferedGame game;
  final String who;

  /// Why it can't be picked: whoever brings it isn't going. Null otherwise.
  final String? notGoing;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final notGoing = this.notGoing;

    return BgeRowFocusRing(
      outsideSides: true,
      builder: (context, tile) => ListTile(
        key: EventDetailScreen.lineupPickKey(game.id),
        focusNode: tile.focusNode,
        onFocusChange: tile.onFocusChange,
        titleAlignment: BgeThumbnail.titleAlignmentOf(context),
        minTileHeight: BgeThumbnail.minTileHeightOf(context),
        contentPadding: EdgeInsets.zero,
        horizontalTitleGap: tokens.spaceSm,
        enabled: notGoing == null,
        leading: BgeThumbnail(url: game.thumbnail),
        title: Text(gameName(l10n, game.title, game.subtitle)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(who),
            // Legible, as the reason a control can't be used is (STYLE_GUIDE
            // §5): not greyed with the rest of the tile.
            if (notGoing != null)
              Text(
                notGoing,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        onTap: () => Navigator.of(context).pop(game),
      ),
    );
  }
}
