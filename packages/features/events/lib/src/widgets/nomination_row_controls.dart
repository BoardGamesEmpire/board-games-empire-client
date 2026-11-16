import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/confirm_dialog.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/held_spinner.dart';
import 'package:events/src/widgets/nomination_vote_control.dart';
import 'package:events/src/widgets/nomination_voters_sheet.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart' hide Visibility;
import 'package:ui/ui.dart';

/// A host's decision on a nomination (#518), in the order their buttons
/// take on a row: the write it sends, the action in the role table it needs,
/// and the status it settles a nomination from.
enum NominationDecision {
  approve(
    NominationWrite.approve,
    EventAction.approveGame,
    NominationStatus.awaitingApproval,
    Icons.check_circle_outline,
  ),
  reject(
    NominationWrite.reject,
    EventAction.rejectGame,
    NominationStatus.awaitingApproval,
    Icons.block,
  ),
  resolve(
    NominationWrite.resolve,
    EventAction.resolveNomination,
    NominationStatus.open,
    Icons.lock_outline,
  );

  const NominationDecision(this.write, this.action, this.from, this.icon);

  final NominationWrite write;
  final EventAction action;

  /// The status a nomination has while this decision is offered on it, and
  /// still has when it is sent.
  final NominationStatus from;

  /// Its button's icon.
  final IconData icon;

  /// Its button's key on the nomination [id].
  Key keyOn(String id) => switch (this) {
    approve => EventDetailScreen.nominationApproveKey(id),
    reject => EventDetailScreen.nominationRejectKey(id),
    resolve => EventDetailScreen.nominationCloseVoteKey(id),
  };

  /// Its button's key in a nomination's quick look (#957).
  Key get quickLookKey => switch (this) {
    approve => EventDetailScreen.quickLookApproveKey,
    reject => EventDetailScreen.quickLookRejectKey,
    resolve => EventDetailScreen.quickLookCloseVoteKey,
  };

  /// Its button's label.
  String label(EventsLocalizations l10n) => switch (this) {
    approve => l10n.eventsApprove,
    reject => l10n.eventsReject,
    resolve => l10n.eventsCloseVote,
  };

  /// Its button's name to a screen reader, on the nomination of [title].
  String named(EventsLocalizations l10n, String title) => switch (this) {
    approve => l10n.eventsApproveNamed(title),
    reject => l10n.eventsRejectNamed(title),
    resolve => l10n.eventsCloseVoteNamed(title),
  };

  /// Its dialog's title, on the nomination of [title].
  String confirmTitle(EventsLocalizations l10n, String title) => switch (this) {
    approve => l10n.eventsApproveConfirmTitle(title),
    reject => l10n.eventsRejectConfirmTitle(title),
    resolve => l10n.eventsCloseVoteConfirmTitle(title),
  };

  /// Its dialog's confirm button's label.
  String confirmLabel(EventsLocalizations l10n) => switch (this) {
    approve => l10n.eventsApproveConfirm,
    reject => l10n.eventsRejectConfirm,
    resolve => l10n.eventsCloseVoteConfirm,
  };
}

/// What the viewer's vote on an open nomination needs: the line above it,
/// and whether it may be pressed now ([NominationVoteControl.enabled] and
/// [NominationVoteControl.busy]).
typedef NominationVoting = ({VoteHint? hint, bool enabled, bool busy});

/// What a nomination's write buttons need, Withdraw (#517) and a host's
/// decisions (#518): whether the viewer may withdraw their own nominations,
/// the decisions their actions hold, whether these may be pressed now,
/// connection aside ([NominationWriteButton.enabled]), and whether a
/// nominations write is out.
typedef NominationRowWrites = ({
  bool withdraw,
  Set<NominationDecision> decisions,
  bool enabled,
  bool busy,
});

/// What a nomination's row is built from, and its quick look (#957): the
/// viewer's vote where they may vote, else null; the write buttons'
/// arguments; the pool row the nominated copy comes from, or null where the
/// pool doesn't hold it; the event's dates, one of which it may be for; how
/// the event counts Interested, or null where its policy isn't known; and
/// whether who voted may name the voters, false where the roster was read
/// and withheld.
typedef NominationRowInputs = ({
  NominationVoting? voting,
  NominationRowWrites writes,
  OfferedGame? copy,
  List<EventOccurrence> occurrences,
  InterestedWeight? interestedWeight,
  bool rosterShown,
});

