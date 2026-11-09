import 'package:equatable/equatable.dart';

import '../common/reach.dart';
import '../user/person_name.dart';
import 'household_member.dart';

/// Which households the staff list shows (#685).
///
/// The names are the server's `status` query values.
enum AdminHouseholdStatus {
  /// Households not deleted.
  live,

  /// Deleted households only, which staff can restore.
  deleted,

  /// Both.
  all;

  /// The value sent as `status`.
  String get wireName => name;
}

/// The order of the staff list (#685).
///
/// The names are the server's `sort` query values.
enum AdminHouseholdSort {
  /// A to Z.
  name,

  /// Most recently created first.
  newest,

  /// Most members first.
  members,

  /// Most recently deleted first, live households last.
  deleted;

  /// The value sent as `sort`. Read through [Enum], since the [name] value
  /// shadows the getter inside this enum.
  String get wireName => (this as Enum).name;

  /// Whether the server accepts this sort with [status]: it answers 400 for
  /// [deleted] with [AdminHouseholdStatus.live], which has no deleted rows to
  /// order.
  bool allowedWith(AdminHouseholdStatus status) =>
      this != AdminHouseholdSort.deleted || status != AdminHouseholdStatus.live;
}

/// A household owner as a row of the staff list names them (#685).
final class AdminHouseholdOwner extends Equatable {
  const AdminHouseholdOwner({
    required this.userId,
    required this.username,
    this.displayName,
  });

  final String userId;
  final String username;

  /// The display name the user chose, null when they have none.
  final String? displayName;

  /// The name to show: [displayName], else [username], trimmed. Null when
  /// both are blank, for the screen to stand in for.
  String? get name => personName(displayName: displayName, username: username);

  @override
  List<Object?> get props => [userId, username, displayName];
}

/// One row of the staff households list (#685): what staff need to find a
/// household and decide whether to restore it, with no roster.
final class AdminHouseholdRow extends Equatable {
  const AdminHouseholdRow({
    required this.id,
    required this.name,
    required this.reach,
    required this.createdAt,
    required this.memberCount,
    required this.owners,
    this.image,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String? image;
  final Reach reach;
  final DateTime createdAt;

  /// When the household was deleted, null while it is live.
  final DateTime? deletedAt;

  /// How many members it has, owners included.
  final int memberCount;

  /// Its household owners, in the order they joined.
  final List<AdminHouseholdOwner> owners;

  bool get isDeleted => deletedAt != null;

  /// This row as it reads once restored: the same, with no [deletedAt].
  AdminHouseholdRow restored() => AdminHouseholdRow(
    id: id,
    name: name,
    image: image,
    reach: reach,
    createdAt: createdAt,
    memberCount: memberCount,
    owners: owners,
  );

  @override
  List<Object?> get props => [
    id,
    name,
    image,
    reach,
    createdAt,
    deletedAt,
    memberCount,
    owners,
  ];
}

/// One household as staff read it from `GET /households/:id` (#685).
final class AdminHouseholdDetail extends Equatable {
  const AdminHouseholdDetail({
    required this.id,
    required this.name,
    required this.reach,
    required this.createdAt,
    required this.members,
    this.description,
    this.image,
    this.languageName,
  });

  final String id;
  final String name;
  final String? description;
  final String? image;
  final Reach reach;

  /// The name of the household's language, null when it has none.
  final String? languageName;
  final DateTime createdAt;
  final List<HouseholdMember> members;

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    image,
    reach,
    languageName,
    createdAt,
    members,
  ];
}
