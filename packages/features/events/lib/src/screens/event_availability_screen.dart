import 'dart:async';
import 'dart:math' as math;

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_event.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_poll_bloc.dart';
import 'package:events/src/bloc/event_poll_event.dart';
import 'package:events/src/bloc/event_poll_state.dart';
import 'package:events/src/detail/event_poll.dart';
import 'package:events/src/widgets/event_date_poll.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart' hide ConnectionState;
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Who answered an event's availability poll (#507): a row for each person
/// the poll lists, a column for each Proposed date, and each person's answer
/// where the two meet. Read only: answers are given on the event's detail.
///
/// The screen reads the poll once, as it opens, through an [EventPollBloc]
/// of its own. The event, its dates and its roster come from the cache. The
/// rows are [pollRows]'s, and the columns are the Proposed dates in the
/// cache's order, which is their sort order.
///
/// Only where the cache lacks the event or its roster, as on a direct visit,
/// does the page read the event as well, with an [EventDetailBloc] of its own.
/// The detail beneath reads it too, but what becomes of that read can't reach
/// this page, and a page opened from the detail never needs it: the detail
/// offers it only with a roster, so this read can't race a write there.
///
/// ## A cell
///
/// It shows the answer, or a dash for none. A vote that doesn't count, its
/// voter having answered Not attending, is struck through. Each cell is one
/// node to a screen reader, saying whose answer it is, for which date, and
/// the answer, with that it doesn't count where it doesn't: a reader moving
/// cell by cell doesn't always say the row's or the column's heading.
///
/// ## Scrolling
///
/// The page scrolls down, and the dates scroll sideways beside the names,
/// which stay put. The two sides are laid out apart, so each row's height
/// is worked out from its text before either is built, and both sides take
/// it: a name that wraps keeps its row's answers level with it.
///
/// Where the dates run past their room they show a scrollbar, whose thumb a
/// mouse can drag, and take keyboard focus, with the left and right arrows
/// moving them. A screen reader moves by the cells instead, and hears no
/// extra stop.
///
/// ## When there is no grid
///
/// The first case below that matches decides what the page shows:
///
/// - No [remote]: shows the page that says the answers can't be seen.
/// - The cache can't be read: shows the failed-to-load page, with no retry.
/// - The cache still to answer: shows the loading page.
/// - The server refuses the read (403), or has no such event (404): shows
///   the page that says the answers can't be seen.
/// - A roster withheld from the viewer (#498), as the summary or the cache
///   says: shows the page that says the answers can't be seen.
/// - The event was cached, and has left the cache since: shows the page that
///   says the answers can't be seen.
/// - The read failed, or the session check stopped it (#432): shows the
///   failed-to-load page, with a retry.
/// - The event or its roster not cached, and the page's own read of the
///   event answered 404 or withheld the roster: shows the page that says the
///   answers can't be seen.
/// - The event or its roster not cached, and that read failed: shows the
///   failed-to-load page, with a retry.
/// - The event or its roster not cached yet, or the poll's read still to
///   answer: shows the loading page.
/// - No poll open: not a poll, or no Proposed date left: shows the page that
///   says the answers can't be seen.
class EventAvailabilityScreen extends StatelessWidget {
  const EventAvailabilityScreen({
    required this.eventId,
    required this.repository,
    this.remote,
    this.confirmSession,
    this.now,
    super.key,
  });

  /// Key on the spinner while the page waits.
  static const Key loadingKey = Key('event_availability.loading');

  /// Key on the note that the viewer can't see the answers.
  static const Key hiddenKey = Key('event_availability.hidden');

  /// Key on the banner saying the answers couldn't be loaded.
  static const Key failedKey = Key('event_availability.failed');

  /// Key on that banner's retry.
  static const Key retryKey = Key('event_availability.retry');

  /// Key on the grid.
  static const Key gridKey = Key('event_availability.grid');

  /// Key on the line above the grid saying what a struck-through answer
  /// means.
  static const Key legendKey = Key('event_availability.legend');

  /// Key on a row's name, by the roster row's id.
  static Key nameKey(String attendeeId) =>
      Key('event_availability.name_$attendeeId');

  /// Key on a column's heading, by the date's id.
  static Key dateKey(String occurrenceId) =>
      Key('event_availability.date_$occurrenceId');

