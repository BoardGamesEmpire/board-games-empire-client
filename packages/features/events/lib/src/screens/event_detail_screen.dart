import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_actions_bloc.dart';
import 'package:events/src/bloc/event_actions_event.dart';
import 'package:events/src/bloc/event_actions_state.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_event.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/bloc/event_poll_bloc.dart';
import 'package:events/src/bloc/event_poll_event.dart';
import 'package:events/src/bloc/event_poll_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_attendee_addition.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_game_offers.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/detail/event_poll.dart';
import 'package:events/src/detail/event_status_now.dart';
import 'package:events/src/widgets/cancel_reason_dialog.dart';
import 'package:events/src/widgets/confirm_dialog.dart';
import 'package:events/src/widgets/destructive_button_style.dart';
import 'package:events/src/widgets/event_date_dialogs.dart';
import 'package:events/src/widgets/event_date_poll.dart';
import 'package:events/src/widgets/event_detail_sections.dart';
import 'package:events/src/widgets/event_detail_tabs.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:events/src/widgets/event_rsvp_controls.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/rsvp_note_dialog.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One event (#498): its header, its dates and who's coming, read reactively
/// from the local cache and from the server once per open, and a tab for its
/// games (#516).
///
/// The household detail's shape: the caller resolves the repository, the
/// optional server and streams and the callbacks, and the screen owns its
/// blocs: the detail's ([EventDetailBloc], whose class doc has the state
/// table) and, where Delete can be offered, the actions'
/// ([EventActionsBloc]), the poll's ([EventPollBloc]), the games pool's
/// ([EventGamesBloc]) and the nominations' ([EventNominationsBloc], #517).
/// Loading, not found and error are short centred pages.
/// Ready is one scroll view of slivers ([BgePage.slivers]).
///
/// ## The page and its tabs
///
/// What answers the whole screen comes first, in the page's header: the
/// couldn't-refresh banner, where the last read failed and while its retry
/// runs, then how the last action and the last vote went. The header stays in
/// the semantics tree however far down the page is scrolled, so a banner that
/// lands while the user is far down the roster is heard as it arrives
/// ([BgePage.header] says how, per platform). An outcome banner also scrolls
/// itself into view as it arrives, which takes the page from wherever the
/// user was; the refresh banner doesn't.
///
/// Under it, where the screen has its actions' blocs and the event is one the
/// server knows, a bar of two tabs (#516): Details, with the event's header,
/// its dates and who's coming, and Games, for the games the people coming
/// offer to bring. An event made offline has nothing on the server to offer
/// games to, and a screen with no server or no way back has no games bloc,
/// so both show Details alone, with no bar. Choosing a tab swaps what is
/// under the bar and keeps the bar, so focus stays on the tab chosen. The
/// selected tab is held above the detail's builder, so no read, write or
/// clock tick sets it back. It isn't in the route: the screen opens on
/// Details.
///
/// ## Which actions it offers
///
/// The bloc works out what the viewer may do, and the screen offers it to a
/// viewer the role table gives it: the app bar's menu has the event's status
/// changes (#502) and Delete (#501), the dates have their own (#506), a
/// poll's dates their answers (#507), who's coming has the viewer's own
/// answer to the invitation (#508) and adding people, someone else's answer
/// and removal (#510), and the Games tab has offering a game and taking it
/// back (#516). It offers no editing of the event (#500) and nothing on a
/// nominated game (#518), which the role table names.
///
/// ## The Games tab
///
/// The games the attendees offer to bring, one row per offered copy, with a
/// title search, a filter by person, and Take back on the viewer's own rows
/// ([EventGamesTab], #516). The pool isn't cached: the [EventGamesBloc] holds
/// what was read last.
///
/// It is read the first time the tab shows on a ready event, or, where a read
/// of the event is running then, once that read ends, and so once; and again
/// each time a read of the event ends once the tab has shown, for the event
/// and the roster the detail shows then ([poolAttendeeIds]); and, once the
/// tab has shown, whenever those ids come to differ from the ids it was last
/// read for, as when the roster a read wrote reaches the screen after the
/// read has ended. Never before the tab is opened, and never for ids that
/// are the same or for none. The viewer's own writes read it as they end: a
/// run of offers, however it ended, and a take-back unless it failed, which
/// changed nothing. A write the screen's re-check dropped reads nothing, and
/// Try again, on the failed state and on the stale-data banner, reads it as
/// the user asks. With nobody to read it for, nothing is read: where the roster
/// was read and withheld, the tab says the games aren't shown; where it
/// hasn't been read, as for an event cached from the list, the tab waits for
/// the event's read to bring it, and says it couldn't load the games if that
/// read fails, with Try again reading the event. A read that finds the
/// event gone reads the event again, as the poll's does.
///
/// The nominations (#517) aren't cached either: the [EventNominationsBloc]
/// holds what was read last. They are read when the pool is: the first time
/// the tab shows on a ready event, or once a read of the event running then
/// ends, and again each time a read of the event ends once the tab has
/// shown, for the event the detail shows then. They need no roster, so
/// they are read where it is withheld or not read yet too, and a roster
/// that changes reads nothing. The viewer's own writes change their rows
/// through the writes' answers, and the stale-data banner's Try again reads
/// them as the user asks. A read that finds the event gone reads the event
/// again, as the pool's does. They show above the pool, in the tab's
/// Nominations section, in every state of the pool: a first read that fails
/// says so there, with Try again, and one that fails over nominations read
/// before leaves them, for the footer's stale-data banner to say.
///
/// The page's footer holds what answers the lists: how far a run of offers
/// has got while it is out, or how the pool's last write went, a run of
/// offers or a take-back, then how the viewer's last nominations write went,
/// a nominate, a vote or a withdrawal, each with its own Dismiss, on either
/// tab, since a run can outlast the stay on Games; then, while Games is
/// selected, the stale-data banners, the pool's and the nominations', while
/// what each shows may be out of date. There each is on screen and heard
/// however far down the list the user is; what answers the whole screen
/// stays in the header.
///
/// *Offer games* is built where [onOfferGames] is given, the role table gives
/// the viewer `offerGame`, they have a row on the roster and the event takes
/// writes (`offerGamesGate`). It sits at the head of the tab, so it is there
/// in every state of the tab but the wait for a first answer and the games
/// being hidden. Where the viewer has answered Not going it is disabled,
/// saying why, and offline it is disabled, each throughout, its own run
/// included. It is disabled too while a read of the event runs, while the
/// screen's own request is out and while another of the pool's writes is,
/// except through the run its own press sent (below). Take back
/// is built wherever the gate isn't hidden, so a viewer who answered Not
/// going still has it, and it needs no [onOfferGames].
///
/// Offer games opens the page of the viewer's collection through
/// [onOfferGames], which shows the games the viewer already offers as
/// checked and disabled, so none is picked twice, and sends the games picked
/// there once it closes, one at a time, as Add people sends its add: once a
/// running read of the event has ended, for the event, the viewer's row and
/// the roster as the detail shows them then, and not at all if the viewer
/// may no longer offer games, or has answered Not going meanwhile, which the
/// footer says. Take back is sent once a running read of the event has
/// ended too, and only if the viewer may still take games back and the game
/// is still theirs and in the pool; answering Not going doesn't stop it.
///
/// The Offer games button keeps its focus through the run it sent, which the
/// page hands it back as it closes (#607). While the run is out it stays
/// enabled, ignores presses and says it is offering. Once the run ends it is
/// available again, through the pool's read that follows it too, unless a
/// read of the event or the screen's own request holds it back as it does any
/// control.
///
/// ## Delete
///
/// An [EventActionsBloc] beside the detail's sends it (#501), straight to the
/// server, after a dialog that says it can't be undone and that nobody on the
/// event is told. It is offered only with a [remote] and an [onBack]: the
/// delete is never queued, and once the event is gone a screen that can't
/// leave has nowhere to go. The status changes, the dates' actions, the
/// viewer's answer and the roster's writes share the bloc, so they are
/// offered only there too. Where the menu offers Cancel, the dialog offers
/// *Cancel event instead*, which closes it and opens Cancel's (#502): a
/// cancel tells everyone and keeps the event.
///
/// Delete waits for the detail read, and the refresh banner's retry waits
/// for the delete: a read's answer landing after the delete would cache the
/// event again. A read that starts while the dialog is open holds the
/// delete back until it ends, and the delete is then sent if the event is
/// still there to delete. Done leaves with a snackbar, and the page holds its
/// last frame while the route leaves, since the removal's null would otherwise
/// draw not found under the exit. A done that lands under another route
/// stays, and falls to not found for the user to find on their way back.
/// Gone, refused and failed each show a
/// banner over the event, and the screen reads the event again where
/// [EventActionOutcome.rereads] says to.
///
/// ## The event's status
///
/// The menu offers Cancel or Reopen, then Archive or Unarchive, by the
/// status worked out from the dates as the page builds and by what the
/// viewer's role holds (#502): Cancel until the event is cancelled or
/// archived, Reopen once it is cancelled, Archive once it is cancelled or
/// has ended, and Unarchive once it is archived, which offers nothing else
/// until it is unarchived. Each goes straight to the server, so it waits
/// for a connection, for a running read and for a request already out, as
/// Delete does, disabled in the menu meanwhile.
///
/// Cancel asks for an optional reason, and Reopen asks first, since both
/// tell everyone on the event. Archive and Unarchive tell nobody and undo
/// each other in one tap, so they go at once. Each is sent once a read
/// that started meanwhile has ended, with the id the detail shows then,
/// and only if the menu would still offer it then: a sync can have changed
/// the status or the viewer's role while a dialog was open, and a date can
/// have ended. Every end shows a banner, done included, and is read again
/// as [EventActionOutcome.rereads] says. None leaves the screen: an
/// archived event stays, and offers Unarchive.
///
/// ## Dates
///
/// Each date has a menu of what its status and the viewer's role allow, and
/// *Add a date* sits under the dates where the event takes another (#506).
/// Each choice opens its dialog. If a read started while it was open, the
/// request waits for that read to end, as Delete's does, since the read's
/// answer landing after the write would put the date back as it was
/// (#589). Dropped, an add or edit would take what the user typed with it.
/// It is sent with the id of the event the screen shows then, and not at
/// all if that event was cancelled or archived meanwhile, which the server
/// would still let a date be edited or removed on (backend#956), or if the
/// viewer's role no longer allows it, which for a confirm, decline or
/// cancel the server doesn't check (backend#979). Nor if the date no longer
/// offers it then, as one that passed while its confirm's dialog was open,
/// which the server would still confirm (backend#1005, #655). Removing a
/// Confirmed date asks once, and is a cancel and then a remove (#446).
///
/// Every end shows a banner, done included, since the screen stays, and
/// each is read again as [EventActionOutcome.rereads] says: the server
/// derives the event's status from its dates.
///
/// On a poll, Confirm offers to decline the other proposed dates in the
/// same step (#507). The dates declined are the others proposed as the
/// event stands once the confirm is sent.
///
/// ## The poll
///
/// On a poll with a proposed date, each proposed date shows the viewer's
/// answer, its tallies, the leader's mark and how many haven't answered,
/// from an [EventPollBloc] beside the actions' (#507). The summary isn't
/// cached, so it is read when the poll first shows and again each time a
/// detail read ends, for the event the detail shows then and only while
/// it still shows a poll the server knows. Offline, the dates show from
/// the cache and the poll says it couldn't load, with a retry.
///
/// A vote goes out at once, and waits for no read: no read can overwrite
/// it, so the chips stay enabled while one runs, and a keyboard user on one
/// keeps their place. They wait for a date write or Delete, as the dates'
/// menus do, and for the viewer's own answers to be read. A vote's end other
/// than done shows a banner of its own, and reads the event again where
/// [EventActionOutcome.rereads] says to: a date no longer open for answers
/// has been confirmed, declined or cancelled meanwhile. A poll read that
/// finds the event gone reads it again too, since nothing else would tell
/// the screen. Either read waits for a running read to end, whose answer may
/// predate what the vote or the poll found, and for a date write or Delete
/// (#589), and isn't made once the event is deleted (#501). *Who answered*
/// opens a page of everyone's answers, through [onWhoAnswered], where the
/// roster can be read.
///
/// ## Your answer
///
/// Who's coming offers the viewer Going, Maybe and Not going, and a note to
/// go with their answer, where the role table gives them `rsvp` and the
/// event takes date writes: not once it is cancelled or archived (#508).
/// Elsewhere their answer shows on their row, as everyone's does. The write
/// names their row on the cached roster, so an event opened before a read
/// cached one offers nothing yet. Each goes straight to the server, so it
/// waits for a connection, for a running read and for a request already
/// out, as the dates' controls do, and the control pressed keeps its focus
/// through the write and the read it starts ([EventRsvpControls]).
///
/// Going and Maybe go at once. Not going asks first, since it pauses the
/// games the viewer nominated and takes the ones they offered off the dates
/// ahead. Coming back brings the nominations back, but not the games they
/// offered. The note opens a dialog, and goes with the answer they have. If a
/// read started while a dialog was open, the write waits for it to end, as a
/// date's does, and is sent for the event and the row the detail shows then.
/// Not at all if the event was cancelled or archived meanwhile, or the viewer
/// was taken off it. Every end shows a banner, done included, and is read
/// again as [EventActionOutcome.rereads] says, which reads a poll again too:
/// whether the viewer's answers on its dates count follows their answer.
///
/// ## The roster
///
/// Each other person on who's coming that the viewer may act on has a menu
/// beside them (#510): Going, Maybe and Not going, their current answer
/// checked and disabled, then *Remove from event*. The role table decides
/// whose and which: no Remove on the host's row, and an organizer or a
/// moderator removes only those who attend. The menus show only where the
/// role table gives the viewer the roster and the event takes date writes:
/// not once it is cancelled or archived. Each item goes straight to the
/// server, so it waits for a connection, for a running read and for a
/// request already out, as the dates' do.
///
/// Remove always asks first, naming them and saying what it does to the
/// games they're bringing and to their votes. Not going asks first too, as
/// the viewer's own does. Going and Maybe go at once, and send no note, so
/// theirs stays. If a read started while a dialog was open, the write waits
/// for it to end, and is sent for the row the detail shows then. Not at all
/// if the row has left, its menu would no longer offer the write, or the
/// event was cancelled meanwhile, and the banner says the roster changed.
/// An answer the row already has sends nothing. Every end shows a banner,
/// done included, and is read again as [EventActionOutcome.rereads] says.
///
/// *Add people* sits under the viewer's own answer, where the menus would
/// show and a roster is shown to add to, and where there is a way to the
/// page ([onAddAttendee]). The page answers with one person and the role
/// they'll have, from the roles the role table lets the viewer give, and
/// the screen sends the add as it does the menus' writes, once any read has
/// ended. Not at all if the event was cancelled meanwhile, the viewer may no
/// longer give that role, or a sync put the person on the roster, which the
/// page couldn't have offered: the banner says the roster changed. The
/// button keeps its focus through the add it sent, which the page hands it
/// back as it closes, and through the read the add's end starts (#607).
///
/// ## The clock
///
/// Nothing writes to the cache as time passes, so the page is built again at
/// its next time boundary: the event's start or end, or a proposed date
/// passing (#502, #655), or an open nomination's deadline passing (#517).
/// The status line, the menu, the dates' controls and a nomination's
/// deadline line move on with the clock while the screen is open, with no
/// read.
///
/// ## Not found is an answer
///
/// The server answers 404 for an event that was deleted and for one this
/// user may no longer read, and does not say which, so neither does the
/// screen.
class EventDetailScreen extends StatelessWidget {
  const EventDetailScreen({
    required this.eventId,
    required this.repository,
    this.remote,
    this.confirmSession,
    this.households,
    this.householdRole,
    this.onBack,
    this.onWhoAnswered,
    this.onAddAttendee,
    this.onOfferGames,
    this.now,
    super.key,
  });

