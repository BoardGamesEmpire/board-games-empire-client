import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Which of the loaded keys the list shows (#1028).
enum ApiKeyStatusFilter { all, enabled, disabled }

/// Where the key list's read of page 1 stands.
enum ApiKeyListStatus { loading, loaded, loadFailed }

/// The key list (#1028): the pages loaded so far, newest first as the server
/// orders them, and the permissions the user may grant, by slug.
final class ApiKeyListState extends Equatable {
  const ApiKeyListState({
    this.status = ApiKeyListStatus.loading,
    this.keys = const [],
    this.hasMore = false,
    this.loadingMore = false,
    this.moreFailed = false,
    this.refreshing = false,
    this.refreshFailed = false,
    this.filter = ApiKeyStatusFilter.all,
    this.grantable,
  });

  final ApiKeyListStatus status;

  /// Every key loaded so far, whatever the [filter].
  final List<ApiKey> keys;

  /// Whether the server has a page after the last one loaded.
  final bool hasMore;

  /// Whether the next page is being read.
  final bool loadingMore;

  /// Whether the last read of the next page failed. The loaded keys stay.
  final bool moreFailed;

  /// Whether page 1 is being read again over the loaded keys, which stay
  /// shown meanwhile.
  final bool refreshing;

  /// Whether the last read of page 1 over loaded keys failed. The keys stay
  /// shown, and may be out of date, until a read succeeds.
  final bool refreshFailed;

  final ApiKeyStatusFilter filter;

  /// The permissions the user may grant, by slug, read with page 1. Null
  /// until that read answers, and when it failed: the rows then give a count
  /// of permissions without a risk level.
  final Map<String, GrantablePermission>? grantable;

  /// The loaded keys [filter] lets through, in the server's order.
  List<ApiKey> get visible => switch (filter) {
    ApiKeyStatusFilter.all => keys,
    ApiKeyStatusFilter.enabled => [
      for (final key in keys)
        if (key.enabled) key,
    ],
    ApiKeyStatusFilter.disabled => [
      for (final key in keys)
        if (!key.enabled) key,
    ],
  };

  /// A copy with the fields given. [grantable] takes a function, so that a
  /// copy can set it to null.
  ApiKeyListState copyWith({
    ApiKeyListStatus? status,
    List<ApiKey>? keys,
    bool? hasMore,
    bool? loadingMore,
    bool? moreFailed,
    bool? refreshing,
    bool? refreshFailed,
    ApiKeyStatusFilter? filter,
    Map<String, GrantablePermission>? Function()? grantable,
  }) => ApiKeyListState(
    status: status ?? this.status,
    keys: keys ?? this.keys,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailed: moreFailed ?? this.moreFailed,
    refreshing: refreshing ?? this.refreshing,
    refreshFailed: refreshFailed ?? this.refreshFailed,
    filter: filter ?? this.filter,
    grantable: grantable == null ? this.grantable : grantable(),
  );

  @override
  List<Object?> get props => [
    status,
    keys,
    hasMore,
    loadingMore,
    moreFailed,
    refreshing,
    refreshFailed,
    filter,
    grantable,
  ];
}