  /// Key on one cell, by its row's and its column's ids.
  static Key cellKey(String attendeeId, String occurrenceId) =>
      Key('event_availability.cell_${attendeeId}_$occurrenceId');

  /// The event whose poll to show, by the id its route carried.
  final String eventId;

  /// The user-session event repository, for the event, its dates and its
  /// roster.
  final EventRepository repository;

  /// The per-server event client the answers are read from. Null reads
  /// nothing, and the page says the viewer can't see the answers.
  final EventRemoteDataSource? remote;

  /// Whether the session is still the user [repository] belongs to, asked
  /// before the read goes out and before its answer is used (#432). Null, as
  /// on native, is always yes.
  final Future<bool> Function()? confirmSession;

  /// The clock that decides whether a date is this year's. Defaults to the
  /// device's.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final remote = this.remote;
    if (remote == null) return const _HiddenPage();

    return _AvailabilityPage(
      // go_router keeps this page when only the id changes; the key makes a
      // new id a new read rather than the old poll under it, as the detail's
      // does (#466).
      key: ValueKey<String>(eventId),
      eventId: eventId,
      repository: repository,
      remote: remote,
      confirmSession: confirmSession,
      now: now ?? DateTime.now,
    );
  }
}

class _AvailabilityPage extends StatefulWidget {
  const _AvailabilityPage({
    required this.eventId,
    required this.repository,
    required this.remote,
    required this.now,
    this.confirmSession,
    super.key,
  });

  final String eventId;
  final EventRepository repository;
  final EventRemoteDataSource remote;
  final Future<bool> Function()? confirmSession;
  final DateTime Function() now;

  @override
  State<_AvailabilityPage> createState() => _AvailabilityPageState();
}

class _AvailabilityPageState extends State<_AvailabilityPage> {
  /// The event's id, or the id a reconcile moved it to (#499). Opened from a
  /// detail that followed the move, the route still carries the old one.
  late final String _eventId =
      widget.repository.reconciledEventId(widget.eventId) ?? widget.eventId;

  /// The cached event, watched for the page's life.
  late final Stream<EventDetail?> _event = widget.repository.watchEvent(
    _eventId,
  );

  /// Whether the cache has held the event. Once it has, a cache with none
  /// has lost it, and no read here would bring it back: only before then is
  /// it the detail beneath still reading.
  bool _cachedOnce = false;

  /// The page's own read of the event: see [EventAvailabilityScreen]. Started
  /// the first time the page finds the cache lacking.
  EventDetailBloc? _eventRead;

  @override
  void dispose() {
    unawaited(_eventRead?.close());
    super.dispose();
  }

