import 'package:flutter/material.dart';

import 'package:events/l10n/events_localizations.dart';

/// The spinner over the user's events, which a screen reader announces as
/// loading them when it appears.
class EventLoadingIndicator extends StatelessWidget {
  const EventLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: EventsLocalizations.of(context).eventsLoading,
    child: const ExcludeSemantics(child: CircularProgressIndicator()),
  );
}
