import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A centered title and body, with an optional icon: the empty, access-denied
/// and missing surfaces of both DataGateway screens (#41), so a user turned
/// away from the list and from a form reads the same shape.
///
/// One live region, so assistive tech reads the whole answer when it appears.
class DataGatewayMessage extends StatelessWidget {
  const DataGatewayMessage({
    required this.title,
    required this.body,
    this.icon,
    super.key,
  });

  final IconData? icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = this.icon;
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            ExcludeSemantics(
              child: Icon(
                icon,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const BgeGap.md(),
          ],
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const BgeGap.sm(),
          Text(
            body,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
