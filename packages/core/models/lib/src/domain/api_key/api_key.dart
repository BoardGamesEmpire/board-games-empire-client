import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:models/src/domain/api_key/api_key_scope.dart';

part 'api_key.freezed.dart';

/// An API key the signed-in user made, as the server lists it (#1028).
///
/// Online-only: read whenever a screen opens and never stored on the device.
/// The secret is not part of this type. The server shows it once, when the key
/// is created, and it arrives in a `CreatedApiKey`.
@freezed
abstract class ApiKey with _$ApiKey {
  const factory ApiKey({
    required String id,
    required List<ApiKeyScope> scopes,
    required bool enabled,
    required DateTime createdAt,

    /// What the user called the key. Null on a key the server has no name for.
    String? name,

    /// The first characters of the secret, for telling keys apart.
    String? start,

    /// When the key stops working. Null for a key that never expires.
    DateTime? expiresAt,

    /// Null for a key that has not been used.
    DateTime? lastUsedAt,
  }) = _ApiKey;
}
