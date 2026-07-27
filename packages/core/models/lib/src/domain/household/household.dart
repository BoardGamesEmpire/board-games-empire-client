import 'package:freezed_annotation/freezed_annotation.dart';

part 'household.freezed.dart';
part 'household.g.dart';

/// A household a user belongs to.
///
/// Read-cached from the server today; user-initiated creation lands in
/// Phase 4 (#27). Create/update writes are applied locally first and
/// enqueued for server sync, mirroring [GameCollection].
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
