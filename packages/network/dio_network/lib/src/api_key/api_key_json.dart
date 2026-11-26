import 'package:dio_network/src/network/json_reads.dart';
import 'package:models/domain.dart';

/// One scope as the create and edit requests carry it (#1028).
///
/// An unpinned scope leaves `resourceId` out of the JSON. The server refuses
/// both `null` and an empty string there, so the key is never written with a
/// null.
Map<String, Object?> apiKeyScopeToJson(ApiKeyScope scope) => {
  'slug': scope.slug,
  'resourceId': ?scope.resourceId,
};

/// A scope as the server lists it on a key. `resourceId` is `null` on the wire
/// for a scope that covers every record.
ApiKeyScope apiKeyScopeFromJson(Map<String, Object?> json) => ApiKeyScope(
  slug: _string(json['slug'], 'slug'),
  resourceId: _stringOrNull(json['resourceId'], 'resourceId'),
);

/// A key as the server lists it (#1028).
///
/// `name`, `start`, `expiresAt` and `lastUsedAt` may be missing or `null`.
/// Dates are ISO-8601 strings, and a trailing `Z` keeps them in UTC. A wrong
/// type or an unparseable date throws, which the caller's `parseRemote` files
/// as the server breaking the contract.
ApiKey apiKeyFromJson(Map<String, Object?> json) {
  final scopes = json['scopes'];
  if (scopes is! List) {
    throw FormatException('"scopes" is ${scopes.runtimeType}, expected a list');
  }
  return ApiKey(
    id: _string(json['id'], 'id'),
    name: _stringOrNull(json['name'], 'name'),
    start: _stringOrNull(json['start'], 'start'),
    scopes: [
      for (final scope in scopes)
        apiKeyScopeFromJson(requireObject(scope, 'scopes[]')),
    ],
    expiresAt: dateOrNull(json['expiresAt']),
    enabled: _bool(json['enabled'], 'enabled'),
    lastUsedAt: dateOrNull(json['lastUsedAt']),
    createdAt: DateTime.parse(_string(json['createdAt'], 'createdAt')),
  );
}

/// One grantable permission. A `riskLevel` this client does not know degrades
/// to [RiskLevel.unknown], rather than failing the whole list.
GrantablePermission grantablePermissionFromJson(Map<String, Object?> json) =>
    GrantablePermission(
      slug: _string(json['slug'], 'slug'),
      description: _string(json['description'], 'description'),
      riskLevel: RiskLevel.fromWire(
        _stringOrNull(json['riskLevel'], 'riskLevel'),
      ),
      pinnable: _bool(json['pinnable'], 'pinnable'),
    );

// The readers name the field and the type found, never the value: a failed
// read must not put a response body, which may hold a secret, in a message.

String _string(Object? raw, String field) {
  if (raw is! String) {
    throw FormatException('"$field" is ${raw.runtimeType}, expected a string');
  }
  return raw;
}

String? _stringOrNull(Object? raw, String field) =>
    raw == null ? null : _string(raw, field);

bool _bool(Object? raw, String field) {
  if (raw is! bool) {
    throw FormatException('"$field" is ${raw.runtimeType}, expected a bool');
  }
  return raw;
}
