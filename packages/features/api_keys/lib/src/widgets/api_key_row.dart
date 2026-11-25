import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:api_keys/src/widgets/api_key_facts.dart';
import 'package:api_keys/src/widgets/scope_summary.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';

/// One key on the key list (#1028): its name, then a line each for the start
/// of its secret, its permissions in words, its expiry, whether it is enabled,
/// and when it was last used. Tapping it opens the key's own page.
///
/// Every fact is in words, enabled or disabled included, so nothing is told
/// by colour alone. The lines sit under the name, not in `trailing`, so they
/// wrap at 320dp and 200% text. The tile and its lines are one semantics
/// node, read as one, with the tap on it.
class ApiKeyRow extends StatelessWidget {
  const ApiKeyRow({
    required this.apiKey,
    required this.grantable,
    required this.onOpen,
    super.key,
  });

  final ApiKey apiKey;

  /// The permissions the user may grant, by slug, for the highest risk
  /// level. Null when they aren't known: the row gives a count alone.
  final Map<String, GrantablePermission>? grantable;

  /// Opens the key's own page. Null leaves the row inert.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final facts = apiKeyFactLines(l10n, apiKey);
    final start = facts.start;

    // MergeSemantics inside the outline and outside the ring, so the tap and
    // every line are one node, as on the other list rows.
    return BgeOutlinedRow(
      child: MergeSemantics(
        child: BgeRowFocusRing(
          builder: (context, row) => ListTile(
            focusNode: row.focusNode,
            onFocusChange: row.onFocusChange,
            focusColor: row.focusColor,
            onTap: row.onTap(onOpen),
            title: Text(apiKeyNameOf(l10n, apiKey)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (start != null) Text(start),
                Text(scopeSummary(l10n, apiKey.scopes, grantable)),
                Text(facts.expiry),
                Text(apiKey.enabled ? l10n.apiKeyEnabled : l10n.apiKeyDisabled),
                Text(facts.lastUsed),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