  /// Key on the first-read spinner.
  static const Key loadingKey = Key('event_detail.loading');

  /// Key on the not-found surface.
  static const Key notFoundKey = Key('event_detail.not_found');

  /// Key on the not-found surface's way back to the events.
  static const Key notFoundBackKey = Key('event_detail.not_found_back');

  /// Key on the failed-read surface.
  static const Key errorKey = Key('event_detail.error');

  /// Key on the failed-read surface's retry button.
  static const Key errorRetryKey = Key('event_detail.error_retry');

  /// Key on the couldn't-refresh banner.
  static const Key refreshBannerKey = Key('event_detail.refresh_banner');

  /// Key on the banner's retry button.
  static const Key refreshRetryKey = Key('event_detail.refresh_retry');

  /// Key on the dates section.
  static const Key datesKey = Key('event_detail.dates');

  /// Key on the who's-coming section.
  static const Key attendeesKey = Key('event_detail.attendees');

  /// Key on one answer's group of the who's-coming section (#508). A status
  /// this client doesn't know keys the Other answers group.
  static Key attendeeGroupKey(EventParticipationStatus status) =>
      Key('event_detail.attendees_${status.name}');

  /// Key on one of the viewer's answer chips (#508).
  static Key rsvpAnswerKey(EventParticipationStatus status) =>
      Key('event_detail.rsvp_${status.name}');

  /// Key on the viewer's *Add a note* or *Edit note* button (#508).
  static const Key rsvpNoteKey = Key('event_detail.rsvp_note');

  /// Key on the Not going dialog's confirm button (#508).
  static const Key rsvpNotGoingConfirmKey = Key(
    'event_detail.rsvp_not_going_confirm',
  );

  /// Key on the note dialog's field (#508).
  static const Key rsvpNoteFieldKey = Key('event_detail.rsvp_note_field');

  /// Key on the note dialog's Save note button (#508).
  static const Key rsvpNoteSaveKey = Key('event_detail.rsvp_note_save');

  /// Key on the menu button beside someone on the roster (#510), by their
  /// row's id.
  static Key attendeeMenuKey(String attendeeId) =>
      Key('event_detail.attendee_menu_$attendeeId');

  /// Key on one item of a roster row's menu: [item] is `going`, `maybe`,
  /// `notGoing` or `remove`.
  static Key attendeeActionKey(String attendeeId, String item) =>
      Key('event_detail.attendee_${item}_$attendeeId');

  /// Key on the remove dialog's Remove button (#510).
  static const Key attendeeRemoveConfirmKey = Key(
    'event_detail.attendee_remove_confirm',
  );

  /// Key on the Not going dialog's confirm button, when the answer is set for
  /// someone else (#510).
  static const Key attendeeNotGoingConfirmKey = Key(
    'event_detail.attendee_not_going_confirm',
  );

  /// Key on who's coming's *Add people* button (#510).
  static const Key addAttendeeKey = Key('event_detail.add_attendee');

  /// Key on the tab bar (#516), Details and Games, where the screen shows it.
  static const Key tabBarKey = Key('event_detail.tab_bar');

  /// Key on one tab of the bar (#516).
  static Key tabKey(EventDetailTab tab) => Key('event_detail.tab_${tab.name}');

  /// Key on what the Games tab shows under the bar (#516).
  static const Key gamesBodyKey = Key('event_detail.games_body');

  /// Key on the Games tab's search field (#516).
  static const Key poolSearchKey = Key('event_detail.pool_search');

  /// Key on the Games tab's People button, which opens *Whose games*.
  static const Key poolPeopleKey = Key('event_detail.pool_people');

  /// Key on the Games tab's "Not mine" chip.
  static const Key poolNotMineKey = Key('event_detail.pool_not_mine');

  /// Key on one person's chip in *Whose games*, by their roster row's id.
  static Key poolPersonKey(String attendeeId) =>
      Key('event_detail.pool_person_$attendeeId');

  /// Key on *Whose games*' switch that leaves the people chosen out.
  static const Key poolLeaveOutKey = Key('event_detail.pool_leave_out');

  /// Key on the chip under the search field for a person chosen, by their
  /// roster row's id.
  static Key poolInUseKey(String attendeeId) =>
      Key('event_detail.pool_in_use_$attendeeId');

  /// Key on one row of the pool, by the offered game's id.
  static Key poolRowKey(String offeredGameId) =>
      Key('event_detail.pool_row_$offeredGameId');

  /// Key on a row's Take back, by the offered game's id.
  static Key poolTakeBackKey(String offeredGameId) =>
      Key('event_detail.pool_take_back_$offeredGameId');

  /// Key on a row's Nominate (#517), by the offered game's id.
  static Key poolNominateKey(String offeredGameId) =>
      Key('event_detail.pool_nominate_$offeredGameId');

  /// Key on a row's "Nominated" marker (#517), by the offered game's id: the
  /// row supplies a live nomination.
  static Key poolNominatedKey(String offeredGameId) =>
      Key('event_detail.pool_nominated_$offeredGameId');

  /// Key on one choice of the nominate dialog (#517): the date's id, or
  /// null for the whole event.
  static Key nominateScopeKey(String? occurrenceId) =>
      Key('event_detail.nominate_scope_${occurrenceId ?? 'event'}');

  /// Key on the nominate dialog's Nominate button (#517).
  static const Key nominateConfirmKey = Key('event_detail.nominate_confirm');

  /// Key on the count of the games the filter keeps.
  static const Key poolCountKey = Key('event_detail.pool_count');

  /// Key on the banner in the footer saying how the pool's last write went:
  /// a run of offers, or a take-back.
  static const Key poolOutcomeKey = Key('event_detail.pool_outcome');

  /// Key on the line in the footer saying how far a run of offers has got.
  static const Key poolProgressKey = Key('event_detail.pool_progress');

  /// Key on the footer's banner saying the games shown may be out of date,
  /// after a read of the pool failed.
  static const Key poolRefreshBannerKey = Key(
    'event_detail.pool_refresh_banner',
  );

  /// Key on the retry of a pool read that failed: the failed state's, or the
  /// refresh banner's over games read before. Never both at once.
  static const Key poolRetryKey = Key('event_detail.pool_retry');

  /// Key on Clear filters, where the filter leaves no game.
  static const Key poolClearFiltersKey = Key(
    'event_detail.pool_clear_filters',
  );

  /// Key on the banner in the footer saying how the viewer's last
  /// nominations write went (#517): a nominate, a vote or a withdrawal.
  static const Key nominationsOutcomeKey = Key(
    'event_detail.nominations_outcome',
  );

  /// Key on the footer's banner saying the nominations shown may be out of
  /// date, after a read of them failed (#517).
  static const Key nominationsRefreshBannerKey = Key(
    'event_detail.nominations_refresh_banner',
  );

  /// Key on the retry of a nominations read that failed (#517): the
  /// Nominations section's failed state's, with none read before, or the
  /// footer's refresh banner's, over nominations read before. Never both at
  /// once.
  static const Key nominationsRetryKey = Key('event_detail.nominations_retry');

  /// Key on one row of the Games tab's Nominations section (#517), by the
  /// nomination's id.
  static Key nominationRowKey(String nominationId) =>
      Key('event_detail.nomination_$nominationId');

  /// Key on one choice of a nomination's vote control (#517), by the
  /// nomination's id and the vote it casts: on the choice's label, inside
  /// its segment.
  static Key nominationVoteKey(String nominationId, VoteType voteType) =>
      Key('event_detail.nomination_vote_${voteType.name}_$nominationId');

  /// Key on a nomination's *Add a note* or *Edit note* button (#517), by
  /// the nomination's id.
  static Key nominationNoteKey(String nominationId) =>
      Key('event_detail.nomination_note_$nominationId');

  /// Key on the vote's note dialog's field (#517).
  static const Key nominationNoteFieldKey = Key(
    'event_detail.nomination_note_field',
  );

  /// Key on the vote's note dialog's Save note button (#517).
  static const Key nominationNoteSaveKey = Key(
    'event_detail.nomination_note_save',
  );

  /// Key on a nomination's *Who voted* button (#517), by the nomination's
  /// id.
  static Key nominationVotersKey(String nominationId) =>
      Key('event_detail.nomination_voters_$nominationId');

  /// Key on the Games tab's Offer games button.
  static const Key offerGamesKey = Key('event_detail.offer_games');

  /// Key on the viewer's role line.
  static const Key roleKey = Key('event_detail.role');

  /// Key on the app bar's More actions button (#501).
  static const Key moreActionsKey = Key('event_detail.more_actions');

  /// Key on the menu's Delete item.
  static const Key deleteKey = Key('event_detail.delete');

  /// Key on the delete dialog's confirm button.
  static const Key deleteConfirmKey = Key('event_detail.delete_confirm');

  /// Key on the delete dialog's *Cancel event instead* (#502).
  static const Key cancelInsteadKey = Key('event_detail.cancel_instead');

  /// Key on the menu's Cancel item (#502).
  static const Key cancelKey = Key('event_detail.cancel');

  /// Key on the cancel dialog's reason field.
  static const Key cancelReasonKey = Key('event_detail.cancel_reason');

  /// Key on the cancel dialog's confirm button.
  static const Key cancelConfirmKey = Key('event_detail.cancel_confirm');

  /// Key on the menu's Reopen item (#502).
  static const Key reopenKey = Key('event_detail.reopen');

  /// Key on the reopen dialog's confirm button.
  static const Key reopenConfirmKey = Key('event_detail.reopen_confirm');

  /// Key on the menu's Archive item (#502).
  static const Key archiveKey = Key('event_detail.archive');

  /// Key on the menu's Unarchive item (#502).
  static const Key unarchiveKey = Key('event_detail.unarchive');

  /// Key on the banner saying how the last action went.
  static const Key actionOutcomeKey = Key('event_detail.action_outcome');

  /// Key on a date's menu button (#506), by the date's id.
  static Key dateMenuKey(String occurrenceId) =>
      Key('event_detail.date_menu_$occurrenceId');

  /// Key on one item of a date's menu.
  static Key dateActionKey(String occurrenceId, EventAction action) =>
      Key('event_detail.date_${action.name}_$occurrenceId');

  /// Key on the dates' *Add a date* button.
  static const Key addDateKey = Key('event_detail.add_date');

  /// Key on one of a proposed date's answer chips (#507).
  static Key pollAnswerKey(
    String occurrenceId,
    AvailabilityResponse response,
  ) => Key('event_detail.poll_${response.name}_$occurrenceId');

  /// Key on a proposed date's tallies line.
  static Key pollTalliesKey(String occurrenceId) =>
      Key('event_detail.poll_tallies_$occurrenceId');

  /// Key on a proposed date's leader mark: the leader, or tied.
  static Key pollLeaderKey(String occurrenceId) =>
      Key('event_detail.poll_leader_$occurrenceId');