/// What [nomination]'s row is built from (#957), from the detail, the
/// nominations' [state], the [pool] as last read and whether it says what
/// the viewer offers ([poolRead]), and whether the screen is [acting]
/// (`eventScreenActing`): one place, so the row and its quick look offer
/// the same votes and writes under the same rules.
///
/// A vote where the viewer's actions hold [EventAction.voteGame], they have
/// a row on the roster and the event takes writes ([takesDateWrites]: not
/// cancelled or archived), with the line [voteHintFor] gives above it: the
/// one about offering a game only once [poolRead]. Withdraw where their
/// actions hold [EventAction.nominateGame], on the same terms, and each of a
/// host's decisions their actions hold, on an event that takes writes. As
/// the tab's other writes are (#589), none may be pressed while a detail
/// read runs or the screen is acting, and Withdraw and the decisions not
/// while a nominations write is out either; a vote's control holds itself
/// through the nominations' own writes.
NominationRowInputs nominationRowInputs({
  required EventNomination nomination,
  required EventDetailReady detail,
  required EventNominationsState state,
  required List<OfferedGame> pool,
  required bool poolRead,
  required bool acting,
}) {
  final snapshot = detail.detail.snapshot;
  final viewerId = detail.detail.attendance?.id;
  // No vote, no Withdraw and no host decision on an event that takes no
  // writes, cancelled or archived, as no Nominate.
  final takesWrites = takesDateWrites(snapshot.event);
  final mayVote =
      takesWrites &&
      detail.actions.contains(EventAction.voteGame) &&
      viewerId != null;
  final hint = voteHintFor(detail, pool: pool);

  return (
    voting: mayVote
        ? (
            hint: hint == VoteHint.countsWhenOffering && !poolRead
                ? null
                : hint,
            // As the tab's other writes are (#589): not while a detail read
            // runs, or the screen's own request is out or the event is
            // deleted. The nominations' own writes are the control's to hold.
            enabled: !detail.reading && !acting,
            busy: state.busy,
          )
        : null,
    // Withdraw (#517), on the viewer's own live rows, and a host's decisions
    // (#518), on the rows they settle. As a vote is, not while a detail read
    // runs or the screen's own request is out, nor while another
    // nominations write is out.
    writes: (
      withdraw:
          takesWrites &&
          detail.actions.contains(EventAction.nominateGame) &&
          viewerId != null,
      decisions: {
        if (takesWrites)
          for (final decision in NominationDecision.values)
            if (detail.actions.contains(decision.action)) decision,
      },
      enabled: !detail.reading && !acting && !state.busy,
      busy: state.busy,
    ),
    copy: pool
        .where((game) => game.id == nomination.suppliedFromId)
        .firstOrNull,
    occurrences: snapshot.occurrences,
    interestedWeight: snapshot.policy?.interestedWeight,
    // A roster read and withheld is an empty list; one not read yet is null,
    // and withholds nothing.
    rosterShown: !(snapshot.attendees?.isEmpty ?? false),
  );
}

/// Whether [nomination] carries Withdraw (#517): the viewer, by their roster
/// row [viewerId], may withdraw ([writes]), and it is their own live
/// nomination.
bool offersWithdraw(
  EventNomination nomination,
  NominationRowWrites writes, {
  required String? viewerId,
}) =>
    writes.withdraw &&
    viewerId != null &&
    nomination.nominatedById == viewerId &&
    nomination.status.isLive;

/// The host's decisions [nomination] carries (#518): those the viewer's
/// actions hold ([writes]) that settle the status it has.
List<NominationDecision> offeredDecisions(
  EventNomination nomination,
  NominationRowWrites writes,
) => [
  for (final decision in NominationDecision.values)
    if (writes.decisions.contains(decision) &&
        nomination.status == decision.from)
      decision,
];

