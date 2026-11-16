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

/// *Who voted ({count})* on a row with votes (#517): opens
/// [showNominationVoters], and puts focus back on itself once it has closed,
/// however it was opened, since a screen reader's tap moves no focus. Named
/// for its game to a screen reader.
class WhoVotedButton extends StatefulWidget {
  const WhoVotedButton({
    required this.nomination,
    required this.names,
    required this.rosterShown,
    required this.viewerId,
    super.key,
  });

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
      key: EventDetailScreen.nominationVotersKey(nomination.id),
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