  /// Key on *Confirm this date*, under the leading date.
  static Key confirmLeaderKey(String occurrenceId) =>
      Key('event_detail.confirm_leader_$occurrenceId');

  /// Key on the banner saying how the last vote went.
  static const Key pollOutcomeKey = Key('event_detail.poll_outcome');

  /// Key on the retry of a poll read that failed.
  static const Key pollRetryKey = Key('event_detail.poll_retry');

  /// Key on the dates' *Who answered* button.
  static const Key whoAnsweredKey = Key('event_detail.who_answered');

  /// Key on the Confirm dialog's *Also decline the other proposed dates*:
  /// the dialog's own key, named here beside the screen's others.
  static const Key declineOthersKey = EventDateDialogKeys.declineOthers;

  /// The event to show.
  final String eventId;

  /// The user-session event repository, which the screen's read and delete
  /// write to.
  final EventRepository repository;

  /// The per-server event client, for the read every open makes, the retry
  /// and the delete (#501). Null reads nothing and offers neither a retry nor
  /// Delete: the screen shows the cache alone.
  final EventRemoteDataSource? remote;

  /// Whether the session is still the user [repository] belongs to, asked
  /// before the read or the delete goes out and before the read's answer is
  /// written (#432). Null, as on native, is always yes.
  final Future<bool> Function()? confirmSession;

  /// The cached households, for the header's household name. Null names
  /// none, and is never waited on.
  final Stream<List<Household>>? households;

  /// The viewer's role in a household, for what they may do to its events
  /// without attending. Null gives household roles no say.
  final Future<HouseholdRole?> Function(String householdId)? householdRole;

  /// Returns to the events, with this screen's context: from the not-found
  /// state, as that surface's primary action, and after a delete (#501). The
  /// feature package doesn't know the route table. Null offers neither that
  /// button nor Delete, and the app bar's back button still leaves.
  final void Function(BuildContext context)? onBack;

  /// Opens the page of who answered the poll (#507), with this screen's
  /// context: the feature package doesn't know the route table. Null
  /// offers no *Who answered*, as does a roster that isn't read yet or isn't
  /// visible.
  final void Function(BuildContext context)? onWhoAnswered;

  /// Opens the Add people page (#510) with [AddAttendeeArgs], with this
  /// screen's context, and completes with whom it picked and their role, or
  /// null on back: the feature package doesn't know the route table. Null
  /// offers no *Add people*.
  final Future<EventAttendeeAddition?> Function(
    BuildContext context,
    AddAttendeeArgs args,
  )?
  onAddAttendee;

  /// Opens the Offer games page (#516) with [OfferGamesArgs], with this
  /// screen's context, and completes with the games picked, or null on
  /// back: the feature package doesn't know the route table. Null builds no
  /// Offer games button; Take back doesn't need it.
  final Future<List<OfferPick>?> Function(
    BuildContext context,
    OfferGamesArgs args,
  )?
  onOfferGames;

  /// The clock that decides whether a date is this year's, whether a
  /// proposed one has passed, and where the event stands as its dates pass,
  /// which picks the menu's status changes (#502, #655). Defaults to the
  /// device's.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final remote = this.remote;
    final hasActions = remote != null && onBack != null;

    return MultiBlocProvider(
      // go_router keeps this page when only the id changes; the key makes a
      // new id new blocs rather than the old event under them, as the
      // household detail's does (#466).
      key: ValueKey<String>(eventId),
      providers: [
        BlocProvider<EventDetailBloc>(
          create: (_) => EventDetailBloc(
            eventId: eventId,
            repository: repository,
            remote: remote,
            confirmSession: confirmSession,
            households: households,
            householdRole: householdRole,
          ),
        ),
        // None without a server or a way back, and then nothing offers
        // Delete, a date's actions, the poll or the Games tab, with its pool
        // and its nominations.
        if (hasActions) ...[
          BlocProvider<EventActionsBloc>(
            create: (_) => EventActionsBloc(
              repository: repository,
              remote: remote,
              confirmSession: confirmSession,
            ),
          ),
          BlocProvider<EventPollBloc>(
            create: (_) =>
                EventPollBloc(remote: remote, confirmSession: confirmSession),
          ),
          BlocProvider<EventGamesBloc>(
            create: (_) =>
                EventGamesBloc(remote: remote, confirmSession: confirmSession),
          ),
          BlocProvider<EventNominationsBloc>(
            create: (_) => EventNominationsBloc(
              remote: remote,
              confirmSession: confirmSession,
            ),
          ),
        ],
      ],
      child: _EventDetailView(
        onBack: onBack,
        onWhoAnswered: onWhoAnswered,
        onAddAttendee: onAddAttendee,
        onOfferGames: onOfferGames,
        now: now ?? DateTime.now,
        hasActions: hasActions,
      ),
    );
  }
}

class _EventDetailView extends StatelessWidget {
  const _EventDetailView({
    required this.now,
    required this.hasActions,
    this.onBack,
    this.onWhoAnswered,
    this.onAddAttendee,
    this.onOfferGames,
  });

  final DateTime Function() now;
  final void Function(BuildContext context)? onBack;
  final void Function(BuildContext context)? onWhoAnswered;
  final _OpenAddAttendee? onAddAttendee;
  final OpenOfferGames? onOfferGames;

  /// Whether an [EventActionsBloc] is provided above, which is whether the
  /// screen has a server and a way back. Looking it up where it isn't would
  /// throw.
  final bool hasActions;

  @override
  Widget build(BuildContext context) {
    final page = BlocBuilder<EventDetailBloc, EventDetailState>(
      // Once the delete is done the screen is leaving, and the route's exit
      // keeps it mounted while it goes. The removal's null would draw not
      // found under the exit, so the page holds its last frame instead.
      // Unless another route covers it, which the screen stays under.
      buildWhen: hasActions
          ? (_, _) =>
                !_deleted(context.read<EventActionsBloc>().state) ||
                _covered(context)
          : null,
      builder: (context, state) {
        // A delete done or found gone removes the event, and the screen
        // falls to not found, as after a read's 404 (#501). The detail
        // derives that from the removal's null only where its last read went
        // through: after one that failed it derives the couldn't-load page,
        // whose retry would read an event the server has just said is gone.
        if (hasActions &&
            state is! EventDetailReady &&
            _removed(context.read<EventActionsBloc>().state)) {
          return _NotFoundPage(onBack: onBack);
        }

        return switch (state) {
          EventDetailLoading() => const _LoadingPage(),
          EventDetailNotFound() => _NotFoundPage(onBack: onBack),
          EventDetailError(:final refreshing, :final canRetry) => _ErrorPage(
            refreshing: refreshing,
            canRetry: canRetry,
          ),
          EventDetailReady() => _ReadyPage(
            state: state,
            now: now,
            hasActions: hasActions,
            onWhoAnswered: onWhoAnswered,
            onAddAttendee: onAddAttendee,
            onOfferGames: onOfferGames,
          ),
        };
      },
    );
    if (!hasActions) return page;

    // The selected tab (#516), held above the detail's builder so that no
    // read, write or clock tick under it sets it back to Details. Not in the
    // route: the screen opens on Details. Under reduced motion the bar's
    // indicator moves at once; the controller keeps its tab when that
    // setting changes. Beside it, what the Games tab keeps: its filter, and
    // whether it has shown, which decides whether a detail read reads the
    // pool and the nominations.
    return DefaultTabController(
      length: EventDetailTab.values.length,
      animationDuration: BgeMotion.durationOf(
        context,
        BgeTokens.of(context).motionMedium,
      ),
      child: EventGamesTabScope(
        onFirstShown: _gamesFirstShown,
        child: _listeners(page),
      ),
    );
  }

  /// [page] under the listeners that answer the actions' and the poll's
  /// ends, read the poll, the games pool and the nominations as the detail
  /// calls for them, and answer a pool read or a nominations read that
  /// finds the event gone.
  Widget _listeners(Widget page) {
    return MultiBlocListener(
      listeners: [
        BlocListener<EventActionsBloc, EventActionsState>(
          // Only a request's end emits an outcome, and a dismissal clears it.
          listenWhen: (previous, current) =>
              current.outcome != null && current.outcome != previous.outcome,
          listener: _onOutcome,
        ),
        const BlocListener<EventDetailBloc, EventDetailState>(
          listenWhen: _pollDue,
          listener: _readPoll,
        ),
        BlocListener<EventPollBloc, EventPollState>(
          // A vote's end the bloc announces, as the actions' outcomes are.
          listenWhen: (previous, current) =>
              current.outcome != null && current.outcome != previous.outcome,
          listener: (context, state) {
            if (state.outcome?.rereads ?? false) {
              unawaited(_rereadEvent(context));
            }
          },
        ),
        BlocListener<EventPollBloc, EventPollState>(
          // The poll stays gone through its later reads, so a server that
          // answers the event but not its poll can't start a loop of them.
          listenWhen: (previous, current) =>
              previous.load != EventPollLoad.gone &&
              current.load == EventPollLoad.gone,
          listener: (context, _) => unawaited(_rereadEvent(context)),
        ),
        const BlocListener<EventDetailBloc, EventDetailState>(
          listenWhen: _detailReadEnded,
          listener: _readPoolAgain,
        ),
        const BlocListener<EventDetailBloc, EventDetailState>(
          listenWhen: _poolIdsMayHaveChanged,
          listener: _readPoolForNewIds,
        ),
        BlocListener<EventGamesBloc, EventGamesState>(
          // On the way into gone only. The read after the event's re-read
          // ends gone again as failed, never into gone, so this can't start
          // a loop of reads.
          listenWhen: (previous, current) =>
              previous.load != EventGamesLoad.gone &&
              current.load == EventGamesLoad.gone,
          listener: (context, _) => unawaited(_rereadEvent(context)),
        ),
        BlocListener<EventNominationsBloc, EventNominationsState>(
          // As the pool's: on the way into gone only, and the read after the
          // event's re-read ends a 404 again as failed, so no loop (#517).
          listenWhen: (previous, current) =>
              previous.load != EventNominationsLoad.gone &&
              current.load == EventNominationsLoad.gone,
          listener: (context, _) => unawaited(_rereadEvent(context)),
        ),
      ],
      child: page,
    );
  }

  void _onOutcome(BuildContext context, EventActionsState state) {
    final outcome = state.outcome;
    if (outcome == null) return;
    if (_deleted(state)) {
      // The messenger is the app's, so the snackbar outlives this route and
      // shows on the screen it leaves for.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(EventsLocalizations.of(context).eventsDeleted)),
      );
      // Only from the top. Busy shows nothing, so while the DELETE was out
      // the user may have pressed back, and the route stays mounted through
      // its exit, or opened another route over it. The app's way back pops
      // whichever route is on top, so either way it would pop another. A
      // covered screen stays, and shows not found once the removal lands.
      if (ModalRoute.isCurrentOf(context) ?? true) onBack!(context);
      return;
    }
    if (outcome.rereads) _retry(context);
  }
}

/// Whether [state] holds a delete the server accepted. The screen is leaving
/// then, and offers nothing that would start another request.
bool _deleted(EventActionsState state) =>
    state.outcome?.action == EventAction.delete &&
    state.outcome?.result == EventActionResult.done;

/// Whether [state] holds a delete the server accepted or found gone: either
/// way it has no live event with that id, and the event leaves the cache.
bool _removed(EventActionsState state) =>
    state.outcome?.action == EventAction.delete &&
    (state.outcome?.result == EventActionResult.done ||
        state.outcome?.result == EventActionResult.gone);

/// Whether another route is over this screen's: still in the stack, but not
/// on top. Null, with no route, is not covered.
bool _covered(BuildContext context) =>
    (ModalRoute.isActiveOf(context) ?? false) &&
    !(ModalRoute.isCurrentOf(context) ?? true);

/// Reads the event again after a vote's end that asks for it, or a poll read
/// that found the event gone (#507), or a games pool read that did (#516), or
/// a nominations read that did (#517), once no read is running and no date
/// write, status write (#502) or Delete is out, and not at all once the event
/// is removed.
///
/// A vote, a poll read, a pool read or a nominations read runs beside the
/// event's read, so it can end while one is running, whose answer may have
/// been served before what this found. The detail would drop a retry then,
/// and a poll, a pool or nominations that stay gone ask only once, so this
/// waits and reads after it.
///
/// It runs beside the actions' requests too, so it can end while one of them
/// is out. A read then could land after the write's answer and put the date
/// or the event's status back as it was (#589), or cache a deleted event
/// again (#501). The write's own end reads the event where its outcome says
/// to. Where that read is running, it began after what this found, so the
/// detail drops this one, and the running read shows the event as it is.
Future<void> _rereadEvent(BuildContext context) async {
  final actions = context.read<EventActionsBloc>();
  final detail = context.read<EventDetailBloc>();
  await readEnded(detail);
  final ended = actions.state.busy
      ? await actions.stream.firstWhere(
          (state) => !state.busy,
          orElse: () => actions.state,
        )
      : actions.state;
  // The bloc can still read as open just after its provider has gone.
  if (!context.mounted || actions.isClosed || detail.isClosed) return;
  if (_removed(ended)) return;
  detail.add(const EventDetailRetryRequested());
}

/// Whether [state] shows a poll the server can be asked about (#507): one
/// with a proposed date, on an event the server knows. An event created
/// offline has an id the server has never heard of.
bool _pollShows(EventDetailState state) {
  if (state is! EventDetailReady) return false;
  final snapshot = state.detail.snapshot;
  return !snapshot.event.isLocalOnly &&
      showsPoll(snapshot.event, snapshot.occurrences);
}