/// Whether [nomination] carries the button that sends [write]: Withdraw
/// ([offersWithdraw]), or one of a host's decisions ([offeredDecisions]).
bool offersNominationWrite(
  NominationWrite write,
  EventNomination nomination,
  NominationRowWrites writes, {
  required String? viewerId,
}) => write == NominationWrite.withdraw
    ? offersWithdraw(nomination, writes, viewerId: viewerId)
    : offeredDecisions(
        nomination,
        writes,
      ).any((decision) => decision.write == write);

/// The viewer's vote on [nomination] (#517), by their roster row [viewerId],
/// where [voting] says they may vote; votes are taken while it is open, and
/// only then. Null where there is none to build.
NominationVoteControl? nominationVoteControl(
  BuildContext context,
  EventNomination nomination, {
  required NominationVoting? voting,
  required String? viewerId,
}) {
  if (voting == null ||
      viewerId == null ||
      nomination.status != NominationStatus.open) {
    return null;
  }
  final vote = viewerVote(nomination, viewerId);
  return NominationVoteControl(
    nomination: nomination,
    vote: vote,
    hint: voting.hint,
    enabled: voting.enabled,
    busy: voting.busy,
    onVote: (type) => voteOnNomination(context, nomination, type),
    onEditNote: () => editVoteNote(context, nomination, note: vote?.comment),
  );
}

/// What [nomination]'s lines say, top to bottom, under its title (#517), on
/// its row and in its quick look (#957): its platform; who nominated it;
/// whose copy it is; whether it is for the whole event or one date; where it
/// stands; its tally of the votes that count, with how the event counts
/// Interested where its policy says; the viewer's vote, and whether it
/// counts, where no vote control shows it ([voteShown]); when voting
/// closes, while it is open and has a deadline; and why it is paused, while
/// it is. Read as one node by whoever builds them.
///
/// The viewer is named by their roster row [viewerId], and anyone else from
/// the roster's [names]. A deadline is a fixed time as of [now], never a
/// countdown, and past it, a line that it stays open until a host closes
/// the vote, since nothing closes it on time yet (backend#797).
List<Widget> nominationLines(
  BuildContext context,
  EventNomination nomination, {
  required NominationRowInputs inputs,
  required String? viewerId,
  required Map<String, String?> names,
  required bool voteShown,
  required DateTime now,
}) {
  final l10n = EventsLocalizations.of(context);
  final theme = Theme.of(context);
  final quiet = theme.textTheme.bodyMedium?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
  );
  final tally = tallyOf(nomination);
  final deadline = nomination.votingDeadline;
  final supplier = nominationSupplierOf(
    l10n,
    copy: inputs.copy,
    viewerId: viewerId,
    names: names,
  );
  final scope = nominationScopeName(
    context,
    nomination.occurrenceId,
    occurrences: inputs.occurrences,
    now: now,
  );
  final interested = interestedLine(l10n, inputs.interestedWeight);
  // A fixed line, not a countdown: passing it closes nothing (#517).
  final closes = deadline == null || nomination.status != NominationStatus.open
      ? null
      : deadline.isBefore(now)
      ? l10n.eventsNominationDeadlinePassed(
          eventWhenLabel(context, deadline, now: now),
        )
      : l10n.eventsNominationDeadline(
          eventWhenLabel(context, deadline, now: now),
        );
  // The server sets where it goes back to whenever it pauses one; a pause
  // without it says Unknown rather than leave a gap.
  final back = nominationStatusLabel(
    l10n,
    nomination.pausedFrom ?? NominationStatus.unknown,
  );
  final paused = nomination.status != NominationStatus.paused
      ? null
      : switch (supplier) {
          NobodyNamedSupplier() => l10n.eventsNominationPausedUnknown(back),
          ViewerSupplier() => l10n.eventsNominationPausedYours(back),
          NamedSupplier(:final name) => l10n.eventsNominationPaused(
            name,
            back,
          ),
        };
  final vote = viewerId == null ? null : viewerVote(nomination, viewerId);
  // Where there's no control to show it chosen, the viewer's vote is still
  // theirs to see (#517): on a paused or decided nomination, or once they
  // can't vote.
  final yours = voteShown || vote == null
      ? null
      : vote.eligible
      ? l10n.eventsNominationYourVote(voteTypeLabel(l10n, vote.voteType))
      : l10n.eventsNominationYourVoteNotCounting(
          voteTypeLabel(l10n, vote.voteType),
        );
  // Who nominated it: the viewer, else their name on the roster, else the
  // username the nomination carries, else "this person", as the pool names
  // someone the roster doesn't.
  final by = nomination.nominatedById;
  final nominatedBy = viewerId != null && by == viewerId
      ? l10n.eventsNominatedByYou
      : l10n.eventsNominatedBy(
          names[by] ??
              personName(username: nomination.nominatedByUsername) ??
              l10n.eventsAttendeeSomeone,
        );

  return [
    Text(nomination.platformName, style: quiet),
    Text(nominatedBy, style: quiet),
    Text(switch (supplier) {
      NobodyNamedSupplier() => l10n.eventsNominationFromUnknown,
      ViewerSupplier() => l10n.eventsNominationFromYours,
      NamedSupplier(:final name) => l10n.eventsNominationFrom(name),
    }, style: quiet),
    if (scope != null) Text(scope, style: quiet),
    Text(
      nominationStatusLabel(l10n, nomination.status),
      style: theme.textTheme.labelLarge,
    ),
    Text(
      l10n.eventsNominationTally(
        tally.forCount,
        tally.againstCount,
        tally.interestedCount,
      ),
      // The symbol between the counts would be read out.
      semanticsLabel: l10n.eventsNominationTallySpoken(
        tally.forCount,
        tally.againstCount,
        tally.interestedCount,
      ),
      style: quiet,
    ),
    if (interested != null) Text(interested, style: quiet),
    if (yours != null) Text(yours, style: quiet),
    if (closes != null) Text(closes, style: quiet),
    if (paused != null) Text(paused, style: quiet),
  ];
}

