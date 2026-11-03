import 'package:models/domain.dart';

/// Maps the `GET /api/users/me/access` body to the access of each asked type
/// (#456).
///
/// Strict on purpose: an asked type the server left out, an action it left
/// out, or an extent this client does not know could each be read as "no
/// access", and a wrong "none" is indistinguishable from a real one. They
/// throw instead, and the caller classifies that as a body that breaks the
/// contract. A type that was not asked about is ignored.
Map<ResourceType, ResourceAccess> callerAccessFromJson(
  Map<String, dynamic> body,
  Set<ResourceType> asked,
) {
  final access = body['access'] as Map<String, dynamic>;
  return {
    for (final type in asked)
      type: _resourceAccessFromJson(
        type,
        access[type.wireName] as Map<String, dynamic>?,
      ),
  };
}

ResourceAccess _resourceAccessFromJson(
  ResourceType type,
  Map<String, dynamic>? json,
) {
  if (json == null) {
    throw FormatException('the answer has no entry for ${type.wireName}');
  }
  AccessExtent extent(AccessAction action) {
    final value = json[action.name];
    return AccessExtent.values.asNameMap()[value] ??
        (throw FormatException(
          '${type.wireName}.${action.name} is $value, not all, some or none',
        ));
  }

  return ResourceAccess(
    create: extent(AccessAction.create),
    read: extent(AccessAction.read),
    update: extent(AccessAction.update),
    delete: extent(AccessAction.delete),
    manage: extent(AccessAction.manage),
  );
}
