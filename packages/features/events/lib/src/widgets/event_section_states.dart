import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A section's spinner, in its rows' place while there is nothing yet to
/// show. Home's shelf and a household's section use it (#613, #503).
class EventSectionSpinner extends StatelessWidget {
  const EventSectionSpinner({required this.label, super.key});

  /// What is loading, for a screen reader.
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceLg),
    child: Center(child: BgeLoadingState(label: label)),
  );
}

/// A line of text in a section's rows' place. A live region, because it
/// takes the place of the spinner, which said it was loading.
class EventSectionMessage extends StatelessWidget {
  const EventSectionMessage(this.text, {required this.textKey, super.key});

  final String text;

  /// On the text itself.
  final Key textKey;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    child: Text(
      text,
      key: textKey,
      style: Theme.of(context).textTheme.bodyMedium,
    ),
  );
}