/// Whether the poll is due a read as the detail goes from [previous] to
/// [current] (#507): it has just started to show, or a detail read has just
/// ended and it still shows. A detail read can change which dates are
/// proposed, and other people's answers come in only when it is read.
bool _pollDue(EventDetailState previous, EventDetailState current) {
  if (!_pollShows(current)) return false;
  if (!_pollShows(previous)) return true;
  return previous is EventDetailReady &&
      current is EventDetailReady &&
      previous.reading &&
      !current.reading;
}

/// Reads the poll of the event [state] shows, by the id it shows then, which
/// a reconcile can move (#499). Only where it shows one.
void _readPoll(BuildContext context, EventDetailState state) {
  if (state is! EventDetailReady || !_pollShows(state)) return;
  context.read<EventPollBloc>().add(
    EventPollRequested(state.detail.snapshot.event.id),
  );
}

/// Whether a detail read has just ended as the detail goes from [previous]
/// to [current] (#516): the games pool is read again then, once the Games
/// tab has shown, since a read can change the roster whose games it holds,
/// and so are the nominations (#517), which others' writes change.
bool _detailReadEnded(EventDetailState previous, EventDetailState current) =>
    previous is EventDetailReady &&
    current is EventDetailReady &&
    previous.reading &&
    !current.reading;

/// Reads the games pool (#516) and the nominations (#517) again after the
/// detail read [state] ended with, where the Games tab has shown at least
/// once. The nominations are read whether or not there is anybody to read
/// the pool for.
void _readPoolAgain(BuildContext context, EventDetailState state) {
  final scope = EventGamesTabScope.of(context);
  if (state is! EventDetailReady || !scope.shown) return;
  _readPool(context, state, scope);
  _readNominations(context, state);
}

/// Reads the games pool (#516) and the nominations (#517) for the Games
/// tab's first showing, and answers whether it showed on a ready detail of
/// an event the server knows. Only that counts as having shown.
///
/// While a detail read is running, as the one every open starts may be,
/// neither is read here: that read's end reads both ([_readPoolAgain]), as
/// the tab has shown by then, and a roster that arrives after it reads the
/// pool for that ([_readPoolForNewIds]).
bool _gamesFirstShown(
  BuildContext context,
  EventGamesTabController controller,
) {
  final state = context.read<EventDetailBloc>().state;
  if (state is! EventDetailReady || state.detail.snapshot.event.isLocalOnly) {
    return false;
  }
  if (!state.reading) {
    _readPool(context, state, controller);
    _readNominations(context, state);
  }
  return true;
}

/// Whether [current] is a ready detail with no read running that isn't
/// the end of one (#516): where the ids to read the pool for can have
/// changed with nothing else reading it. A read's end reads it already.
bool _poolIdsMayHaveChanged(
  EventDetailState previous,
  EventDetailState current,
) =>
    current is EventDetailReady &&
    !current.reading &&
    !_detailReadEnded(previous, current);

/// Reads the games pool where the Games tab has shown and the ids to read
/// it for differ, by value and order, from the ids it was last asked for
/// (#516): as when a read of the event has ended and the roster it wrote
/// reaches the screen after it. Ids that are the same read nothing, and so
/// do none, which forgets the ids last asked for ([_readPool]).
///
/// A read of the pool changes no detail, and each request is for ids that
/// differ from the last asked, so this sends one request per change of the
/// ids and can't loop. A read already out for the old ids is followed by
/// one for these, as the bloc runs one more read for the latest request.
void _readPoolForNewIds(BuildContext context, EventDetailState state) {
  if (state is! EventDetailReady) return;
  final scope = EventGamesTabScope.of(context);
  if (!scope.shown) return;
  final ids = poolAttendeeIds(state.detail);
  if (ids.isNotEmpty && listEquals(ids, scope.requestedIds)) return;
  _readPool(context, state, scope);
}

/// Reads the games pool of the event [state] shows, for the roster it shows
/// then, by the ids it shows then, which a reconcile can move (#499), and
/// notes those ids on [controller]. Not at all with nobody to read it
/// for, or for an event the server doesn't know.
///
/// Nobody to read it for forgets the ids last asked for. The tab shows no
/// games then, so a roster that comes back, the same one included, is read
/// for again, and the games shown are never as old as its absence.
void _readPool(
  BuildContext context,
  EventDetailReady state,
  EventGamesTabController controller,
) {
  final event = state.detail.snapshot.event;
  if (event.isLocalOnly) return;
  final ids = poolAttendeeIds(state.detail);
  if (ids.isEmpty) {
    controller.requestedIds = null;
    return;
  }
  controller.requestedIds = ids;
  context.read<EventGamesBloc>().add(EventGamesRequested(event.id, ids));
}

/// Reads the nominations of the event [state] shows (#517), by the id it
/// shows then, which a reconcile can move (#499). Not for an event the
/// server doesn't know.
///
/// Unlike the pool's read, it needs no roster: the nominations are the
/// event's, so where the roster is withheld or not yet read they are read
/// all the same, and a roster that changes doesn't read them again.
void _readNominations(BuildContext context, EventDetailReady state) {
  final event = state.detail.snapshot.event;
  if (event.isLocalOnly) return;
  context.read<EventNominationsBloc>().add(EventNominationsRequested(event.id));
}

/// The event itself: one scroll view of slivers (#516). What answers the
/// whole screen, the refresh banner and the outcome banners, comes first, in
/// the page's header, then the tab bar where the screen shows one, then the
/// selected tab.
///
/// The bar shows where the screen has its actions' blocs and the event is
/// one the server knows: an event made offline has nothing on the server to
/// offer games to. Without the bar the page is Details alone, whatever the
/// controller holds.
class _ReadyPage extends StatelessWidget {
  const _ReadyPage({
    required this.state,
    required this.now,
    required this.hasActions,
    this.onWhoAnswered,
    this.onAddAttendee,
    this.onOfferGames,
  });

  /// Key on the sliver that holds the tab bar.
  static const _tabBarSliverKey = ValueKey<String>(
    'event_detail.tab_bar_sliver',
  );

  /// Key on the sliver that holds Details, so it keeps its state where the
  /// bar comes in above it, as when an event made offline reaches the
  /// server.
  static const _detailsKey = ValueKey<String>('event_detail.details');

  final EventDetailReady state;
  final DateTime Function() now;

  /// Whether an [EventActionsBloc], an [EventPollBloc], an [EventGamesBloc],
  /// an [EventNominationsBloc], the tabs' [TabController] and the Games
  /// tab's [EventGamesTabScope] are provided above.
  final bool hasActions;
  final void Function(BuildContext context)? onWhoAnswered;
  final _OpenAddAttendee? onAddAttendee;
  final OpenOfferGames? onOfferGames;

  @override
  Widget build(BuildContext context) {
    final snapshot = state.detail.snapshot;

    Widget clocked(List<EventNomination> nominations) => _ClockedPage(
      event: snapshot.event,
      occurrences: snapshot.occurrences,
      nominations: nominations,
      now: now,
      builder: _page,
    );

    if (!hasActions) return clocked(const []);
    // Built again as the nominations change, so the page moves on at the
    // next deadline among them too (#517).
    return BlocSelector<
      EventNominationsBloc,
      EventNominationsState,
      List<EventNomination>
    >(
      selector: (state) => state.nominations,
      builder: (context, nominations) => clocked(nominations),
    );
  }

  /// The page as the clock and the blocs above have it now.
  Widget _page(BuildContext context) {
    if (!hasActions) {
      return _build(context, null, null, null, null, null);
    }

    final tabs = DefaultTabController.of(context);
    final games = EventGamesTabScope.of(context);
    return BlocBuilder<EventActionsBloc, EventActionsState>(
      builder: (context, actionsState) =>
          BlocBuilder<EventPollBloc, EventPollState>(
            builder: (context, pollState) =>
                BlocBuilder<EventGamesBloc, EventGamesState>(
                  builder: (context, gamesState) =>
                      BlocBuilder<EventNominationsBloc, EventNominationsState>(
                        builder: (context, nominationsState) =>
                            ListenableBuilder(
                              // Built again as the selected tab changes,
                              // and as the Games tab's filter does.
                              listenable: Listenable.merge([tabs, games]),
                              builder: (context, _) => _build(
                                context,
                                actionsState,
                                pollState,
                                gamesState,
                                nominationsState,
                                tabs,
                              ),
                            ),
                      ),
                ),
          ),
    );
  }

