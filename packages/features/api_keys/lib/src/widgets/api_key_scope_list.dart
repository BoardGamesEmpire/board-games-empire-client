import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:api_keys/src/widgets/scope_summary.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';

/// Every permission an API key holds, on the key's own page (#1028), in the
/// key's order.
///
/// Each row is read as one: what the permission allows, from [grantable],
/// its risk level in words ("Risk: Critical"), never by colour alone, and
/// its code. Then:
///
/// - a scope whose slug [grantable] doesn't have shows its slug and "No
///   longer available": the user may no longer give it;
/// - a scope limited to one record adds "Limited to one record". A pin can
///   only be made through the API, so this page shows it and nothing more.
///
/// A null [grantable] means its read failed, which says nothing of whether a
/// permission is still available. A line says the descriptions couldn't be
/// loaded, and each row shows its slug, with no risk level and never "No
/// longer available".
///
/// With no scopes, it says the key works nowhere until it is given some.
///
/// The rows are facts, not controls: no tap, no focus stop and no outline.
class ApiKeyScopeList extends StatelessWidget {
  const ApiKeyScopeList({
    required this.scopes,
    required this.grantable,
    super.key,
  });

  final List<ApiKeyScope> scopes;

  /// The permissions the user may grant, by slug, or null when they
  /// couldn't be read.
  final Map<String, GrantablePermission>? grantable;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final grantable = this.grantable;
    if (scopes.isEmpty) return Text(l10n.apiKeyScopesEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (grantable == null) Text(l10n.apiKeyScopesUndescribed),
        for (final scope in scopes)
          _ScopeRow(
            scope: scope,
            described: grantable != null,
            permission: grantable?[scope.slug],
          ),
      ],
    );
  }
}

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
    required this.scope,
    required this.described,
    required this.permission,
  });

  final ApiKeyScope scope;

  /// Whether the grantable permissions were read, so that a [permission]
  /// that is null means the user may no longer give it.
  final bool described;

  /// What the scope's slug allows, when the user may still give it.
  final GrantablePermission? permission;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final permission = this.permission;
    final lines = [
      if (permission != null) ...[
        Text(
          l10n.apiKeyScopeRisk(riskLevelLabel(l10n, permission.riskLevel)),
        ),
        Text(scope.slug, style: small),
      ] else if (described)
        Text(l10n.apiKeyScopeNoLongerAvailable),
      if (scope.pinned) Text(l10n.apiKeyScopePinned),
    ];

    return MergeSemantics(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(permission?.description ?? scope.slug),
        // A scope shown by its slug alone, unpinned, has nothing to add, and
        // takes a one-line row.
        subtitle: lines.isEmpty
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: lines,
              ),
      ),
    );
  }
}
