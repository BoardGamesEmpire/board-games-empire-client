import 'package:equatable/equatable.dart';

import 'package:models/src/domain/access/access_extent.dart';

/// The caller's [AccessExtent] for each [AccessAction] on one resource type
/// (#456).
final class ResourceAccess extends Equatable {
  const ResourceAccess({
    required this.create,
    required this.read,
    required this.update,
    required this.delete,
    required this.manage,
  });

  /// Access to nothing, for every action.
  static const ResourceAccess none = ResourceAccess(
    create: AccessExtent.none,
    read: AccessExtent.none,
    update: AccessExtent.none,
    delete: AccessExtent.none,
    manage: AccessExtent.none,
  );

  final AccessExtent create;
  final AccessExtent read;
  final AccessExtent update;
  final AccessExtent delete;
  final AccessExtent manage;

  /// The extent for [action].
  AccessExtent of(AccessAction action) => switch (action) {
    AccessAction.create => create,
    AccessAction.read => read,
    AccessAction.update => update,
    AccessAction.delete => delete,
    AccessAction.manage => manage,
  };

  @override
  List<Object?> get props => [create, read, update, delete, manage];
}