  /// [actionsState], [pollState], [gamesState], [nominationsState] and
  /// [tabs] are null where there are no such blocs, and then the app bar
  /// offers no menu, no poll shows and there are no tabs.
  Widget _build(
    BuildContext context,
    EventActionsState? actionsState,
    EventPollState? pollState,
    EventGamesState? gamesState,
    EventNominationsState? nominationsState,
    TabController? tabs,
  ) {
    final l10n = EventsLocalizations.of(context);
    final snapshot = state.detail.snapshot;
    final event = snapshot.event;
    // A request on its way, or a delete done and the screen leaving.
    final acting =
        actionsState != null && (actionsState.busy || _deleted(actionsState));
    // As the event stands now, which its dates move on (#502).
    final writes = _statusWritesFor(
      eventStatusAt(event, snapshot.occurrences, now: now()),
      state.actions,
    );
    final deletes = state.actions.contains(EventAction.delete);
    // The bar shows only where there is a server that knows the event.
    final shownTabs = event.isLocalOnly ? null : tabs;
    final tab = shownTabs == null
        ? EventDetailTab.details
        : EventDetailTab.values[shownTabs.index];
    // Made once, so the rows the page counts are the rows the tab draws
    // (#517). The bar shows only with a games bloc, which the tab reads.
    final gamesTab = tab == EventDetailTab.games && gamesState != null
        ? EventGamesTab(
            key: EventDetailScreen.gamesBodyKey,
            detail: state,
            games: gamesState,
            nominations: nominationsState,
            controller: EventGamesTabScope.of(context),
            acting: acting,
            now: now,
            onOfferGames: onOfferGames,
          )
        : null;

    return BgePage.slivers(
      // The section name, not the event's: the title is the page's heading
      // below, where a long one wraps rather than being cut short.
      title: Text(l10n.eventsTitle),
      actions: [
        // Only with something in it: a menu would otherwise open on
        // nothing, as an archived event does for a viewer holding cancel
        // alone.
        if (actionsState != null && (deletes || writes.isNotEmpty))
          _ActionsMenu(
            title: event.title,
            writes: writes,
            deletes: deletes,
            now: now,
            // Not while a read runs, whose answer landing after the write
            // would cache the event as it was before (#501, #502). Nor
            // while a request is out or once the delete is done, when a
            // press would send another.
            enabled: !state.reading && !acting,
          ),
      ],
      width: BgePageWidth.pane,
      // Details holds no list. The Games tab holds the rows it shows, the
      // nominations' and the pool's, and none of either while it shows a
      // state (#516, #517).
      semanticChildCount: gamesTab?.rowCount,
      // How far a run of offers has got or how the pool's last write went
      // (#516), then how the viewer's last nominations write went (#517), on
      // either tab, then, on the Games tab, the stale-data banners: answers
      // on a long list, so on screen and heard wherever the list is
      // scrolled. A run can outlast the stay on Games, and a footer left out
      // on Details would silence its live region. Passed on every build
      // where there is a games bloc, so the page keeps one shape as the tabs
      // swap.
      footer: gamesState == null
          ? null
          : EventGamesFooter(
              state: gamesState,
              nominations: nominationsState,
              showStale: tab == EventDetailTab.games,
            ),
      // Above the tabs, and in the semantics tree however far down the page
      // is, so a banner that lands while the user is far down is heard as it
      // arrives. Passed on every build, an empty column with nothing to say,
      // so the call site keeps one shape, as the style guide's Tabs section
      // asks; an empty header adds no node and no height.
      header: _banners(context, actionsState, pollState, acting: acting),
      slivers: [
        if (shownTabs != null)
          SliverToBoxAdapter(
            key: _tabBarSliverKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EventDetailTabBar(
                  key: EventDetailScreen.tabBarKey,
                  controller: shownTabs,
                ),
                const BgeGap.lg(),
              ],
            ),
          ),
        ...switch (tab) {
          EventDetailTab.details => [
            SliverToBoxAdapter(
              key: _detailsKey,
              child: _details(
                context,
                actionsState,
                pollState,
                acting: acting,
              ),
            ),
          ],
          EventDetailTab.games => [?gamesTab],
        },
      ],
    );
  }

  /// What answers the whole screen, over every tab: the couldn't-refresh
  /// banner, then how the last action and the last vote went. An empty
  /// column where none shows. [acting] is [_build]'s.
  Widget _banners(
    BuildContext context,
    EventActionsState? actionsState,
    EventPollState? pollState, {
    required bool acting,
  }) {
    final l10n = EventsLocalizations.of(context);
    final outcome = actionsState?.outcome;
    final pollOutcome = pollState?.outcome;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.refreshFailed || state.refreshing) ...[
          BgeRefreshBanner(
            key: EventDetailScreen.refreshBannerKey,
            retryKey: EventDetailScreen.refreshRetryKey,
            failedMessage: l10n.eventsDetailRefreshFailed,
            inProgressLabel: l10n.eventsRefreshInProgress,
            retryLabel: l10n.eventsRefreshRetry,
            refreshing: state.refreshing,
            // No read while the delete is out or done: its answer could land
            // after the removal and cache the event again (#501).
            onRetry: state.canRetry && !acting ? () => _retry(context) : null,
          ),
          const BgeGap.lg(),
        ],
        // A delete's done has no banner: the screen leaves with a snackbar.
        if (actionsState != null &&
            outcome != null &&
            !_deleted(actionsState)) ...[
          _ActionOutcomeBanner(
            bannerKey: EventDetailScreen.actionOutcomeKey,
            outcome: outcome,
            onDismiss: () => context.read<EventActionsBloc>().add(
              const EventActionOutcomeDismissed(),
            ),
          ),
          const BgeGap.lg(),
        ],
        // A vote's, beside the actions': nothing holds a date write back
        // for a vote that is out, so both can end (#507).
        if (pollOutcome != null) ...[
          _ActionOutcomeBanner(
            bannerKey: EventDetailScreen.pollOutcomeKey,
            outcome: pollOutcome,
            onDismiss: () => context.read<EventPollBloc>().add(
              const EventPollOutcomeDismissed(),
            ),
          ),
          const BgeGap.lg(),
        ],
      ],
    );
  }

  /// The Details tab, and the whole page where there are no tabs: the
  /// event's header, its dates and who's coming. [acting] is [_build]'s.
  Widget _details(
    BuildContext context,
    EventActionsState? actionsState,
    EventPollState? pollState, {
    required bool acting,
  }) {
    final snapshot = state.detail.snapshot;
    final event = snapshot.event;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EventDetailHeader(
          event: event,
          occurrences: snapshot.occurrences,
          now: now,
          householdName: state.householdName,
          role: state.detail.attendance?.role,
        ),
        const BgeGap.xl(),
        _Dates(
          state: state,
          now: now,
          hasActions: actionsState != null,
          poll: pollState,
          onWhoAnswered: onWhoAnswered,
          acting: acting,
          // Not while a read runs, whose answer landing after the write
          // would put the date back as it was (#589). Nor while a request
          // is out or once the delete is done.
          enabled: !state.reading && !acting,
        ),
        const BgeGap.lg(),
        EventAttendeesSection(
          attendees: snapshot.attendees,
          controls: _rsvpControls(context, actionsState, acting: acting),
          reach: actionsState == null
              ? AttendeeReach.none
              : _rosterReach(state),
          viewerAttendeeId: state.detail.attendance?.id,
          // As the dates' controls are: not while a read runs, whose answer
          // landing after the write would put the row back as it was
          // (#589), nor while a request is out or once the delete is done.
          enabled: !state.reading && !acting,
          onAnswer: actionsState == null
              ? null
              : (row, answer) => unawaited(_answerFor(context, row, answer)),
          onRemove: actionsState == null
              ? null
              : (row) => unawaited(_removeAttendee(context, row)),
          addButton: _addButton(context, actionsState, acting: acting),
        ),
      ],
    );
  }

  /// The viewer's answer to the invitation (#508), or null where none is
  /// offered: no actions bloc, a role that doesn't answer, an event that no
  /// longer takes one, or no row of theirs on the cached roster to send it
  /// for. [acting] is [_build]'s.
  Widget? _rsvpControls(
    BuildContext context,
    EventActionsState? actionsState, {
    required bool acting,
  }) {
    final attendee = state.detail.attendance;
    if (actionsState == null ||
        attendee == null ||
        !state.actions.contains(EventAction.rsvp) ||
        !takesDateWrites(state.detail.snapshot.event)) {
      return null;
    }

    return EventRsvpControls(
      attendee: attendee,
      // Not while a read runs, whose answer landing after the write would
      // put the old answer back (#589). Nor while a request is out or once
      // the delete is done.
      enabled: !state.reading && !acting,
      busy: actionsState.busy,
      onAnswer: (status) => _sendRsvp(context, status),
      onEditNote: () => _sendRsvp(context, null, editNote: true),
    );
  }

  /// *Add people* (#510), or null where it isn't offered: no way to the
  /// page, no actions bloc, a role table that gives the viewer no roles to
  /// give, an event that no longer takes the write, or no roster shown to add
  /// to. [acting] is [_build]'s.
  Widget? _addButton(
    BuildContext context,
    EventActionsState? actionsState, {
    required bool acting,
  }) {
    final open = onAddAttendee;
    final snapshot = state.detail.snapshot;
    final roster = snapshot.attendees;
    if (open == null ||
        actionsState == null ||
        assignableEventRoles(_rosterReach(state)).isEmpty ||
        roster == null ||
        roster.isEmpty) {
      return null;
    }

    return _AddPeopleButton(
      // As the roster's menus are: not while a read runs, whose answer
      // landing after the add would leave the roster without them (#589),
      // nor while a request is out or once the delete is done.
      enabled: !state.reading && !acting,
      onPressed: () => _addAttendee(context, open),
    );
  }
}

/// *Add people* (#510). Opens the Add people page, and is held through the
/// add the page answers with, as the RSVP's note button is through its note
/// ([EventRsvpControls]).
///
/// The page hands the focus back to it as it closes, just before the add
/// goes out, and a disabled button can't hold focus (#607). So while it is
/// unavailable after its own press, through the add and the read the add's
/// end starts, it stays enabled and ignores presses, saying it is adding.
/// While it is unavailable for another reason, a read or another request,
/// it is disabled, and offline too (#49). The press is held through
/// [HeldPress], and forgotten the first time the button is built available
/// after its add went out, and as soon as the page answers with nothing to
/// send.
class _AddPeopleButton extends StatefulWidget {
  const _AddPeopleButton({required this.enabled, required this.onPressed});

  /// Whether it may be pressed now: false while a read runs, a request is
  /// out or the delete is done.
  final bool enabled;

  /// Opens the page and sends what it answers. Completes true when an add
  /// was sent, and false when nothing was.
  final Future<bool> Function() onPressed;

  @override
  State<_AddPeopleButton> createState() => _AddPeopleButtonState();
}

class _AddPeopleButtonState extends State<_AddPeopleButton>
    with HeldPress<_AddPeopleButton> {
  /// Built available after its add went out: the add and the read its
  /// outcome started have ended, or ended before a frame showed them.
  @override
  bool get heldActionOver => widget.enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    // Offline it is disabled, pressed or not: no press made it so (#49).
    final inert = heldInert(
      available: widget.enabled && !offline,
      disabled: offline,
    );
    final label = inert
        ? l10n.eventsAddAttendeeInProgress
        : l10n.eventsAddAttendee;

    return BgeOnlineOnly(
      child: BgeInertButton(
        inert: inert,
        label: label,
        onPressed: (widget.enabled && !offline) || inert
            ? () => unawaited(holdPress(widget.onPressed))
            : null,
        builder: (context, focusNode, onPressed) => TextButton.icon(
          key: EventDetailScreen.addAttendeeKey,
          focusNode: focusNode,
          onPressed: onPressed,
          icon: inert
              ? const _HeldSpinner()
              : const Icon(Icons.person_add_alt_1_outlined),
          label: Text(label),
        ),
      ),
    );
  }
}

/// The held button's icon while the add its press sent runs: scaled with the
/// label beside it, in the button's icon colour, as the RSVP note button's
/// is.
class _HeldSpinner extends StatelessWidget {
  const _HeldSpinner();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: BgeTextScale.clampedOf(context)
        .scale(BgeTokens.of(context).spaceMd),
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: IconTheme.of(context).color,
    ),
  );
}

/// How the screen opens the Add people page:
/// [EventDetailScreen.onAddAttendee].
typedef _OpenAddAttendee = Future<EventAttendeeAddition?> Function(
  BuildContext context,
  AddAttendeeArgs args,
);

/// Builds the page again at its next time boundary (#502, #655): the
/// event's start or end, or a proposed date passing ([nextDetailBoundary]),
/// or an open nomination's deadline passing, which turns its line
/// ([nextDeadlinePassing], #517).
///
/// Nothing writes to the cache as time passes, and the page reads the clock
/// only as it builds, so without this its status line, its menu and the
/// dates' controls would stay as they were while the screen is open.
///
/// The timer is set again whenever the event or its dates may have changed,
/// and each time it fires. It waits a day at most, as the overview's does: a
/// browser fires a timeout longer than about 24.8 days at once.
class _ClockedPage extends StatefulWidget {
  const _ClockedPage({
    required this.event,
    required this.occurrences,
    required this.nominations,
    required this.now,
    required this.builder,
  });

  final Event event;
  final List<EventOccurrence> occurrences;

  /// The event's nominations as last read, none where there are no blocs.
  final List<EventNomination> nominations;
  final DateTime Function() now;

  /// The page, built again each time the timer fires.
  final WidgetBuilder builder;

  @override
  State<_ClockedPage> createState() => _ClockedPageState();
}

class _ClockedPageState extends State<_ClockedPage> {
  /// The longest [_timer] waits before it is set again.
  static const _maxWait = Duration(days: 1);

  /// Fires when the page next moves on with the clock, if it will.
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(_ClockedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A read or a sync can have moved the dates, and a nominations read the
    // deadlines, and the boundary with them.
    _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    final now = widget.now();
    final boundaries = [
      ?nextDetailBoundary(widget.event, widget.occurrences, now: now),
      ?nextDeadlinePassing(widget.nominations, now: now),
    ];
    if (boundaries.isEmpty) return;
    final next = boundaries.reduce((a, b) => a.isBefore(b) ? a : b);

    // Never negative: the boundary lies after now.
    final wait = next.difference(now);
    _timer = Timer(wait < _maxWait ? wait : _maxWait, _tick);
  }

