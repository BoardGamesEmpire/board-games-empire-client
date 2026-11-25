import 'package:meta/meta.dart';
import 'package:models/src/domain/api_key/api_key.dart';

/// A key the server has just made, with the secret it shows only once (#1028).
///
/// A plain class rather than a generated one, because a generated `toString`
/// would print [secret]. The secret stays in memory: it is not stored, logged
/// or sent anywhere, and [toString] leaves it out.
@immutable
final class CreatedApiKey {
  const CreatedApiKey({required this.apiKey, required this.secret});

  /// The key as the server stored it.
  final ApiKey apiKey;

  /// The full key, to show once.
  final String secret;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CreatedApiKey &&
          other.apiKey == apiKey &&
          other.secret == secret;

  @override
  int get hashCode => Object.hash(apiKey, secret);

  @override
  String toString() => 'CreatedApiKey(id: ${apiKey.id})';
}
