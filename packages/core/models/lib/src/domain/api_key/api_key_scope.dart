import 'package:freezed_annotation/freezed_annotation.dart';

part 'api_key_scope.freezed.dart';

/// One permission an API key holds (#1028).
///
/// A scope is a permission [slug], optionally pinned to a single record. A
/// pin can only be made through the API: the screens show it, keep it through
/// an edit, and never offer to create one.
@freezed
abstract class ApiKeyScope with _$ApiKeyScope {
  const factory ApiKeyScope({
    required String slug,

    /// The one record the permission is limited to. Null when it covers every
    /// record the key's owner may reach.
    String? resourceId,
  }) = _ApiKeyScope;
  const ApiKeyScope._();

  /// Whether the permission is limited to one record.
  bool get pinned => resourceId != null;
}
