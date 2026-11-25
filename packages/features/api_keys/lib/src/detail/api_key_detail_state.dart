import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Where the read of a key's own page stands (#1028).
enum ApiKeyDetailStatus {
  loading,
  loaded,
  loadFailed,

  /// The server has no such key: it was deleted, or it expired, which
  /// deletes it.
  gone,
}

/// A change a key's page sends to the server (#1028). One is on its way at a
/// time.
enum ApiKeyWrite {
  /// Enabling or disabling the key.
  toggle,

  /// Deleting the key.
  delete,
}

/// What the last write answered, for the page to say (#1028).
///
/// A toggle that went through has no words: the switch shows the key as the
/// server answered it.
sealed class ApiKeyDetailOutcome extends Equatable {
  const ApiKeyDetailOutcome();

  @override
  List<Object?> get props => [];
}

/// The server deleted the key. The page says so and leaves.
final class ApiKeyDetailDeleted extends ApiKeyDetailOutcome {
  const ApiKeyDetailDeleted();
}

/// The [write] failed, for the reason [failure] gives. The key is as it was.
final class ApiKeyDetailFailed extends ApiKeyDetailOutcome {
  const ApiKeyDetailFailed(this.failure, {required this.write});

  final ApiKeyFailure failure;
  final ApiKeyWrite write;

  @override
  List<Object?> get props => [failure, write];
}

/// One API key's own page (#1028): the key, what each permission it holds
/// allows, and the write on its way, if any.
final class ApiKeyDetailState extends Equatable {
  const ApiKeyDetailState({
    this.status = ApiKeyDetailStatus.loading,
    this.key,
    this.grantable,
    this.writing,
    this.outcome,
    this.deleted = false,
  });

  final ApiKeyDetailStatus status;

  /// The key as the server last answered it. Null until it has loaded, and
  /// once it is gone.
  final ApiKey? key;

  /// The permissions the user may grant, by slug, read with the key: what
  /// gives each of the key's scopes its description and risk level. Null
  /// when that read failed, which never fails the page: the scopes then show
  /// their slugs.
  final Map<String, GrantablePermission>? grantable;

  /// The write on its way, or null.
  final ApiKeyWrite? writing;

  /// What the last write answered, until it is retired.
  final ApiKeyDetailOutcome? outcome;

  /// Whether the server deleted the key. The page is leaving then, and holds
  /// [key] as it last drew it on the way out. Nothing more is sent.
  final bool deleted;

  /// A copy with the fields given. The nullable fields take a function, so
  /// that a copy can set them to null.
  ApiKeyDetailState copyWith({
    ApiKeyDetailStatus? status,
    ApiKey? key,
    Map<String, GrantablePermission>? Function()? grantable,
    ApiKeyWrite? Function()? writing,
    ApiKeyDetailOutcome? Function()? outcome,
    bool? deleted,
  }) => ApiKeyDetailState(
    status: status ?? this.status,
    key: key ?? this.key,
    grantable: grantable == null ? this.grantable : grantable(),
    writing: writing == null ? this.writing : writing(),
    outcome: outcome == null ? this.outcome : outcome(),
    deleted: deleted ?? this.deleted,
  );

  @override
  List<Object?> get props => [
    status,
    key,
    grantable,
    writing,
    outcome,
    deleted,
  ];
}