/// A write button on a nomination's row: Withdraw on one of the viewer's
/// own live nominations (#517), or a host's Approve, Reject or Close vote
/// (#518). A direct write, so disabled offline through [BgeOnlineOnly], with
/// the connection's reason as its hint. Named for its game to a screen
/// reader ([named]).
///
/// Its press opens a dialog that asks first, which hands focus back to it as
/// it closes, just before the write goes out, and a disabled button can't
/// hold focus (#607). So, as Nominate is, it is held through [HeldPress]
/// from its press until its write is over ([runOver]): enabled, ignoring
/// presses and showing a spinner, wherever it would otherwise be
/// unavailable. It is disabled with no hint while it may not be pressed for
/// a while ([enabled]).
class NominationWriteButton extends StatefulWidget {
  const NominationWriteButton({
    required this.buttonKey,
    required this.label,
    required this.named,
    required this.icon,
    required this.area,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
    required this.onPointerDown,
    super.key,
  });

  /// Key on the button itself.
  final Key buttonKey;

  /// What the button says.
  final String label;

  /// Its name to a screen reader, naming the game.
  final String named;
  final IconData icon;

  /// Holds the button, so its row can tell whether it holds focus.
  final FocusNode area;

  /// Whether it may be pressed now, connection aside: false while a detail
  /// read runs, the screen's own request is out, or a nominations write is
  /// out.
  final bool enabled;

  /// Whether no nominations write is out: once its own write went out, that
  /// is over.
  final bool runOver;

  /// Asks first, and sends the write. Completes true when it was sent, and
  /// false when nothing was.
  final Future<bool> Function() onPressed;

  /// Told the kind of each pointer pressed on it, before the press.
  final void Function(PointerDeviceKind kind) onPointerDown;

  @override
  State<NominationWriteButton> createState() => NominationWriteButtonState();
}

