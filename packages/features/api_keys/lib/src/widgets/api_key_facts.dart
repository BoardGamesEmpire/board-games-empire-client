import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:models/domain.dart';

/// What [key] is called wherever it is named (#1028): its name, or "Unnamed
/// key" for one made outside the app without a name.
String apiKeyNameOf(ApiKeysLocalizations l10n, ApiKey key) =>
    key.name ?? l10n.apiKeyUnnamed;

/// The facts a key's row on the list and its own page both give, a line of
/// text each (#1028).
///
/// - `start`: the start of its secret, or null when the server sent none;
/// - `expiry`: when it expires;
/// - `lastUsed`: when it was last used, or that it never was.
///
/// Dates are shown in the device's zone.
typedef ApiKeyFactLines = ({String? start, String expiry, String lastUsed});

/// [key]'s [ApiKeyFactLines], in [l10n]'s words.
ApiKeyFactLines apiKeyFactLines(ApiKeysLocalizations l10n, ApiKey key) {
  final start = key.start;
  final expiresAt = key.expiresAt;
  final lastUsedAt = key.lastUsedAt;
  return (
    start: start == null ? null : l10n.apiKeyStart(start),
    expiry: expiresAt == null
        ? l10n.apiKeyNeverExpires
        : l10n.apiKeyExpires(expiresAt.toLocal()),
    lastUsed: lastUsedAt == null
        ? l10n.apiKeyNeverUsed
        : l10n.apiKeyLastUsed(lastUsedAt.toLocal()),
  );
}
