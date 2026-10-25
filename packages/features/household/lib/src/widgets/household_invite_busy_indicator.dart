import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

/// An invite row's spinner while an action runs (#487), announced in words.
class HouseholdInviteBusyIndicator extends StatelessWidget {
  const HouseholdInviteBusyIndicator({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: HouseholdLocalizations.of(context).householdInviteBusy,
    liveRegion: true,
    child: ExcludeSemantics(
      child: SizedBox.square(
        dimension: BgeTokens.of(context).spaceLg,
        child: const CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}