class NominationWriteButtonState extends State<NominationWriteButton>
    with HeldPress<NominationWriteButton> {
  @override
  bool get heldActionOver => widget.runOver;

  @override
  Widget build(BuildContext context) {
    final offline = BgeConnectivityScope.offlineOf(context);
    final available = widget.enabled && !offline;
    // Offline it is disabled, pressed or not: no press made it so (#49).
    final inert = heldInert(available: available, disabled: offline);

    return Focus(
      focusNode: widget.area,
      includeSemantics: false,
      child: Listener(
        onPointerDown: (event) => widget.onPointerDown(event.kind),
        child: BgeOnlineOnly(
          showNote: false,
          child: BgeInertButton(
            inert: inert,
            label: widget.named,
            onPressed: available || inert
                ? () => unawaited(holdPress(widget.onPressed))
                : null,
            builder: (context, focusNode, onPressed) => TextButton.icon(
              key: widget.buttonKey,
              focusNode: focusNode,
              onPressed: onPressed,
              icon: inert ? const HeldSpinner() : Icon(widget.icon),
              label: Text(widget.label),
            ),
          ),
        ),
      ),
    );
  }
}

/// Withdraws the viewer's own [nomination] once they confirm it, and once
/// any running detail read has ended (#517). Completes true when the
/// withdrawal was sent, and false when nothing was: Keep it, or as below.
///
/// It asks first, as a destructive action: the nomination's votes are lost,
/// and nominating the game again starts from none. Then it goes for the
/// event as the detail shows it then, whose id a reconcile can have moved
/// (#499), and for the nomination as the nominations' state holds it then.
/// Nothing is sent if, by then, the event takes no writes (cancelled or
/// archived), the viewer may no longer nominate, or the nomination is gone,
/// isn't theirs, or is no longer live: the page already shows that, and the
/// footer says the withdrawal was dropped, or a screen reader would hear
/// nothing happen.
Future<bool> withdrawNomination(
  BuildContext context,
  EventNomination nomination,
) async {
  // Read before the dialog opens: the row under it can rebuild without
  // Withdraw, and take this context with it.
  final l10n = EventsLocalizations.of(context);
  final detail = context.read<EventDetailBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final title = nomination.title;
  final confirmed = await showConfirmDialog(
    context,
    title: l10n.eventsWithdrawConfirmTitle(title),
    body: l10n.eventsWithdrawConfirmBody,
    keepLabel: l10n.eventsWithdrawConfirmKeep,
    confirmLabel: l10n.eventsWithdrawConfirm,
    destructive: true,
    keepKey: EventDetailScreen.withdrawKeepKey,
    confirmKey: EventDetailScreen.withdrawConfirmKey,
  );
  if (!confirmed || nominations.isClosed) return false;

  final state = await readEnded(detail);
  if (state is! EventDetailReady || nominations.isClosed) return false;
  final viewer = state.detail.attendance;
  final current = nominations.state.nominations
      .where((shown) => shown.id == nomination.id)
      .firstOrNull;
  if (!takesDateWrites(state.detail.snapshot.event) ||
      !state.actions.contains(EventAction.nominateGame) ||
      viewer == null ||
      current == null ||
      current.nominatedById != viewer.id ||
      !current.status.isLive) {
    nominations.add(
      NominationWriteDropped(NominationWrite.withdraw, title: title),
    );
    return false;
  }
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  nominations.add(
    NominationWithdrawn(state.detail.snapshot.event.id, current),
  );
  return true;
}

