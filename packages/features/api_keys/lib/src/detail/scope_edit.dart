import 'package:api_keys/src/widgets/scope_picker.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:models/domain.dart';

// What an edit of a key's permissions sends, and what it must have
// confirmed (#1028). Pure, so the rules are tested without a screen.

/// The scopes [key] holds whose permission [grantable] still has, those
/// limited to one record among them: what the picker starts from, and what a
/// change of permissions is measured against (#1028). One the user may no
/// longer give is left out, so it never rides along in what is sent.
List<ApiKeyScope> heldGrantable(
  ApiKey key,
  Map<String, GrantablePermission> grantable,
) => [
  for (final scope in key.scopes)
    if (grantable.containsKey(scope.slug)) scope,
];

/// The scopes a save sends for [picks], or null when they are what [key]
/// holds: an edit replaces the key's whole list, so it goes only when the
/// user changed it (#1028).
///
/// What goes is the picks, and every scope the key holds limited to one
/// record, as it was, less any the user may no longer give, which the server
/// would refuse. They are compared with what the key holds as a set of
/// permission and record.
List<ApiKeyScope>? scopesToSend(
  ApiKey key,
  Map<String, GrantablePermission> grantable,
  List<ApiKeyScope> picks,
) {
  final sent = <ApiKeyScope>{
    for (final scope in picks)
      if (grantable.containsKey(scope.slug)) scope,
    for (final scope in key.scopes)
      if (scope.pinned && grantable.containsKey(scope.slug)) scope,
  };
  if (setEquals(sent, heldGrantable(key, grantable).toSet())) return null;
  return sent.toList();
}

/// The Critical permissions among [scopes] that [key] doesn't hold yet, in
/// [grantable]'s order: what a save must have confirmed (#1028). Matched by
/// permission, as the server matches them, so one the key holds already,
/// limited to one record or not, asks for nothing again.
List<GrantablePermission> newCritical(
  ApiKey key,
  List<ApiKeyScope> scopes,
  Map<String, GrantablePermission> grantable,
) {
  final held = {for (final scope in key.scopes) scope.slug};
  return [
    for (final permission in criticalIn(
      PickedScopes(scopes),
      grantable.values.toList(),
    ))
      if (!held.contains(permission.slug)) permission,
  ];
}
