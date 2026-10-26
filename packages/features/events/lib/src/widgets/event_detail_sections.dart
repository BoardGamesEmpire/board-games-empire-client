import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../screens/event_detail_screen.dart';
import 'event_labels.dart';

/// The top of an event's detail (#498): its title, as the page's heading,
/// then what kind of event it is and where it stands, whose it is, who may
/// see it, where, its link and description, and what the viewer is at it.
///
/// A line with nothing to say is left out. An unknown type, status, reach
/// or role is a value a newer server sent, and a guess at it is worse than
/// no line. The household is named only where the user's own cached
/// households name it, so a friend or a public reader who isn't a member
/// sees no household line (#498).
///
/// The link is selectable text, not a link: opening it waits for a launcher
/// this package doesn't have, so for now the user can copy it. Like every
/// icon line, it wraps within the width its row leaves it, a long address
/// with no spaces included.
class EventDetailHeader extends StatelessWidget {
  const EventDetailHeader({
    required this.event,
    this.householdName,
    this.role,
    super.key,
  });

  final Event event;

  /// The event's household, by name, or null where the cache has none.
  final String? householdName;

  /// The viewer's role at the event, from their own row on the roster.
  final EventRole? role;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);

    final kind = [
      ?eventTypeLabel(l10n, event.type),
      ?eventStatusLabel(l10n, event.status),
    ];
    final household = _present(householdName);
    final reach = eventReachLabel(l10n, event.reach);
    final location = _present(event.location);
    final url = _present(event.url);
    final description = _present(event.description);
    final role = this.role;
    final rolePhrase = role == null ? null : eventRolePhrase(l10n, role);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spaceSm,
      children: [
        Semantics(
          header: true,
          child: Text(event.title, style: theme.textTheme.headlineSmall),
        ),
        if (kind.isNotEmpty)
          // Joined differently for the eye and the ear, as the row's detail
          // line is: a screen reader would read the symbol out.
          Text(
            kind.join(l10n.eventsDetailSeparator),
            semanticsLabel: kind.join(l10n.eventsDetailSpokenSeparator),
            style: _quiet(theme),
          ),
        if (household != null)
          _IconLine(icon: Icons.groups_outlined, child: Text(household)),
        if (reach != null)
          _IconLine(icon: Icons.visibility_outlined, child: Text(reach)),
        if (location != null)
          _IconLine(icon: Icons.place_outlined, child: Text(location)),
        if (url != null)
          _IconLine(icon: Icons.link, child: SelectableText(url)),
        if (description != null)
          Padding(
            padding: EdgeInsets.only(top: tokens.spaceSm),
            child: Text(description, style: theme.textTheme.bodyLarge),
          ),
        if (rolePhrase != null)
          _IconLine(
            icon: Icons.badge_outlined,
            child: Text(
              key: EventDetailScreen.roleKey,
              l10n.eventsDetailYourRole(rolePhrase),
            ),
          ),
      ],
    );
  }
}

/// When the event happens: each cached date in the server's order, with its
/// end, its status and its own place where it has one (#498).
///
/// With no dates, the row's copy for an undated event: a poll is choosing
/// one, and any other event has none set.
class EventDatesSection extends StatelessWidget {
  const EventDatesSection({
    required this.occurrences,
    required this.schedulingMode,
    required this.now,
    super.key,
  });

  final List<EventOccurrence> occurrences;
  final EventSchedulingMode schedulingMode;

  /// The clock, which decides whether a date is this year's.
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return _Section(
      key: EventDetailScreen.datesKey,
      title: l10n.eventsDetailDates,
      children: occurrences.isEmpty
          ? [
              _Note(
                schedulingMode == EventSchedulingMode.poll
                    ? l10n.eventsDateBeingChosen
                    : l10n.eventsNoDateYet,
              ),
            ]
          : [
              for (final occurrence in occurrences)
                _OccurrenceEntry(occurrence: occurrence, now: now()),
            ],
    );
  }
}

/// One date, as one semantics node.
class _OccurrenceEntry extends StatelessWidget {
  const _OccurrenceEntry({required this.occurrence, required this.now});

  final EventOccurrence occurrence;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final label = _present(occurrence.label);
    final start = occurrence.startDate;
    final end = occurrence.endDate;
    final status = occurrenceStatusLabel(l10n, occurrence.status);
    final location = _present(occurrence.location);
    final quiet = _quiet(theme);