/// Sends a host's [decision] on [nomination] once they confirm it, and once
/// any running detail read has ended, and for a close of the vote any
/// running nominations read too ([nominationsReadEnded]) (#518). Completes
/// true when it was sent, and false when nothing was: Not yet, or as below.
///
/// None of the three can be undone while nothing takes a game out of the
/// lineup (#520), so each asks first: a rejection as a destructive action,
/// and a close of the vote with [nomination]'s tally of the votes that count
/// so far (#517), which is what it settles, and how the event counts
/// Interested, from [interestedWeight], as the row says it. Then it goes for
/// the event as the detail shows it then, whose id a reconcile can have
/// moved (#499), and for the nomination as the nominations' state holds it
/// then. Nothing is sent if, by then, the event takes no writes (cancelled
/// or archived), the viewer's actions no longer hold the decision, or the
/// nomination is gone or no longer has the status it decides from, or, for a
/// close of the vote, its tally or how the event counts Interested isn't
/// what the dialog showed, as a read while it was open can find (the request
/// carries neither, so the server would settle on what it holds then): the
/// page already shows that, and the footer
/// says the decision was dropped, or a screen reader would hear nothing
/// happen. A host closes the vote on the counts they saw, or presses again.
Future<bool> decideNomination(
  BuildContext context,
  EventNomination nomination,
  NominationDecision decision, {
  required InterestedWeight? interestedWeight,
}) async {
  // Read before the dialog opens: the row under it can rebuild without the
  // button, and take this context with it.
  final l10n = EventsLocalizations.of(context);
  final detail = context.read<EventDetailBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final title = nomination.title;
  final tally = tallyOf(nomination);
  final interested = interestedLine(l10n, interestedWeight);
  final confirmed = await showConfirmDialog(
    context,
    title: decision.confirmTitle(l10n, title),
    body: switch (decision) {
      NominationDecision.approve => l10n.eventsApproveConfirmBody,
      NominationDecision.reject => l10n.eventsRejectConfirmBody,
      NominationDecision.resolve when interested != null =>
        l10n.eventsCloseVoteConfirmBodyInterested(
          tally.forCount,
          tally.againstCount,
          tally.interestedCount,
          interested,
        ),
      NominationDecision.resolve => l10n.eventsCloseVoteConfirmBody(
        tally.forCount,
        tally.againstCount,
        tally.interestedCount,
      ),
    },
    keepLabel: l10n.eventsHostDecisionKeep,
    confirmLabel: decision.confirmLabel(l10n),
    destructive: decision == NominationDecision.reject,
    keepKey: EventDetailScreen.hostDecisionKeepKey,
    confirmKey: EventDetailScreen.hostDecisionConfirmKey,
  );
  if (!confirmed || nominations.isClosed) return false;

  var state = await readEnded(detail);
  if (decision == NominationDecision.resolve) {
    await nominationsReadEnded(nominations);
    // The detail can have read again while the nominations did.
    state = await readEnded(detail);
  }
  if (state is! EventDetailReady || nominations.isClosed) return false;
  final current = nominations.state.nominations
      .where((shown) => shown.id == nomination.id)
      .firstOrNull;
  if (!takesDateWrites(state.detail.snapshot.event) ||
      !state.actions.contains(decision.action) ||
      current == null ||
      current.status != decision.from ||
      (decision == NominationDecision.resolve &&
          (tallyOf(current) != tally ||
              state.detail.snapshot.policy?.interestedWeight !=
                  interestedWeight))) {
    nominations.add(NominationWriteDropped(decision.write, title: title));
    return false;
  }
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  final eventId = state.detail.snapshot.event.id;
  nominations.add(switch (decision) {
    NominationDecision.approve => NominationApproved(eventId, current),
    NominationDecision.reject => NominationRejected(eventId, current),
    NominationDecision.resolve => NominationResolved(eventId, current),
  });
  return true;
}

/// Completes once no read of [nominations] is out, or at once when none
/// is. A close of the vote waits on it (#518): a read out at the confirm
/// can be bringing a tally the host never saw, and its answer landing after
/// the resolve went would come too late to stop it. It narrows the gap but
/// can't close it: a vote the server takes after the last read is seen by no
/// read, and the request carries no tally for the server to check. The
/// footer then says the counts the server settled on.
Future<void> nominationsReadEnded(EventNominationsBloc nominations) {
  bool ended(EventNominationsState state) =>
      state.load != EventNominationsLoad.loading;

  if (ended(nominations.state)) return Future.value();
  return nominations.stream.firstWhere(ended, orElse: () => nominations.state);
}

/// How the event counts an Interested vote, as a row says it under its
/// tally and Close vote's dialog says it (#517, #518), or null where the
/// policy isn't known or its weight is one this client can't name.
String? interestedLine(
  EventsLocalizations l10n,
  InterestedWeight? weight,
) => switch (weight) {
  InterestedWeight.asFor => l10n.eventsNominationInterestedAsFor,
  InterestedWeight.asAgainst => l10n.eventsNominationInterestedAsAgainst,
  InterestedWeight.asAbstain => l10n.eventsNominationInterestedNotCounted,
  InterestedWeight.unknown || null => null,
};

