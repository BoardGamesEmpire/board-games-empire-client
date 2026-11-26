import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:models/domain.dart';

/// A key's permissions in words, for its row on the key list (#1028).
///
/// - No scopes: the key works nowhere, and the words say so.
/// - [grantable] known, and holding at least one of the scopes' slugs: the
///   count and the highest risk level among them, "3 permissions, highest
///   risk High".
/// - Otherwise the count alone, "3 permissions".
///
/// The count is every scope the key holds. A scope whose slug [grantable]
/// doesn't have, or whose level this client doesn't know, counts towards it
/// but not towards the highest risk.
String scopeSummary(
  ApiKeysLocalizations l10n,
  List<ApiKeyScope> scopes,
  Map<String, GrantablePermission>? grantable,
) {
  if (scopes.isEmpty) return l10n.apiKeyNoScopes;
  final highest = grantable == null
      ? null
      : highestRisk(
          scopes.map((scope) => grantable[scope.slug]?.riskLevel),
        );
  if (highest == null) return l10n.apiKeyScopeCount(scopes.length);
  return l10n.apiKeyScopeCountWithRisk(
    scopes.length,
    riskLevelLabel(l10n, highest),
  );
}

/// The highest of [levels], or null when none is a level this client ranks.
///
/// [RiskLevel.unknown] and nulls are passed over: `unknown` comes after
/// `critical` in the enum, so the enum's order is not the ranking.
RiskLevel? highestRisk(Iterable<RiskLevel?> levels) {
  RiskLevel? highest;
  var highestRank = -1;
  for (final level in levels) {
    final rank = riskRank(level);
    if (rank > highestRank) {
      highest = level;
      highestRank = rank;
    }
  }
  return highest;
}

/// Where [level] ranks, from 0 for Low to 3 for Critical, and -1 for a level
/// this client doesn't know or a missing one, which never ranks.
int riskRank(RiskLevel? level) => switch (level) {
  RiskLevel.low => 0,
  RiskLevel.medium => 1,
  RiskLevel.high => 2,
  RiskLevel.critical => 3,
  RiskLevel.unknown || null => -1,
};

/// The name of [level], in words: risk is never told by colour alone.
String riskLevelLabel(ApiKeysLocalizations l10n, RiskLevel level) =>
    switch (level) {
      RiskLevel.low => l10n.apiKeyRiskLow,
      RiskLevel.medium => l10n.apiKeyRiskMedium,
      RiskLevel.high => l10n.apiKeyRiskHigh,
      RiskLevel.critical => l10n.apiKeyRiskCritical,
      RiskLevel.unknown => l10n.apiKeyRiskUnknown,
    };