  void _retry(BuildContext context) =>
      context.read<EventPollBloc>().add(EventPollRetryRequested(_eventId));

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => EventPollBloc(
      remote: widget.remote,
      confirmSession: widget.confirmSession,
    )..add(EventPollRequested(_eventId)),
    child: BlocBuilder<EventPollBloc, EventPollState>(
      builder: (context, poll) => StreamBuilder<EventDetail?>(
        stream: _event,
        builder: (context, cached) => _pageFor(context, cached, poll),
      ),
    ),
  );

  Widget _pageFor(
    BuildContext context,
    AsyncSnapshot<EventDetail?> cached,
    EventPollState poll,
  ) {
    if (cached.hasError) return const _FailedPage();
    if (cached.connectionState == ConnectionState.waiting) {
      return const _LoadingPage();
    }

    final summary = poll.summary;
    final snapshot = cached.data?.snapshot;
    final roster = snapshot?.attendees;
    if (snapshot != null) _cachedOnce = true;
    if (_serverRefused(poll) ||
        _rosterWithheld(poll, roster) ||
        _eventLost(snapshot)) {
      return const _HiddenPage();
    }
    // A failed read keeps its page, and the retry on it, while the next
    // read runs, so a retry that has focus keeps it.
    if (poll.refreshFailed) {
      return _FailedPage(
        onRetry: () => _retry(context),
        retrying: poll.refreshing,
      );
    }
    // Only the roster says the rest of the event has been read, so nothing is
    // said of the poll before it: a refusal here would be announced, then
    // taken back.
    if (snapshot == null || roster == null) return _eventReadPage();
    if (summary == null) return const _LoadingPage();
    if (!showsPoll(snapshot.event, snapshot.occurrences)) {
      return const _HiddenPage();
    }

    return _GridPage(
      snapshot: snapshot,
      roster: roster,
      summary: summary,
      now: widget.now(),
    );
  }

  /// Whether the server refused the read, or has no such event.
  bool _serverRefused(EventPollState poll) =>
      poll.load == EventPollLoad.hidden || poll.load == EventPollLoad.gone;

  /// Whether the summary or the cache withholds the roster from the viewer.
  bool _rosterWithheld(EventPollState poll, List<EventAttendee>? roster) =>
      poll.summary?.rosterVisible == false || (roster?.isEmpty ?? false);

  /// Whether the cache has held the event, and no longer does.
  bool _eventLost(EventSnapshot? snapshot) => snapshot == null && _cachedOnce;

  /// The page while the cache lacks the event or its roster, as the page's
  /// own read of them stands. A read that succeeds reaches the page through
  /// the cache.
  Widget _eventReadPage() {
    final read = _eventRead ??= EventDetailBloc(
      eventId: _eventId,
      repository: widget.repository,
      remote: widget.remote,
      confirmSession: widget.confirmSession,
    );

    return BlocBuilder<EventDetailBloc, EventDetailState>(
      bloc: read,
      builder: (context, state) => switch (state) {
        EventDetailNotFound() => const _HiddenPage(),
        EventDetailError(:final refreshing, :final canRetry) ||
        EventDetailReady(
          refreshFailed: true,
          :final refreshing,
          :final canRetry,
        ) => _FailedPage(
          onRetry: canRetry
              ? () => read.add(const EventDetailRetryRequested())
              : null,
          retrying: refreshing,
        ),
        EventDetailReady(:final detail)
            when detail.snapshot.attendees?.isEmpty ?? false =>
          const _HiddenPage(),
        _ => const _LoadingPage(),
      },
    );
  }
}

/// The event's title, and the grid under it.
class _GridPage extends StatelessWidget {
  const _GridPage({
    required this.snapshot,
    required this.roster,
    required this.summary,
    required this.now,
  });

  final EventSnapshot snapshot;
  final List<EventAttendee> roster;
  final AvailabilitySummary summary;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final event = snapshot.event;
    final dates = [
      for (final occurrence in snapshot.occurrences)
        if (occurrence.status == OccurrenceStatus.proposed) occurrence,
    ];
    // Whether a cell is struck through: a vote shown with its answer that
    // doesn't count. Sighted viewers get the line saying what that means; a
    // screen reader hears it in the cell.
    final struck = dates.any(
      (date) => (summary.of(date.id)?.voters ?? const <AvailabilityVoter>[])
          .any((voter) => _struckThrough(l10n, voter)),
    );

    return BgePage(
      title: Text(l10n.eventsPollWhoAnsweredTitle),
      width: BgePageWidth.pane,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(event.title, style: theme.textTheme.titleLarge),
          ),
          const BgeGap.lg(),
          if (struck) ...[
            Text(
              key: EventAvailabilityScreen.legendKey,
              l10n.eventsPollNotCountingLegend,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const BgeGap.md(),
          ],
          _PollGrid(
            key: EventAvailabilityScreen.gridKey,
            dates: dates,
            rows: pollRows(event, snapshot.occurrences, roster, summary),
            summary: summary,
            now: now,
          ),
        ],
      ),
    );
  }
}

/// The answer [vote]'s cell shows, or null for one this client can't name,
/// which shows as no answer.
String? _answerOf(EventsLocalizations l10n, AvailabilityVoter? vote) =>
    availabilityResponseLabel(l10n, vote?.response);

/// Whether [vote]'s cell is struck through: it shows an answer, and the
/// vote doesn't count.
bool _struckThrough(EventsLocalizations l10n, AvailabilityVoter? vote) =>
    vote != null && !vote.eligible && _answerOf(l10n, vote) != null;

/// What a cell with no answer shows. A mark, not words: a screen reader
/// hears the cell's label instead.
const _noAnswerMark = '\u{2014}';

/// The largest share of the grid's width the name column takes, so the
/// dates always keep the rest. A proportion, not a spacing or a width, so
/// there is no token for it, as with `BgePage`'s footer.
const double _nameColumnMaxShare = 0.5;