/// The viewer's vote on [nomination], by their roster row [viewerId], or
/// null before they have voted.
EventNominationVote? viewerVote(EventNomination nomination, String viewerId) =>
    nomination.votes.where((vote) => vote.attendeeId == viewerId).firstOrNull;

/// Sends the viewer's vote of [type] on [nomination] ([sendVote]).
/// Completes true when it was sent.
Future<bool> voteOnNomination(
  BuildContext context,
  EventNomination nomination,
  VoteType type,
) => sendVote(
  context.read<EventDetailBloc>(),
  context.read<EventNominationsBloc>(),
  nomination,
  type: type,
);

/// Asks for the note on the viewer's vote on [nomination], with [note], the
/// one it has, in the field, and sends it with that vote ([sendVote]).
/// Completes true when it was sent: false when the dialog was cancelled, or
/// as [sendVote] has it.
Future<bool> editVoteNote(
  BuildContext context,
  EventNomination nomination, {
  String? note,
}) async {
  // Read before the dialog opens: the row under it can rebuild without the
  // control, and take this context with it.
  final detail = context.read<EventDetailBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final written = await showNominationNoteDialog(
    context,
    title: nomination.title,
    note: note,
  );
  if (written == null || nominations.isClosed) return false;
  return sendVote(detail, nominations, nomination, comment: written);
}

/// Sends the viewer's vote on [nomination] once any running detail read of
/// [detail] has ended (#517): of [type], or, with none, of the type of the
/// vote they have, with [comment] where they wrote a note. Completes true
/// when it was added to [nominations].
///
/// It goes for the event as the detail shows it then, whose id a reconcile
/// can have moved (#499), and for the nomination as [nominations] holds it
/// then. Nothing is sent if, by then, the event takes no writes (cancelled
/// or archived), the viewer may no longer vote, or the nomination is gone or
/// no longer open, or a note has no vote to go with: the page shows that
/// already, and the footer says the vote was dropped, or a screen reader
/// would hear nothing happen. A note the same as the one the vote has sends
/// nothing, and says nothing.
Future<bool> sendVote(
  EventDetailBloc detail,
  EventNominationsBloc nominations,
  EventNomination nomination, {
  VoteType? type,
  String? comment,
}) async {
  final state = await readEnded(detail);
  if (state is! EventDetailReady || nominations.isClosed) return false;

  final viewer = state.detail.attendance;
  final current = nominations.state.nominations
      .where((shown) => shown.id == nomination.id)
      .firstOrNull;
  final own = viewer == null || current == null
      ? null
      : viewerVote(current, viewer.id);
  final voteType = type ?? own?.voteType;
  if (!takesDateWrites(state.detail.snapshot.event) ||
      !state.actions.contains(EventAction.voteGame) ||
      viewer == null ||
      current == null ||
      current.status != NominationStatus.open ||
      voteType == null ||
      voteType == VoteType.unknown) {
    nominations.add(
      NominationWriteDropped(NominationWrite.vote, title: nomination.title),
    );
    return false;
  }
  // Nothing to send and nothing to say: the note the vote already has.
  if (comment != null && comment == (own?.comment ?? '')) return false;
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  nominations.add(
    NominationVoteCast(
      state.detail.snapshot.event.id,
      current,
      voteType,
      comment: comment,
    ),
  );
  return true;
}

/// *Who voted ({count})* on a row with votes (#517), or in its quick look
/// (#957): opens [showNominationVoters], and puts focus back on itself once
/// it has closed, however it was opened, since a screen reader's tap moves
/// no focus. Named for its game to a screen reader.
class WhoVotedButton extends StatefulWidget {
  const WhoVotedButton({
    required this.nomination,
    required this.names,
    required this.rosterShown,
    required this.viewerId,
    this.buttonKey,
    super.key,
  });

  /// Key on the button itself: the row's
  /// ([EventDetailScreen.nominationVotersKey]) where null.
  final Key? buttonKey;

  final EventNomination nomination;
  final Map<String, String?> names;
  final bool rosterShown;
  final String? viewerId;