  void _tick() {
    _arm();
    // The page reads the clock again as it builds.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// The app bar's More actions menu (#501): the event's status changes the
/// viewer may make as it stands (#502), then Delete where they may delete
/// it. See [EventDetailScreen] on how each is sent.
class _ActionsMenu extends StatelessWidget {
  const _ActionsMenu({
    required this.title,
    required this.writes,
    required this.deletes,
    required this.enabled,
    required this.now,
  });

  /// The event's title, for the dialogs'.
  final String title;

  /// The status changes the menu offers, in its order ([_statusWritesFor]).
  final List<EventStatusWrite> writes;

  /// Whether the menu offers Delete.
  final bool deletes;

  /// Whether the items may be pressed now. When they may not, they stay in
  /// the menu, disabled, rather than leaving it empty.
  final bool enabled;

  /// The screen's clock, which a status change is checked against again
  /// once its dialog closes.
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    // Each is a direct write, so it waits for a connection (#49). The anchor
    // button stays enabled, so the menu can be opened to read why.
    final pressable = enabled && !BgeConnectivityScope.offlineOf(context);

    return BgeOnlineOnlyMenu(
      builder: (context, menu) => MenuAnchor(
        controller: menu,
        // Left unconstrained, the panel sits in a hard-clipped box as wide as
        // its widest entry, which at 2.0 text runs past a phone's edge. Held
        // to the screen, the entries wrap instead.
        crossAxisUnconstrained: false,
        menuChildren: [
          for (final write in writes)
            MenuItemButton(
              key: switch (write) {
                EventStatusWrite.cancel => EventDetailScreen.cancelKey,
                EventStatusWrite.reopen => EventDetailScreen.reopenKey,
                EventStatusWrite.archive => EventDetailScreen.archiveKey,
                EventStatusWrite.unarchive => EventDetailScreen.unarchiveKey,
              },
              overflowAxis: Axis.vertical,
              onPressed: pressable
                  ? () => unawaited(_writeStatus(context, write))
                  : null,
              child: BgeOnlineOnlyLabel(switch (write) {
                EventStatusWrite.cancel => l10n.eventsDetailCancel,
                EventStatusWrite.reopen => l10n.eventsDetailReopen,
                EventStatusWrite.archive => l10n.eventsDetailArchive,
                EventStatusWrite.unarchive => l10n.eventsDetailUnarchive,
              }),
            ),
          if (deletes)
            MenuItemButton(
              key: EventDetailScreen.deleteKey,
              overflowAxis: Axis.vertical,
              onPressed: pressable ? () => unawaited(_delete(context)) : null,
              child: BgeOnlineOnlyLabel(l10n.eventsDetailDelete),
            ),
        ],
        builder: (context, controller, _) => MergeSemantics(
          child: Semantics(
            expanded: controller.isOpen,
            child: IconButton(
              key: EventDetailScreen.moreActionsKey,
              icon: const Icon(Icons.more_vert),
              tooltip: l10n.eventsDetailMoreActions,
              onPressed: controller.isOpen ? controller.close : controller.open,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context) async {
    // Cancel instead runs inside ask: only Delete's dialog chooses it, and
    // that dialog opens inside ask, so the blocs are read before it opens.
    await sendDetailWrite<_DeleteChoice>(
      context,
      ask: () async {
        final choice = await _confirmDelete(context);
        if (choice == _DeleteChoice.cancelInstead && context.mounted) {
          // The delete's dialog has closed, and Cancel's opens in its place
          // (#502), to be sent as Cancel from the menu is.
          await _writeStatus(context, EventStatusWrite.cancel);
        }
        return choice == _DeleteChoice.delete ? choice : null;
      },
      // A read can have started while the dialog was open, and Delete waits
      // for it to end (#501). The id is the detail's then, not the one the
      // screen was opened on, which a reconcile can have moved (#499).
      check: (state, _) =>
          SendWrite(EventDeleteRequested(state.detail.snapshot.event.id)),
    );
  }

  /// Delete's dialog. Where the menu offers Cancel, it offers *Cancel event
  /// instead* too (#502): a cancel tells everyone on the event and keeps it,
  /// where a delete takes it from everyone and tells nobody. It has three
  /// answers, so it is built here, laid out as `showConfirmDialog` lays out
  /// its two.
  Future<_DeleteChoice> _confirmDelete(BuildContext context) async {
    final l10n = EventsLocalizations.of(context);
    final offersCancel = writes.contains(EventStatusWrite.cancel);
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (dialogContext) {
        void choose(_DeleteChoice choice) =>
            Navigator.of(dialogContext).pop(choice);

        return AlertDialog(
          // At 2.0 text a long title and the body can outgrow a phone's
          // height. Buttons that don't fit side by side stack, each as wide
          // as its label needs, up to the dialog's width.
          scrollable: true,
          title: Text(l10n.eventsDeleteConfirmTitle(title)),
          content: Text(l10n.eventsDeleteConfirmBody),
          actions: [
            TextButton(
              onPressed: () => choose(_DeleteChoice.keep),
              child: Text(l10n.eventsDeleteConfirmKeep),
            ),
            if (offersCancel)
              TextButton(
                key: EventDetailScreen.cancelInsteadKey,
                onPressed: () => choose(_DeleteChoice.cancelInstead),
                child: Text(l10n.eventsDeleteCancelInstead),
              ),
            TextButton(
              key: EventDetailScreen.deleteConfirmKey,
              style: destructiveButtonStyle(dialogContext),
              onPressed: () => choose(_DeleteChoice.delete),
              child: Text(l10n.eventsDeleteConfirm),
            ),
          ],
        );
      },
    );
    return choice ?? _DeleteChoice.keep;
  }

  /// Asks for [write] where it asks first, then sends it (#502). See
  /// [EventDetailScreen].
  Future<void> _writeStatus(
    BuildContext context,
    EventStatusWrite write,
  ) async {
    await sendDetailWrite<_StatusRequest>(
      context,
      ask: () => switch (write) {
        EventStatusWrite.cancel => _askCancel(context),
        EventStatusWrite.reopen => _askReopen(context),
        // No dialog: they tell nobody, and one tap undoes the other.
        EventStatusWrite.archive => Future.value(EventArchiveRequested.new),
        EventStatusWrite.unarchive => Future.value(EventUnarchiveRequested.new),
      },
      // A read can have started while a dialog was open, and the write waits
      // for it to end, as Delete does (#501). The event is the detail's as
      // it is then, whose id a reconcile can have moved (#499).
      check: (state, request) {
        // A sync can have changed the status or the viewer's role
        // meanwhile, or a date can have ended and moved the status on. The
        // page already shows the menu as it is then, and nothing is sent
        // that it no longer offers. Its banner says so, or a screen reader
        // would hear nothing happen, and a typed reason would go without a
        // word.
        final shown = state.detail.snapshot;
        final status = eventStatusAt(
          shown.event,
          shown.occurrences,
          now: now(),
        );
        if (!_statusWritesFor(status, state.actions).contains(write)) {
          return DropWrite(EventWriteDropped.status(write));
        }
        return SendWrite(request(shown.event.id));
      },
    );
  }

  /// Cancel's dialog, with its optional reason: null when the event is
  /// kept, else the request to send. A blank reason is sent as none.
  Future<_StatusRequest?> _askCancel(BuildContext context) async {
    final l10n = EventsLocalizations.of(context);
    final reason = await showCancelReasonDialog(
      context,
      title: l10n.eventsCancelConfirmTitle(title),
      body: l10n.eventsCancelConfirmBody,
      keepLabel: l10n.eventsCancelConfirmKeep,
      confirmLabel: l10n.eventsCancelConfirm,
      reasonKey: EventDetailScreen.cancelReasonKey,
      confirmKey: EventDetailScreen.cancelConfirmKey,
    );
    if (reason == null) return null;
    EventActionsEvent cancelRequest(String eventId) =>
        EventCancelRequested(eventId, reason: reason);
    return cancelRequest;
  }

  /// Reopen's dialog, which asks first since a reopen tells everyone on the
  /// event: null when it stays cancelled, else the request to send.
  Future<_StatusRequest?> _askReopen(BuildContext context) async {
    final l10n = EventsLocalizations.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.eventsReopenConfirmTitle(title),
      body: l10n.eventsReopenConfirmBody,
      keepLabel: l10n.eventsReopenConfirmKeep,
      confirmLabel: l10n.eventsReopenConfirm,
      confirmKey: EventDetailScreen.reopenConfirmKey,
    );
    return confirmed ? EventReopenRequested.new : null;
  }
}

/// An event status write's request, built from the id of the event as the
/// detail shows it once its dialog closes (#502).
typedef _StatusRequest = EventActionsEvent Function(String eventId);

/// How Delete's dialog closed (#502).
enum _DeleteChoice {
  /// *Keep event*, or dismissed: nothing is sent.
  keep,

  /// *Delete*.
  delete,

  /// *Cancel event instead*: Cancel's dialog opens.
  cancelInstead,
}

/// The status changes the menu offers on an event reading [status], to a
/// viewer holding [actions] (#502): Cancel or Reopen, then Archive or
/// Unarchive.
///
/// The role table gives `cancel` and `archive`, and the status picks which
/// of each pair, as the server allows them. Cancel until the event is
/// cancelled or archived, Reopen once it is cancelled. Archive once it is
/// cancelled or has ended, and Unarchive once it is archived, which offers
/// nothing else: it has to be unarchived first. An unknown status, which a
/// newer server sent, offers neither.
List<EventStatusWrite> _statusWritesFor(
  EventStatus status,
  Set<EventAction> actions,
) => [
  if (actions.contains(EventAction.cancel))
    ?switch (status) {
      EventStatus.planning ||
      EventStatus.scheduled ||
      EventStatus.ongoing ||
      EventStatus.completed => EventStatusWrite.cancel,
      EventStatus.cancelled => EventStatusWrite.reopen,
      EventStatus.archived || EventStatus.unknown => null,
    },
  if (actions.contains(EventAction.archive))
    ?switch (status) {
      EventStatus.completed ||
      EventStatus.cancelled => EventStatusWrite.archive,
      EventStatus.archived => EventStatusWrite.unarchive,
      EventStatus.planning ||
      EventStatus.scheduled ||
      EventStatus.ongoing ||
      EventStatus.unknown => null,
    },
];

/// The dates section (#498), with each date's menu and *Add a date* where
/// the viewer may use them (#506), and a poll's answers (#507). See
/// [EventDetailScreen] on how a choice is sent.
class _Dates extends StatelessWidget {
  const _Dates({
    required this.state,
    required this.now,
    required this.hasActions,
    required this.enabled,
    required this.acting,
    this.poll,
    this.onWhoAnswered,
  });

  final EventDetailReady state;
  final DateTime Function() now;

  /// Whether an [EventActionsBloc] is provided above. Without one the dates
  /// offer nothing.
  final bool hasActions;

  /// Whether the controls may be pressed now.
  final bool enabled;

  /// Whether a date write or Delete is out, or the delete is done. All that
  /// holds the poll's answers: see [EventDetailScreen].
  final bool acting;

  /// The poll's state, or null where there is no [EventPollBloc] and no
  /// poll shows.
  final EventPollState? poll;
  final void Function(BuildContext context)? onWhoAnswered;

  @override
  Widget build(BuildContext context) {
    final snapshot = state.detail.snapshot;
    final event = snapshot.event;
    return EventDatesSection(
      occurrences: snapshot.occurrences,
      schedulingMode: event.schedulingMode,
      now: now,
      actionsFor: hasActions
          ? (occurrence, at) =>
                dateActionsFor(event, occurrence, state.actions, now: at)
          : null,
      onAdd:
          hasActions && canAddDate(event, snapshot.occurrences, state.actions)
          ? () => unawaited(
              _send(context, EventAction.addDate, () => _askAdd(context)),
            )
          : null,
      onAction: hasActions
          ? (occurrence, action) => unawaited(
              _send(
                context,
                action,
                () => _ask(context, occurrence, action),
                occurrenceId: occurrence.id,
              ),
            )
          : null,
      poll: _pollView(context),
      enabled: enabled,
    );
  }

  /// The poll on the dates (#507), or null where none shows: no poll bloc,
  /// or no poll the server can be asked about, by the check the reads use.
  DatesPollView? _pollView(BuildContext context) {
    final poll = this.poll;
    if (poll == null || !_pollShows(state)) return null;

    final event = state.detail.snapshot.event;
    final onWhoAnswered = this.onWhoAnswered;
    return datesPollView(
      snapshot: state.detail.snapshot,
      viewer: state.detail.attendance,
      actions: state.actions,
      poll: poll,
      acting: acting,
      // Sent at once: no read can overwrite a vote, since the summary
      // isn't cached.
      onVote: (occurrence, response) => context.read<EventPollBloc>().add(
        EventPollVoted(event.id, occurrence.id, response),
      ),
      onRetry: () =>
          context.read<EventPollBloc>().add(EventPollRetryRequested(event.id)),
      onWhoAnswered: onWhoAnswered == null
          ? null
          : () => onWhoAnswered(context),
    );
  }

  /// Asks through [ask]'s dialog, then sends the request it answers for
  /// [action], as Delete does: on date [occurrenceId], or null for an add.
  Future<void> _send(
    BuildContext context,
    EventAction action,
    Future<_DateRequest?> Function() ask, {
    String? occurrenceId,
  }) async {
    await sendDetailWrite<_DateRequest>(
      context,
      ask: ask,
      // A read can have started while the dialog was open, and the write
      // waits for it to end (#589). The event is the detail's as it is then,
      // whose id a reconcile can have moved (#499).
      check: (state, request) {
        // A sync can have cancelled the event while the dialog was open, and
        // the server still takes an edit or a removal on a cancelled event
        // (backend#956). Or taken the action from the viewer, and the server
        // still takes a confirm, decline or cancel from an organizer
        // (backend#979). The page already shows either, without the
        // control, and its banner says the write was dropped, or a screen
        // reader would hear nothing happen (#655).
        final shown = state.detail.snapshot;
        if (!takesDateWrites(shown.event) || !state.actions.contains(action)) {
          return DropWrite(EventWriteDropped(action));
        }

        // Or the date can have passed while the dialog was open, and the
        // server still takes a confirm on a passed date (backend#1005), so
        // the clock is read again (#655). The page moved on as it passed,
        // without the control. A date that changed meanwhile is checked the
        // same way, and one gone meanwhile goes on to the server, whose
        // answer says so.
        final occurrence = occurrenceId == null
            ? null
            : shown.occurrences.where((o) => o.id == occurrenceId).firstOrNull;
        if (occurrence != null) {
          final offered = dateActionsFor(
            shown.event,
            occurrence,
            state.actions,
            now: now(),
          );
          if (!offered.contains(action)) {
            return DropWrite(EventWriteDropped(action));
          }
        }
        return SendWrite(request(shown));
      },
    );
  }

  Future<_DateRequest?> _askAdd(BuildContext context) async {
    final draft = await showAddDateDialog(context, now: now);
    if (draft == null) return null;
    // After the event's last date, as the dates stand once it is sent.
    EventActionsEvent addRequest(EventSnapshot shown) => EventDateAddRequested(
      shown.event.id,
      draft,
      sortOrder: nextSortOrder(shown.occurrences),
    );
    return addRequest;
  }

  Future<_DateRequest?> _ask(
    BuildContext context,
    EventOccurrence occurrence,
    EventAction action,
  ) async {
    final name = eventDateName(context, occurrence, now: now());
    final id = occurrence.id;

    switch (action) {
      case EventAction.editDate:
        final update = await showEditDateDialog(context, occurrence, now: now);
        if (update == null) return null;
        EventActionsEvent editRequest(EventSnapshot shown) =>
            EventDateEditRequested(shown.event.id, id, update);
        return editRequest;
      case EventAction.confirmDate:
        final confirm = await showConfirmDateDialog(
          context,
          name,
          offerDeclineOthers: _offersDeclineOthers(occurrence),
        );
        if (confirm == null) return null;
        // The others as the event stands once it is sent (#507).
        EventActionsEvent confirmRequest(EventSnapshot shown) =>
            EventDateConfirmRequested(
              shown.event.id,
              id,
              decline: confirm.declineOthers
                  ? _otherProposed(shown.occurrences, id)
                  : const [],
            );
        return confirmRequest;
      case EventAction.declineDate:
        if (!await showDeclineDateDialog(context, name)) return null;
        EventActionsEvent declineRequest(EventSnapshot shown) =>
            EventDateDeclineRequested(shown.event.id, id);
        return declineRequest;
      case EventAction.cancelDate:
        final reason = await showCancelDateDialog(
          context,
          name,
          removing: false,
        );
        if (reason == null) return null;
        EventActionsEvent cancelRequest(EventSnapshot shown) =>
            EventDateCancelRequested(shown.event.id, id, reason: reason);
        return cancelRequest;
      // The server removes a Confirmed date only once it is cancelled
      // (#446), so one dialog asks for both, and its reason goes with the
      // cancel.
      case EventAction.removeDate
          when occurrence.status == OccurrenceStatus.confirmed:
        final reason = await showCancelDateDialog(
          context,
          name,
          removing: true,
        );
        if (reason == null) return null;
        EventActionsEvent cancelAndRemoveRequest(EventSnapshot shown) =>
            EventDateRemoveRequested(
              shown.event.id,
              id,
              cancelFirst: true,
              reason: reason,
            );
        return cancelAndRemoveRequest;
      case EventAction.removeDate:
        if (!await showRemoveDateDialog(context, name)) return null;
        EventActionsEvent removeRequest(EventSnapshot shown) =>
            EventDateRemoveRequested(shown.event.id, id);
        return removeRequest;
      // A date's menu offers only the date actions above.
      case EventAction.edit:
      case EventAction.delete:
      case EventAction.cancel:
      case EventAction.archive:
      case EventAction.addDate:
      case EventAction.voteAvailability:
      case EventAction.rsvp:
      case EventAction.manageAttendees:
      case EventAction.approveGame:
      case EventAction.rejectGame:
      case EventAction.resolveNomination:
      case EventAction.offerGame:
      case EventAction.nominateGame:
      case EventAction.voteGame:
        return null;
    }
  }

  /// Whether confirming [occurrence] offers to decline the event's other
  /// proposed dates in the same step (#507): on a poll that has another, to
  /// a viewer who may decline them.
  bool _offersDeclineOthers(EventOccurrence occurrence) {
    final snapshot = state.detail.snapshot;
    return snapshot.event.schedulingMode == EventSchedulingMode.poll &&
        state.actions.contains(EventAction.declineDate) &&
        _otherProposed(snapshot.occurrences, occurrence.id).isNotEmpty;
  }
}

/// The ids of [occurrences]' proposed dates other than [id], in order.
List<String> _otherProposed(List<EventOccurrence> occurrences, String id) => [
  for (final occurrence in occurrences)
    if (occurrence.id != id && occurrence.status == OccurrenceStatus.proposed)
      occurrence.id,
];

/// A date's request, built from the event as the detail shows it once the
/// dialog closes.
typedef _DateRequest = EventActionsEvent Function(EventSnapshot shown);

/// Sends the viewer's answer [status], or with [editNote] their current
/// answer with the note its dialog asks for (#508), and answers whether it
/// sent it: not when a dialog was cancelled, the note was saved unchanged,
/// the answer is already the viewer's, the read it waited for left no event to
/// show, the write was dropped, or another request is out. The controls hold
/// the control pressed only while what it sent is out. See
/// [EventDetailScreen].
Future<bool> _sendRsvp(
  BuildContext context,
  EventParticipationStatus? status, {
  bool editNote = false,
}) {
  return sendDetailWrite<_RsvpAsked>(
    context,
    ask: () async {
      if (editNote) {
        final shown = context.read<EventDetailBloc>().state;
        final shownNote = shown is EventDetailReady
            ? shown.detail.attendance?.notes
            : null;
        final notes = await showRsvpNoteDialog(context, note: shownNote);
        if (notes == null) return null;
        return (notes: notes, shownNote: shownNote);
      }
      if (status == EventParticipationStatus.notAttending) {
        // It pauses the nominations of the games the viewer is bringing,
        // whoever made them, and takes those games off the dates ahead
        // (#823). Coming back brings the nominations back, but not the
        // games.
        final l10n = EventsLocalizations.of(context);
        final confirmed = await showConfirmDialog(
          context,
          title: l10n.eventsRsvpNotGoingTitle,
          body: l10n.eventsRsvpNotGoingBody,
          keepLabel: l10n.eventsRsvpNotGoingKeep,
          confirmLabel: l10n.eventsRsvpNotGoingConfirm,
          destructive: true,
          confirmKey: EventDetailScreen.rsvpNotGoingConfirmKey,
        );
        if (!confirmed) return null;
      }
      return (notes: null, shownNote: null);
    },
    // A read can have started while a dialog was open, and the write waits
    // for it to end, as a date's does (#589). The event and the viewer's row
    // are the detail's as they are then, whose ids a reconcile can have
    // moved (#499).
    check: (state, asked) {
      final (:notes, :shownNote) = asked;
      // A sync can have cancelled or archived the event while a dialog was
      // open, taken the viewer off it, or left their row with a role or an
      // answer this client doesn't know, which a note would go out with.
      // The page already shows that, without the controls or without the
      // note, and the banner says the write was dropped, or a screen reader
      // would hear nothing happen.
      final event = state.detail.snapshot.event;
      final attendance = state.detail.attendance;
      // A note saved as the dialog showed it, or as it stands now, sends
      // nothing, and so does the answer the viewer already gave. The server
      // takes every send as a new answer: it notifies the host that the
      // viewer answered, and an answer of Going or Not going takes a new
      // date. Saving the note the dialog opened on would also put it back
      // over one another device saved while the dialog was open.
      if (notes != null &&
          (notes == (shownNote ?? '').trim() ||
              (attendance != null &&
                  notes == (attendance.notes ?? '').trim()))) {
        return const SkipWrite();
      }
      if (status != null && status == attendance?.status) {
        return const SkipWrite();
      }
      final answer = status ?? attendance?.status;
      if (attendance == null ||
          answer == null ||
          answer == EventParticipationStatus.unknown ||
          !takesDateWrites(event) ||
          !state.actions.contains(EventAction.rsvp)) {
        return const DropWrite(EventWriteDropped(EventAction.rsvp));
      }
      return SendWrite(
        EventRsvpRequested(event.id, attendance.id, answer, notes: notes),
      );
    },
  );
}

/// What an answer's dialog asked (#508): the note typed, and the note the
/// dialog opened on, for a note's edit; neither for an answer.
typedef _RsvpAsked = ({String? notes, String? shownNote});

/// Removes [row] from the roster once its dialog is confirmed (#510). See
/// [EventDetailScreen].
Future<void> _removeAttendee(BuildContext context, EventAttendee row) async {
  await sendDetailWrite<bool>(
    context,
    ask: () async {
      // It pauses the nominations of the games they're bringing, whoever
      // made them, takes those games off the dates ahead, and their votes
      // stop counting, so it always asks, naming them (#510).
      final l10n = EventsLocalizations.of(context);
      final name = row.name ?? l10n.eventsAttendeeSomeone;
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.eventsAttendeeRemoveTitle(name),
        body: l10n.eventsAttendeeRemoveBody(name),
        keepLabel: l10n.eventsAttendeeRemoveKeep,
        confirmLabel: l10n.eventsAttendeeRemoveConfirm,
        destructive: true,
        confirmKey: EventDetailScreen.attendeeRemoveConfirmKey,
      );
      return confirmed ? true : null;
    },
    // A read can have started while the dialog was open, and the write waits
    // for it to end, as a date's does (#589). The event and the row are the
    // detail's as they are then.
    check: (state, _) {
      final shown = _actableRow(state, row.id, canRemoveAttendee);
      if (shown == null) {
        return DropWrite(
          EventWriteDropped.attendee(EventAttendeeWrite.remove, name: row.name),
        );
      }
      return SendWrite(
        EventAttendeeRemoveRequested(
          state.detail.snapshot.event.id,
          shown.id,
          name: row.name,
        ),
      );
    },
  );
}

/// Sets [row]'s answer to [status] for them (#510): Not going once its
/// dialog is confirmed, Going and Maybe at once. It sends no note, so theirs
/// stays. See [EventDetailScreen].
Future<void> _answerFor(
  BuildContext context,
  EventAttendee row,
  EventParticipationStatus status,
) async {
  await sendDetailWrite<EventParticipationStatus>(
    context,
    ask: () async {
      if (status != EventParticipationStatus.notAttending) return status;
      // As the viewer's own Not going does (#823), it pauses the
      // nominations of the games they're bringing and takes those games
      // off the dates ahead, and their votes stop counting, so it asks
      // first, naming them.
      final l10n = EventsLocalizations.of(context);
      final name = row.name ?? l10n.eventsAttendeeSomeone;
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.eventsAttendeeNotGoingTitle(name),
        body: l10n.eventsAttendeeNotGoingBody(name),
        keepLabel: l10n.eventsAttendeeNotGoingKeep,
        confirmLabel: l10n.eventsRsvpNotGoingConfirm,
        destructive: true,
        confirmKey: EventDetailScreen.attendeeNotGoingConfirmKey,
      );
      return confirmed ? status : null;
    },
    // As Remove's does, against the detail once any read has ended.
    check: (state, status) {
      // The answer they already have sends nothing, as the viewer's own
      // doesn't: the server takes every send as a new answer, and a sync
      // can have brought it while the dialog was open.
      final roster = state.detail.snapshot.attendees ?? const [];
      if (roster.any((shown) => shown.id == row.id && shown.status == status)) {
        return const SkipWrite();
      }
      final shown = _actableRow(state, row.id, canSetAnswerFor);
      if (shown == null) {
        return DropWrite(
          EventWriteDropped.attendee(EventAttendeeWrite.answer, name: row.name),
        );
      }
      return SendWrite(
        EventAttendeeAnswerRequested(
          state.detail.snapshot.event.id,
          shown.id,
          status,
          name: row.name,
        ),
      );
    },
  );
}

/// Opens the Add people page through [open] (#510), with the roles the
/// viewer may give and the people the roster holds, as the detail shows
/// them now, and adds whom it answers with. Answers whether it sent the add:
/// not when the page answered nothing, or the add was dropped. See
/// [EventDetailScreen].
Future<bool> _addAttendee(BuildContext context, _OpenAddAttendee open) =>
    sendDetailWrite<EventAttendeeAddition>(
      context,
      ask: () async {
        final shown = context.read<EventDetailBloc>().state;
        if (shown is! EventDetailReady) return null;
        // The detail can be a step ahead of the frame the button was built
        // from: a sync can have left the viewer no role to give, or cancelled
        // or archived the event, and the button is going with the next frame.
        // The page needs a role to offer.
        final roles = assignableEventRoles(_rosterReach(shown));
        if (roles.isEmpty) return null;
        return open(
          context,
          AddAttendeeArgs(
            roles: roles,
            // A guest without an account has no user id, and the page finds
            // only people with one.
            rosterUserIds: {
              for (final row
                  in shown.detail.snapshot.attendees ?? const <EventAttendee>[])
                ?row.userId,
            },
          ),
        );
      },
      // A read can have started while the page was open, and the add waits
      // for it to end, as the menus' writes do (#589). The event is the
      // detail's as it is then, whose id a reconcile can have moved (#499).
      check: (state, addition) {
        final user = addition.user;
        // What the banner calls them.
        final name = personName(
          displayName: user.displayName,
          username: user.username,
        );
        final snapshot = state.detail.snapshot;
        final roster = snapshot.attendees;
        // A sync can have cancelled or archived the event while the page was
        // open, taken the roster from the viewer, or narrowed the roles they
        // may give: the page beneath shows it, without Add people or with
        // fewer roles to give. Or a sync put the person on the roster, whom
        // the page couldn't have offered. Either way nothing is sent, and the
        // banner says the roster changed, or a screen reader would hear
        // nothing happen (#655).
        if (!assignableEventRoles(_rosterReach(state))
                .contains(addition.role) ||
            roster == null ||
            roster.isEmpty ||
            roster.any((row) => row.userId == user.id)) {
          return DropWrite(
            EventWriteDropped.attendee(EventAttendeeWrite.add, name: name),
          );
        }
        return SendWrite(
          EventAttendeeAddRequested(
            snapshot.event.id,
            user.id,
            addition.role,
            name: name,
          ),
        );
      },
    );

/// Row [id] of the roster [state] shows, where its menu would still offer
/// the write [allows] decides on: the event takes it, the role table still
/// gives the viewer the roster, and [allows] still holds for the row. Null
/// where a sync changed any of that while a dialog was open, or took the
/// row off. The page already shows that, without the item, and the write's
/// banner says the roster changed, or a screen reader would hear nothing
/// happen (#655).
EventAttendee? _actableRow(
  EventDetailReady state,
  String id,
  bool Function(
    AttendeeReach reach,
    EventAttendee row, {
    required String? viewerAttendeeId,
  })
  allows,
) {
  final reach = _rosterReach(state);
  if (reach == AttendeeReach.none) return null;
  final row = state.detail.snapshot.attendees
      ?.where((shown) => shown.id == id)
      .firstOrNull;
  if (row == null ||
      !allows(reach, row, viewerAttendeeId: state.detail.attendance?.id)) {
    return null;
  }
  return row;
}

/// How far [state]'s viewer reaches over its roster (#510): as the role
/// table says while the event takes the write, and [AttendeeReach.none] once
/// it is cancelled or archived. The menus, Add people and the writes'
/// re-checks all ask this.
AttendeeReach _rosterReach(EventDetailReady state) =>
    takesDateWrites(state.detail.snapshot.event)
    ? state.attendeeReach
    : AttendeeReach.none;

/// How the last action went (#501, #502, #506, #508, #510), or the last vote
/// (#507), over the event until dismissed or replaced. A live region, as every
/// [BgeInlineBanner] is. A delete's done has none: the screen leaves. Nor
/// does a vote's: its chip shows it.
class _ActionOutcomeBanner extends StatelessWidget {
  const _ActionOutcomeBanner({
    required this.outcome,
    required this.onDismiss,
    required this.bannerKey,
  });

  final EventActionOutcome outcome;

  /// Clears the outcome from the bloc that holds it.
  final VoidCallback onDismiss;

  /// The screen's key for this banner, on the [BgeInlineBanner] itself.
  final Key bannerKey;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final action = outcome.action;
    final message = switch (outcome) {
      // Cancel and reopen share an action, as archive and unarchive do, so
      // the outcome says which it was (#502). So do the roster's three
      // writes (#510).
      EventActionOutcome(:final statusWrite?) => _statusWriteMessage(
        l10n,
        statusWrite,
      ),
      EventActionOutcome(:final attendeeWrite?) => _attendeeMessage(
        l10n,
        attendeeWrite,
      ),
      _ => _actionMessage(l10n),
    };
    if (message == null) return const SizedBox.shrink();

    return BgeInlineBanner(
      key: bannerKey,
      tone: switch (outcome.result) {
        EventActionResult.done => BgeBannerTone.success,
        // Gone is what deleting, removing a date and removing someone
        // asked for: a second press after an answer was lost finds it so.
        // Any other write's is what it named gone from under it.
        EventActionResult.gone =>
          action == EventAction.delete ||
                  action == EventAction.removeDate ||
                  outcome.attendeeWrite == EventAttendeeWrite.remove
              ? BgeBannerTone.success
              : BgeBannerTone.warning,
        EventActionResult.refused ||
        EventActionResult.changed ||
        EventActionResult.partlyDone => BgeBannerTone.warning,
        EventActionResult.failed => BgeBannerTone.error,
      },
      message: message,
      action: TextButton(
        onPressed: onDismiss,
        child: Text(l10n.eventsActionDismiss),
      ),
    );
  }

  /// The copy of an outcome that is not a status write, by its action, or
  /// null for an action whose outcome this banner never shows.
  String? _actionMessage(EventsLocalizations l10n) => switch (outcome.action) {
    EventAction.addDate => _dateMessage(l10n, done: l10n.eventsDateAdded),
    EventAction.editDate => _dateMessage(l10n, done: l10n.eventsDateSaved),
    EventAction.confirmDate => _dateMessage(
      l10n,
      done: l10n.eventsDateConfirmed,
    ),
    EventAction.declineDate => _dateMessage(
      l10n,
      done: l10n.eventsDateDeclined,
    ),
    EventAction.cancelDate => _dateMessage(
      l10n,
      done: l10n.eventsDateCancelled,
    ),
    EventAction.removeDate => _dateMessage(l10n, done: l10n.eventsDateRemoved),
    EventAction.voteAvailability => _voteMessage(l10n),
    EventAction.rsvp => _rsvpMessage(l10n),
    // An offer never travels through the actions bloc: the games pool's
    // bloc sends it and owns its outcome, which the page's footer shows
    // (#516). So this banner has no copy for it, and shows none.
    EventAction.offerGame => null,
    // Nor does a nomination or a vote (#517): the nominations' bloc owns
    // theirs.
    EventAction.nominateGame || EventAction.voteGame => null,
    // Delete is the only other action whose outcome reaches here: a status
    // write's and a roster write's take the arms above. The event's edit
    // (#500) is offered nowhere on this screen, so none reaches here.
    _ => _deleteMessage(l10n),
  };

  /// A status write's copy (#502), saying which was done where it was.
  ///
  /// No failure says the status didn't change. A transient one's answer was
  /// lost, and the write may have landed, so it may be pressed again. Any
  /// other failure doesn't ask for that: a rejection, or one that sent
  /// nothing, would end the same way pressed again. It points at the status
  /// instead, which the screen reads again after it, since an answer this
  /// device could not read may follow a write that landed.
  String _statusWriteMessage(
    EventsLocalizations l10n,
    EventStatusWrite write,
  ) => switch (outcome.result) {
    EventActionResult.done => switch (write) {
      EventStatusWrite.cancel => l10n.eventsCancelled,
      EventStatusWrite.reopen => l10n.eventsReopened,
      EventStatusWrite.archive => l10n.eventsArchived,
      EventStatusWrite.unarchive => l10n.eventsUnarchived,
    },
    EventActionResult.gone => l10n.eventsStatusWriteGone,
    EventActionResult.refused => l10n.eventsStatusWriteRefused,
    EventActionResult.changed => l10n.eventsStatusWriteChanged,
    // A status write is one request, so it never ends partly done.
    EventActionResult.failed || EventActionResult.partlyDone =>
      outcome.error is EventRemoteTransientException
          ? l10n.eventsStatusWriteFailed
          : l10n.eventsStatusWriteFailedUnexpected,
  };

  /// A roster write's copy (#510). An end that names the person names them
  /// as the write did, or says "this person" where they have no name: "This
  /// person" where the sentence starts with them.
  ///
  /// No failure says the write didn't land: a transient one's answer was
  /// lost, and it may have. Nor that the roster below is up to date: the
  /// read after it can fail too, and one that sent nothing isn't read again
  /// ([EventActionOutcome.rereads]). Each asks for the roster to be checked.
  String _attendeeMessage(EventsLocalizations l10n, EventAttendeeWrite write) {
    final name = outcome.attendeeName ?? l10n.eventsAttendeeSomeone;
    final leading = outcome.attendeeName ?? l10n.eventsAttendeeSomeoneStart;
    return switch (outcome.result) {
      EventActionResult.done => switch (write) {
        EventAttendeeWrite.add => l10n.eventsAttendeeAdded(name),
        EventAttendeeWrite.remove => l10n.eventsAttendeeRemoved(name),
        EventAttendeeWrite.answer => l10n.eventsAttendeeAnswerSaved(name),
      },
      // A 404. For an add, the person or the event, which the server
      // doesn't tell apart.
      EventActionResult.gone => switch (write) {
        EventAttendeeWrite.add => l10n.eventsAttendeeAddGone(name),
        EventAttendeeWrite.remove => l10n.eventsAttendeeRemoveGone(leading),
        EventAttendeeWrite.answer => l10n.eventsAttendeeAnswerGone(leading),
      },
      // A 403. For an add, a grant gone or the person's own settings, which
      // the client can't tell apart.
      EventActionResult.refused => switch (write) {
        EventAttendeeWrite.add => l10n.eventsAttendeeAddRefused(leading),
        EventAttendeeWrite.remove => l10n.eventsAttendeeRemoveRefused(name),
        EventAttendeeWrite.answer => l10n.eventsAttendeeAnswerRefused(name),
      },
      // An add's 409 is someone already on the event. Any other is a write
      // the screen dropped, or a 400 for a roster that moved.
      EventActionResult.changed =>
        write == EventAttendeeWrite.add && !outcome.dropped
            ? l10n.eventsAttendeeAddAlreadyOn(leading)
            : l10n.eventsAttendeeRosterChanged,
      // Each is one request, so it never ends partly done.
      EventActionResult.failed || EventActionResult.partlyDone =>
        outcome.error is EventRemoteTransientException
            ? l10n.eventsAttendeeWriteFailed
            : l10n.eventsAttendeeWriteFailedUnexpected,
    };
  }

  /// A vote's copy (#507). A failure never says the answer wasn't saved:
  /// one whose answer was lost may have landed.
  String _voteMessage(EventsLocalizations l10n) => switch (outcome.result) {
    EventActionResult.changed => l10n.eventsPollVoteChanged,
    EventActionResult.gone => l10n.eventsDateGone,
    EventActionResult.refused => l10n.eventsPollVoteRefused,
    // Done and partly done never come here: done shows on the chip, and a
    // vote is one request.
    EventActionResult.failed ||
    EventActionResult.done ||
    EventActionResult.partlyDone => l10n.eventsPollVoteFailed,
  };

  /// The viewer's answer's copy (#508). No failure says the answer wasn't
  /// saved: a transient one's answer was lost, and the write may have
  /// landed, so it may be pressed again. Any other points at the answer,
  /// which the screen reads again after it, as a status write's does.
  String _rsvpMessage(EventsLocalizations l10n) => switch (outcome.result) {
    EventActionResult.done => l10n.eventsRsvpSaved,
    // The event or the viewer's row on it, and the read after says which.
    EventActionResult.gone => l10n.eventsRsvpGone,
    EventActionResult.refused => l10n.eventsRsvpRefused,
    EventActionResult.changed => l10n.eventsRsvpChanged,
    // An RSVP is one request, so it never ends partly done.
    EventActionResult.failed || EventActionResult.partlyDone =>
      outcome.error is EventRemoteTransientException
          ? l10n.eventsRsvpFailed
          : l10n.eventsRsvpFailedUnexpected,
  };

  String _deleteMessage(EventsLocalizations l10n) => switch (outcome.result) {
    EventActionResult.done => l10n.eventsDeleted,
    EventActionResult.gone => l10n.eventsDeleteGone,
    EventActionResult.refused => l10n.eventsDeleteRefused,
    // Only a date write (#506) ends changed or partlyDone.
    EventActionResult.changed => l10n.eventsDateChanged,
    EventActionResult.partlyDone => l10n.eventsDateCancelledRemoveUnconfirmed,
    // Only a transient failure is worth pressing again (#501). A session
    // that moved sent nothing, and a permanent failure (a 4xx) stays one: the
    // same press would end the same way.
    EventActionResult.failed =>
      outcome.error is EventRemoteTransientException
          ? l10n.eventsDeleteFailed
          : l10n.eventsDeleteFailedUnexpected,
  };

  /// A date write's copy (#506), saying [done] where it was.
  ///
  /// A failure never says the change didn't happen: a write whose answer
  /// was lost may have landed. An add that went out is read again before
  /// Add can be pressed twice, since a second add is a second date
  /// (backend#902), so it asks the user to look first. Any other failure
  /// that was transient may be pressed again. One that wasn't, or that sent
  /// nothing, would end the same way.
  String _dateMessage(EventsLocalizations l10n, {required String done}) =>
      switch (outcome.result) {
        EventActionResult.done => done,
        EventActionResult.gone => l10n.eventsDateGone,
        EventActionResult.refused => l10n.eventsDateRefused,
        EventActionResult.changed => l10n.eventsDateChanged,
        // A confirm whose declines didn't all land (#507), or a cancel whose
        // remove didn't (#446).
        EventActionResult.partlyDone =>
          outcome.action == EventAction.confirmDate
              ? l10n.eventsDateConfirmedNotAllDeclined
              : l10n.eventsDateCancelledRemoveUnconfirmed,
        EventActionResult.failed =>
          outcome.action == EventAction.addDate && outcome.error != null
              ? l10n.eventsDateAddFailed
              : outcome.error is EventRemoteTransientException
              ? l10n.eventsDateFailed
              : l10n.eventsDateFailedUnexpected,
      };
}

/// Nothing cached to show and nothing that will answer: the overview's two
/// failed-read surfaces, for one event.
///
/// Where the bloc would read again ([EventDetailError.canRetry]), #102's
/// error-with-retry. The retry stays in place while it runs, disabled and
/// saying so, rather than giving way to a spinner: a press that left the
/// failure up would otherwise look like one that did nothing. Where it
/// wouldn't, with no server or once the cache has ended, the failure alone,
/// with no button that would do nothing.
class _ErrorPage extends StatelessWidget {
  const _ErrorPage({required this.refreshing, required this.canRetry});