/// The names, fixed, beside the dates, which scroll sideways under their
/// headings.
///
/// ## Widths
///
/// The names take what they need, up to [_nameColumnMaxShare] of the width,
/// past which they wrap. A date column is as wide as the longest answer, so
/// no answer wraps, or as its heading's longest word, but never wider than
/// the room the dates have, so a whole date always shows beside the names.
/// With more than one date, a column leaves the next one's start showing
/// too, a token wide, so there is plainly more to the side: at large text on
/// a narrow screen a column would otherwise fill the room exactly, and
/// nothing would show that the dates go on. Where a column is narrower than
/// an answer, the answer scales down to fit, as the detail's answer chips
/// do.
class _PollGrid extends StatelessWidget {
  const _PollGrid({
    required this.dates,
    required this.rows,
    required this.summary,
    required this.now,
    super.key,
  });

  final List<EventOccurrence> dates;
  final List<PollRow> rows;
  final AvailabilitySummary summary;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final pad = tokens.spaceSm;
    final text = _GridText.of(context);

    final names = [
      for (final row in rows) row.attendee?.name ?? l10n.eventsPollUnknownVoter,
    ];
    final headings = [
      for (final date in dates) eventDateName(context, date, now: now),
    ];
    // Each date's votes, by roster row.
    final votes = [
      for (final date in dates)
        {
          for (final voter
              in summary.of(date.id)?.voters ?? const <AvailabilityVoter>[])
            voter.attendeeId: voter,
        },
    ];

    final line = BorderSide(color: theme.colorScheme.outlineVariant);
    final rule = BorderSide(color: theme.colorScheme.outline);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final answers = [
          for (final response in AvailabilityResponse.values)
            ?availabilityResponseLabel(l10n, response),
          _noAnswerMark,
        ];
        final dateWidth =
            answers
                .map((answer) => text.widthOf(answer, text.body))
                .reduce(math.max) +
            2 * pad;
        final namesWidth = names.isEmpty
            ? 0.0
            : names
                      .map((name) => text.widthOf(name, text.body))
                      .reduce(math.max) +
                  2 * pad;
        final nameWidth = math.min(namesWidth, width * _nameColumnMaxShare);
        final room = width - nameWidth;
        // Leaves the next date's start showing: see Widths above.
        final widest = dates.length > 1
            ? math.max<double>(0, room - tokens.spaceXl)
            : room;
        final columns = [
          for (final heading in headings)
            math.min(
              widest,
              math.max(
                dateWidth,
                text.longestWordOf(heading, text.heading) + 2 * pad,
              ),
            ),
        ];