  @override
  State<WhoVotedButton> createState() => WhoVotedButtonState();
}

class WhoVotedButtonState extends State<WhoVotedButton> {
  final FocusNode _focus = FocusNode(debugLabel: 'Who voted');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    await showNominationVoters(
      context,
      widget.nomination,
      names: widget.names,
      rosterShown: widget.rosterShown,
      viewerId: widget.viewerId,
    );
    if (mounted && _focus.context != null) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final nomination = widget.nomination;
    // Every vote, those that don't count included: the list marks them.
    final count = nomination.votes.length;

    return TextButton.icon(
      key:
          widget.buttonKey ??
          EventDetailScreen.nominationVotersKey(nomination.id),
      focusNode: _focus,
      onPressed: () => unawaited(_open()),
      icon: const Icon(Icons.how_to_vote_outlined),
      label: Text(
        l10n.eventsVotersOpen(count),
        semanticsLabel: l10n.eventsVotersOpenNamed(count, nomination.title),
      ),
    );
  }
}

/// Who brings a nominated copy: someone named, the viewer, or nobody the
/// pool can name.
sealed class NominationSupplier {
  const NominationSupplier();
}

/// Someone other than the viewer.
final class NamedSupplier extends NominationSupplier {
  const NamedSupplier(this.name);

  /// Their name on the roster, or "this person".
  final String name;
}

/// The viewer.
final class ViewerSupplier extends NominationSupplier {
  const ViewerSupplier();
}

/// Nobody the pool can name: it no longer holds the row.
final class NobodyNamedSupplier extends NominationSupplier {
  const NobodyNamedSupplier();
}

/// Whose copy it is, from the pool row it was nominated from (#517): [copy],
/// by [viewerId], the viewer's roster row id, and [names], the roster's names.
NominationSupplier nominationSupplierOf(
  EventsLocalizations l10n, {
  required OfferedGame? copy,
  required String? viewerId,
  required Map<String, String?> names,
}) {
  if (copy == null) return const NobodyNamedSupplier();
  if (viewerId != null && copy.attendeeId == viewerId) {
    return const ViewerSupplier();
  }
  return NamedSupplier(names[copy.attendeeId] ?? l10n.eventsAttendeeSomeone);
}

/// What a nomination for the date [occurrenceId] is for, as its row names
/// it (#517): the whole event where it is null, else the date it names, by
/// [occurrences] as of [now]. Null for a date the event no longer has,
/// rather than name one it doesn't. An offered copy's quick look names what
/// the copy supplies the same way (#957).
String? nominationScopeName(
  BuildContext context,
  String? occurrenceId, {
  required List<EventOccurrence> occurrences,
  required DateTime now,
}) {
  final l10n = EventsLocalizations.of(context);
  if (occurrenceId == null) return l10n.eventsNominationWholeEvent;
  final date = occurrences.where((each) => each.id == occurrenceId).firstOrNull;
  if (date == null) return null;
  return l10n.eventsNominationForDate(eventDateName(context, date, now: now));
}

/// Where a nomination stands, as its row says it. Unlike the event's own
/// labels, an unknown status has one: a paused row names the status it goes
/// back to, and needs a word for one this client can't read.
String nominationStatusLabel(
  EventsLocalizations l10n,
  NominationStatus status,
) => switch (status) {
  NominationStatus.open => l10n.eventsNominationStatusVoting,
  NominationStatus.awaitingApproval =>
    l10n.eventsNominationStatusAwaitingApproval,
  NominationStatus.approved => l10n.eventsNominationStatusApproved,
  NominationStatus.passed => l10n.eventsNominationStatusPassed,
  NominationStatus.failed => l10n.eventsNominationStatusFailed,
  NominationStatus.quorumNotMet => l10n.eventsNominationStatusQuorumNotMet,
  NominationStatus.rejected => l10n.eventsNominationStatusRejected,
  NominationStatus.withdrawn => l10n.eventsNominationStatusWithdrawn,
  NominationStatus.paused => l10n.eventsNominationStatusPaused,
  NominationStatus.unknown => l10n.eventsNominationStatusUnknown,
};
