import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:flutter/material.dart';

/// One choice the nominate dialog offers: what it nominates for, how it is
/// named, and whether, and why, it can't be chosen.
typedef NominateScopeChoice = ({
  NominationScope scope,
  String label,
  NominateTaken taken,
});

/// Asks whether a nomination of the game named [title], as its pool row
/// names it, with its subtitle where it has one (#851), is for the whole
/// event or for one of its dates (#517), and answers the scope chosen, or
/// null when cancelled.
///
/// Each of [choices] is a radio button, in order. One taken already is
/// disabled and says why under its name: nominated already, which the server
/// doesn't stop for one copy and one choice (backend#1214), or its game in
/// the lineup for it. So the client doesn't offer it. The first choice not
/// taken is chosen as the dialog opens; the caller opens it only while one is
/// left.
///
/// Scrollable, since at 2.0 text a long title and the dates can outgrow a
/// phone's height. Nominating takes nothing away, so Nominate is drawn as an
/// ordinary button, not a destructive one.
Future<NominationScope?> showNominateScopeDialog(
  BuildContext context, {
  required String title,
  required List<NominateScopeChoice> choices,
}) => showDialog<NominationScope>(
  context: context,
  builder: (_) => _NominateScopeDialog(title: title, choices: choices),
);

class _NominateScopeDialog extends StatefulWidget {
  const _NominateScopeDialog({required this.title, required this.choices});

  final String title;
  final List<NominateScopeChoice> choices;

  @override
  State<_NominateScopeDialog> createState() => _NominateScopeDialogState();
}

class _NominateScopeDialogState extends State<_NominateScopeDialog> {
  NominationScope? _chosen;

  @override
  void initState() {
    super.initState();
    _chosen = widget.choices
        .where((choice) => choice.taken == NominateTaken.no)
        .firstOrNull
        ?.scope;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final chosen = _chosen;
    final title = l10n.eventsNominateTitle(widget.title);

    return AlertDialog(
      scrollable: true,
      // Without it the dialog has no name on iOS and macOS (#762).
      semanticLabel: title,
      title: Text(title),
      content: RadioGroup<NominationScope>(
        groupValue: chosen,
        onChanged: (scope) {
          if (scope != null) setState(() => _chosen = scope);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final choice in widget.choices)
              RadioListTile<NominationScope>(
                key: EventDetailScreen.nominateScopeKey(switch (choice.scope) {
                  WholeEventScope() => null,
                  DateScope(:final occurrenceId) => occurrenceId,
                }),
                value: choice.scope,
                enabled: choice.taken == NominateTaken.no,
                contentPadding: EdgeInsets.zero,
                title: Text(choice.label),
                subtitle: switch (choice.taken) {
                  NominateTaken.no => null,
                  NominateTaken.nominated => Text(l10n.eventsNominateAlready),
                  NominateTaken.inLineup => Text(l10n.eventsNominateInLineup),
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.eventsNominateCancel),
        ),
        TextButton(
          key: EventDetailScreen.nominateConfirmKey,
          onPressed: chosen == null
              ? null
              : () => Navigator.of(context).pop(chosen),
          child: Text(l10n.eventsNominateConfirm),
        ),
      ],
    );
  }
}
