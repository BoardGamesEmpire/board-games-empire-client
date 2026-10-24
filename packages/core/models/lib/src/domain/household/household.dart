import 'package:freezed_annotation/freezed_annotation.dart';

import 'household_settings.dart';

part 'household.freezed.dart';
part 'household.g.dart';

/// A household a user belongs to.
///
/// Read-cached from the server. A create is applied locally first and
/// enqueued for server sync, mirroring [GameCollection]. An edit is not:
/// it is sent straight to the server, and the server's answer is cached
/// (#476).
///
/// Soft delete: [deletedAt] is the canonical tombstone marker. A row
/// with `deletedAt != null` is awaiting remote confirmation before
/// being purged.
@freezed
abstract class Household with _$Household {
  const Household._();

  const factory Household({
    required String id,
    required String name,
    String? description,
    String? image,

    /// The household's settings. Null when this client has not read them
    /// yet: a row cached before they were, or a server answer that carries
    /// none, such as the create answer.
    HouseholdSettings? settings,

    /// True when this household has local changes not yet synced to the
    /// server.
    @Default(false) bool isDirty,

    /// True when this household was created offline / optimistically and
    /// has not yet been confirmed by the server. The create path (#39)
    /// sets this on the optimistic row and clears it on reconcile, once
    /// the server assigns the canonical id.
    @Default(false) bool isLocalOnly,

    DateTime? deletedAt,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _Household;

  factory Household.fromJson(Map<String, dynamic> json) =>
      _$HouseholdFromJson(json);

  /// True iff [deletedAt] is set (tombstoned).
  bool get isDeleted => deletedAt != null;
}