  final bool refreshing;
  final bool canRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return _MessagePage(
      child: canRetry
          ? BgeErrorState(
              key: EventDetailScreen.errorKey,
              retryKey: EventDetailScreen.errorRetryKey,
              icon: Icons.error_outline,
              title: l10n.eventsDetailError,
              body: l10n.eventsDetailErrorBody,
              retryLabel: l10n.eventsRefreshRetry,
              retryProgressLabel: l10n.eventsRefreshInProgress,
              retrying: refreshing,
              onRetry: () => _retry(context),
            )
          : BgeInlineBanner(
              key: EventDetailScreen.errorKey,
              tone: BgeBannerTone.error,
              message: l10n.eventsDetailError,
            ),
    );
  }
}

/// No event the user may read at this id; see [EventDetailScreen].
class _NotFoundPage extends StatelessWidget {
  const _NotFoundPage({this.onBack});

  final void Function(BuildContext context)? onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final back = onBack;

    return _MessagePage(
      child: Column(
        key: EventDetailScreen.notFoundKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.eventsDetailNotFoundTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          const BgeGap.sm(),
          Text(
            l10n.eventsDetailNotFoundBody,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          // The app bar's back button does the same. This one is here
          // because leaving is the likely intent on this surface.
          if (back != null) ...[
            const BgeGap.lg(),
            FilledButton.icon(
              key: EventDetailScreen.notFoundBackKey,
              onPressed: () => back(context),
              icon: const Icon(Icons.event_outlined),
              label: Text(l10n.eventsDetailNotFoundAction),
            ),
          ],
        ],
      ),
    );
  }
}

class _LoadingPage extends StatelessWidget {
  const _LoadingPage();

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return _MessagePage(
      child: Center(
        child: BgeLoadingState(
          key: EventDetailScreen.loadingKey,
          label: l10n.eventsDetailLoading,
        ),
      ),
    );
  }
}

/// A short message centred on an otherwise empty page.
class _MessagePage extends StatelessWidget {
  const _MessagePage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => BgePage(
    title: Text(EventsLocalizations.of(context).eventsTitle),
    width: BgePageWidth.pane,
    centerVertically: true,
    child: child,
  );
}

/// The only event the screen sends the detail bloc (#498): read the event
/// again.
void _retry(BuildContext context) =>
    context.read<EventDetailBloc>().add(const EventDetailRetryRequested());
