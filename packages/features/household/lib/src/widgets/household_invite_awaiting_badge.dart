import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

/// "Awaiting approval" on an invite (#489), as an icon plus words, never
/// color alone.
///
/// The color is the domain `pending` from [BgeStatusColors], not an accent
/// role. Its paired icon is not [BgeStatusColors.iconFor]'s: that one says a
/// change is queued to sync, and this is a person's decision still to come.
class HouseholdInviteAwaitingBadge extends StatelessWidget {
  const HouseholdInviteAwaitingBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = BgeStatusColors.of(context).pending;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.hourglass_empty,
          // Scales with its label.
          size: MediaQuery.textScalerOf(context)
              .scale(theme.textTheme.labelMedium?.fontSize ?? 0),
          color: color,
        ),
        const BgeGap.xs(axis: Axis.horizontal),
        Flexible(
          child: Text(
            HouseholdLocalizations.of(context).householdInviteStatusAwaiting,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