    return _Entry(
      children: [
        // Not a title role: those are the display face, which here would
        // read as one more section heading.
        if (label != null) Text(label, style: theme.textTheme.labelLarge),
        Text(
          start == null
              ? l10n.eventsNoDateYet
              : eventWhenLabel(context, start, now: now),
          style: theme.textTheme.bodyLarge,
        ),
        if (end != null) Text(_until(context, l10n, start, end)),
        if (status != null) Text(status, style: quiet),
        if (location != null) Text(location, style: quiet),
      ],
    );
  }

  /// The end as the time of day where it falls on the start's local day,
  /// and as a full date and time where it doesn't: a multi-day date, or a
  /// night past midnight, would otherwise seem to end before it starts.
  String _until(
    BuildContext context,
    EventsLocalizations l10n,
    DateTime? start,
    DateTime end,
  ) {
    final from = start?.toLocal();
    final to = end.toLocal();
    final sameDay =
        from != null &&
        from.year == to.year &&
        from.month == to.month &&
        from.day == to.day;
    return l10n.eventsDetailUntil(
      sameDay
          ? eventTimeOfDayLabel(context, to)
          : eventWhenLabel(context, to, now: now),
    );
  }
}

/// Who's coming, in the roster's three states (#498): not read yet, not
/// visible to this user, or the people on it.
///
/// An empty roster is the server saying this user may not read it, not that
/// nobody is coming, so it says so rather than "nobody".
class EventAttendeesSection extends StatelessWidget {
  const EventAttendeesSection({required this.attendees, super.key});

  /// Null where no read has carried a roster, empty where the read carried
  /// one this user may not see.
  final List<EventAttendee>? attendees;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return _Section(
      key: EventDetailScreen.attendeesKey,
      title: l10n.eventsDetailAttendees,
      children: switch (attendees) {
        null => [_Note(l10n.eventsDetailAttendeesNotLoaded)],
        [] => [_Note(l10n.eventsDetailAttendeesHidden)],
        final attendees => [
          for (final attendee in attendees) _AttendeeEntry(attendee: attendee),
        ],
      },
    );
  }
}

/// One person on the roster, with their role and their answer, as one
/// semantics node.
class _AttendeeEntry extends StatelessWidget {
  const _AttendeeEntry({required this.attendee});

  final EventAttendee attendee;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final name = attendee.name;
    final role = attendee.role;
    final details = [
      if (role != null) ?eventRoleLabel(l10n, role),
      ?eventRsvpLabel(l10n, attendee.status),
    ];
    if (name == null && details.isEmpty) return const SizedBox.shrink();

    return _Entry(
      children: [
        if (name != null) Text(name, style: theme.textTheme.bodyLarge),
        if (details.isNotEmpty)
          Text(
            details.join(l10n.eventsDetailSeparator),
            semanticsLabel: details.join(l10n.eventsDetailSpokenSeparator),
            style: _quiet(theme),
          ),
      ],
    );
  }
}

/// The games, which #519 fills once the server gives an event-level read.
/// Until then it says they will show here, so the page keeps its shape.
class EventGamesSection extends StatelessWidget {
  const EventGamesSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return _Section(
      key: EventDetailScreen.gamesKey,
      title: l10n.eventsDetailGames,
      children: [_Note(l10n.eventsDetailGamesNotYet)],
    );
  }
}

/// A section: its heading, announced as one, over its content.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      const BgeGap.xs(),
      ...children,
    ],
  );
}

/// One date or one person: its lines, read as one semantics node.
class _Entry extends StatelessWidget {
  const _Entry({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Padding(
      padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

/// A section's single line where it has nothing to list.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceSm),
    child: Text(text, style: _quiet(Theme.of(context))),
  );
}

/// A header line after an icon that says what it is. The icon is the eye's
/// alone: the words carry the meaning, so it has no label of its own.
class _IconLine extends StatelessWidget {
  const _IconLine({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
      const BgeGap.sm(axis: Axis.horizontal),
      Expanded(child: child),
    ],
  );
}

/// [text], or null where there is nothing in it to show.
String? _present(String? text) =>
    text == null || text.trim().isEmpty ? null : text;

/// A secondary line's style: body text in the theme's quieter color.
TextStyle? _quiet(ThemeData theme) => theme.textTheme.bodyMedium?.copyWith(
  color: theme.colorScheme.onSurfaceVariant,
);