        double inside(double outer) => math.max(0, outer - 2 * pad);
        final headingHeight =
            [
              for (final (j, heading) in headings.indexed)
                text.heightOf(heading, text.heading, inside(columns[j])),
            ].fold<double>(0, math.max) +
            2 * pad;
        // On one line, however narrow the column: an answer scales down
        // rather than wrap.
        final answerHeight = answers
            .map((answer) => text.heightOf(answer, text.body, double.infinity))
            .reduce(math.max);
        final rowHeights = [
          for (final name in names)
            math.max(
                  text.heightOf(name, text.body, inside(nameWidth)),
                  answerHeight,
                ) +
                2 * pad,
        ];

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: nameWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Cell(
                    height: headingHeight,
                    border: Border(bottom: rule),
                    child: const SizedBox.shrink(),
                  ),
                  for (final (i, row) in rows.indexed)
                    _Cell(
                      key: EventAvailabilityScreen.nameKey(row.attendeeId),
                      height: rowHeights[i],
                      border: BorderDirectional(bottom: line, end: rule),
                      child: text.draw(names[i], text.body),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _DatesScroller(
                overflows:
                    columns.fold<double>(0, (sum, column) => sum + column) >
                    room,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (j, date) in dates.indexed)
                          _Cell(
                            key: EventAvailabilityScreen.dateKey(date.id),
                            width: columns[j],
                            height: headingHeight,
                            border: Border(bottom: rule),
                            alignment: Alignment.bottomCenter,
                            child: text.draw(
                              headings[j],
                              text.heading,
                              align: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                    for (final (i, row) in rows.indexed)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (j, date) in dates.indexed)
                            _AnswerCell(
                              key: EventAvailabilityScreen.cellKey(
                                row.attendeeId,
                                date.id,
                              ),
                              name: names[i],
                              date: headings[j],
                              vote: votes[j][row.attendeeId],
                              text: text,
                              width: columns[j],
                              height: rowHeights[i],
                              border: Border(bottom: line),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The dates' side of the grid, scrolling sideways under its own scrollbar.
///
/// Material leaves a horizontal scroller with no scrollbar and no mouse drag,
/// and nothing in the grid takes focus, so with a mouse or a keyboard the
/// later dates would be out of reach. While the dates [overflows] their room,
/// the bar shows, and this takes focus, its ring round what shows of the
/// dates, and the arrows move them. With nothing to move it is no stop at all.
///
/// A screen reader has each cell to land on, and the scroller's own scroll
/// actions, so the focus adds no node for it to stop on.
class _DatesScroller extends StatefulWidget {
  const _DatesScroller({required this.overflows, required this.child});

  /// Whether the dates are wider than the room they have.
  final bool overflows;

  final Widget child;

  @override
  State<_DatesScroller> createState() => _DatesScrollerState();
}

class _DatesScrollerState extends State<_DatesScroller> {
  final ScrollController _controller = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'Who answered dates');

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Moves the dates half of what shows, towards the dates on the side the
  /// arrow points: which way that is along the scroller follows the text's
  /// direction.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => AxisDirection.left,
      LogicalKeyboardKey.arrowRight => AxisDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;

    final position = _controller.position;
    final step = position.viewportDimension / 2;
    unawaited(
      position.moveTo(
        position.pixels + (direction == position.axisDirection ? step : -step),
      ),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final ring = Theme.of(context).colorScheme.primary;

    // Round the scroller, not its content: focus reveals what it is on, and
    // would otherwise send the dates to their end as it lands.
    return Focus(
      focusNode: _focus,
      canRequestFocus: widget.overflows,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: _focus,
        builder: (context, scroller) => DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: _focus.hasPrimaryFocus
                ? Border.all(color: ring, width: 2)
                : null,
          ),
          child: scroller,
        ),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: widget.overflows,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            // The bar's own room, so its thumb covers no answer.
            child: Padding(
              padding: EdgeInsets.only(
                bottom: widget.overflows ? tokens.spaceMd : 0,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// One person's answer on one date, as one node to a screen reader.
class _AnswerCell extends StatelessWidget {
  const _AnswerCell({
    required this.name,
    required this.date,
    required this.text,
    required this.width,
    required this.height,
    required this.border,
    this.vote,
    super.key,
  });

  /// The row's person and the column's date, as their headings name them.
  final String name;
  final String date;

  /// Their vote on the date, or null for none.
  final AvailabilityVoter? vote;

  final _GridText text;
  final double width;
  final double height;
  final BoxBorder border;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final quiet = Theme.of(context).colorScheme.onSurfaceVariant;
    // An answer this client doesn't know is none it can show.
    final answer = _answerOf(l10n, vote);
    final struck = _struckThrough(l10n, vote);

    final spoken = answer == null
        ? l10n.eventsPollNoAnswer
        : !struck
        ? answer
        : [
            answer,
            l10n.eventsPollVoteNotCounting,
          ].join(l10n.eventsDetailSpokenSeparator);

    return Semantics(
      container: true,
      label: l10n.eventsPollCell(name, date, spoken),
      excludeSemantics: true,
      child: _Cell(
        width: width,
        height: height,
        border: border,
        alignment: Alignment.center,
        // One line, scaled down where the column is narrower than the
        // word: see _PollGrid.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: text.draw(
            answer ?? _noAnswerMark,
            answer != null && !struck
                ? text.body
                : text.body.copyWith(
                    color: quiet,
                    decoration: struck ? TextDecoration.lineThrough : null,
                  ),
            align: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

/// A box of the grid: [child] padded, at [height] and, unless the column's
/// own width sets it, [width].
class _Cell extends StatelessWidget {
  const _Cell({
    required this.height,
    required this.border,
    required this.child,
    this.width,
    this.alignment = AlignmentDirectional.centerStart,
    super.key,
  });

  final double height;
  final double? width;
  final BoxBorder border;
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pad = BgeTokens.of(context).spaceSm;

    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(border: border),
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Align(alignment: alignment, child: child),
        ),
      ),
    );
  }
}

/// The grid's text, measured as it is drawn.
///
/// The names and the dates are laid out apart, the dates in a scroll view
/// of their own, so a row's height is worked out from its text first. Each
/// piece is measured with the style, scaler, direction, locale and height
/// behaviour it is then drawn with, resolved once here as `Text` resolves
/// them, so the two can't disagree.
final class _GridText {
  const _GridText._({
    required this.body,
    required this.heading,
    required this.scaler,
    required this.direction,
    required this.locale,
    required this.heightBehavior,
  });

  factory _GridText.of(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final ambient = DefaultTextStyle.of(context);
    final bold = MediaQuery.boldTextOf(context);
    TextStyle resolve(TextStyle? style) {
      final merged = ambient.style.merge(style);
      return bold
          ? merged.merge(const TextStyle(fontWeight: FontWeight.bold))
          : merged;
    }

    return _GridText._(
      body: resolve(textTheme.bodyMedium),
      heading: resolve(textTheme.labelLarge),
      scaler: MediaQuery.textScalerOf(context),
      direction: Directionality.of(context),
      locale: Localizations.maybeLocaleOf(context),
      heightBehavior:
          ambient.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
    );
  }

  /// The names and the answers: one body size for the whole table.
  final TextStyle body;

  /// The dates heading the columns.
  final TextStyle heading;

  final TextScaler scaler;
  final TextDirection direction;
  final Locale? locale;
  final TextHeightBehavior? heightBehavior;

  /// [text] laid out in [style], no wider than [maxWidth].
  T _measure<T>(
    String text,
    TextStyle style,
    T Function(TextPainter painter) read, {
    double maxWidth = double.infinity,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
      textHeightBehavior: heightBehavior,
    )..layout(maxWidth: maxWidth);
    try {
      return read(painter);
    } finally {
      painter.dispose();
    }
  }

  /// How wide [text] is on one line.
  double widthOf(String text, TextStyle style) =>
      _measure(text, style, (painter) => painter.width);

  /// How wide [text]'s longest word is.
  double longestWordOf(String text, TextStyle style) =>
      _measure(text, style, (painter) => painter.minIntrinsicWidth);

  /// How tall [text] is, wrapped at [width].
  double heightOf(String text, TextStyle style, double width) =>
      _measure(text, style, (painter) => painter.height, maxWidth: width);

  /// [text] drawn as it was measured.
  Widget draw(String text, TextStyle style, {TextAlign? align}) => Text(
    text,
    style: style,
    textAlign: align,
    textScaler: scaler,
    textDirection: direction,
    locale: locale,
    textHeightBehavior: heightBehavior,
  );
}

/// Nothing to show yet.
class _LoadingPage extends StatelessWidget {
  const _LoadingPage();

  @override
  Widget build(BuildContext context) => _MessagePage(
    child: Center(
      child: BgeLoadingState(
        key: EventAvailabilityScreen.loadingKey,
        label: EventsLocalizations.of(context).eventsDetailLoading,
      ),
    ),
  );
}

/// The answers can't be shown to this viewer, or not here: see
/// [EventAvailabilityScreen].
class _HiddenPage extends StatelessWidget {
  const _HiddenPage();

  @override
  Widget build(BuildContext context) => _MessagePage(
    child: BgeInlineBanner(
      key: EventAvailabilityScreen.hiddenKey,
      message: EventsLocalizations.of(context).eventsPollHidden,
    ),
  );
}

/// The answers couldn't be loaded, with a retry where reading again could
/// help.
///
/// While the retry's read runs, the page and the retry stay as they are, the
/// retry ignoring presses ([PollRetryButton]): the banner's copy doesn't
/// change, so it isn't announced again if the retry fails too.
class _FailedPage extends StatelessWidget {
  const _FailedPage({this.onRetry, this.retrying = false});

  final VoidCallback? onRetry;

  /// Whether the retry's read is under way.
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final retry = onRetry;

    return _MessagePage(
      child: BgeInlineBanner(
        key: EventAvailabilityScreen.failedKey,
        tone: BgeBannerTone.error,
        message: EventsLocalizations.of(context).eventsPollLoadFailed,
        action: retry == null
            ? null
            : PollRetryButton(
                key: EventAvailabilityScreen.retryKey,
                busy: retrying,
                onRetry: retry,
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
    title: Text(EventsLocalizations.of(context).eventsPollWhoAnsweredTitle),
    width: BgePageWidth.pane,
    centerVertically: true,
    child: child,
  );
}
