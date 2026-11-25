import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Where the read of the permissions the user may give a key stands (#1028).
enum ApiKeyGrantableStatus { loading, loaded, loadFailed }

/// The page that makes an API key (#1028): the permissions on offer, the
/// create on its way, how the last one failed, and the key once it is made.
///
/// [created] holds the new key's secret, and is the only place it is kept:
/// it is in no route argument and nothing restores it, so it goes when the
/// page's bloc does. [toString] leaves it out, so a state printed by a
/// failed test, a debugger or a bloc observer never shows it.
final class ApiKeyCreateState extends Equatable {
  const ApiKeyCreateState({
    this.grantableStatus = ApiKeyGrantableStatus.loading,
    this.grantable = const [],
    this.submitting = false,
    this.failure,
    this.created,
  });

  final ApiKeyGrantableStatus grantableStatus;

  /// The permissions the user may give a key, in the server's order. Empty
  /// until they have loaded.
  final List<GrantablePermission> grantable;

  /// Whether a create is on its way.
  final bool submitting;

  /// Why the last create failed, until it is retired.
  final ApiKeyFailure? failure;

  /// The key the server made, with the secret it shows once. Null until a
  /// create goes through.
  final CreatedApiKey? created;

  /// A copy with the fields given. [failure] takes a function, so that a
  /// copy can set it to null.
  ApiKeyCreateState copyWith({
    ApiKeyGrantableStatus? grantableStatus,
    List<GrantablePermission>? grantable,
    bool? submitting,
    ApiKeyFailure? Function()? failure,
    CreatedApiKey? created,
  }) => ApiKeyCreateState(
    grantableStatus: grantableStatus ?? this.grantableStatus,
    grantable: grantable ?? this.grantable,
    submitting: submitting ?? this.submitting,
    failure: failure == null ? this.failure : failure(),
    created: created ?? this.created,
  );

  @override
  List<Object?> get props => [
    grantableStatus,
    grantable,
    submitting,
    failure,
    created,
  ];

  /// Names the key made by its id, never by its secret.
  @override
  String toString() =>
      'ApiKeyCreateState(grantableStatus: ${grantableStatus.name}, '
      'grantable: ${grantable.length}, submitting: $submitting, '
      'failure: $failure, created: ${created?.apiKey.id})';
}
