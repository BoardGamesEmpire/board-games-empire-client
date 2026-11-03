import 'package:equatable/equatable.dart';

import 'access_extent.dart';
import 'resource_access.dart';
import 'resource_type.dart';

/// What the server says the caller may do, by resource type (#456).
///
/// Either unknown (no answer yet, or none that survived) or known. An unknown
/// answer allows nothing, so a control that needs access stays hidden until
/// the server has said yes.
final class CallerAccess extends Equatable {
  /// No answer yet.
  const CallerAccess.unknown() : _types = null;

  /// The server's answer. A type it leaves out allows nothing.
  const CallerAccess.known(Map<ResourceType, ResourceAccess> types)
    : _types = types;

  final Map<ResourceType, ResourceAccess>? _types;

  bool get isKnown => _types != null;

  /// Whether [action] is open on [type]: false while unknown, or when the
  /// answer lacks [type].
  bool allows(ResourceType type, AccessAction action) =>
      _types?[type]?.of(action).allows ?? false;

  /// Whether the answer is known and every action on every type is
  /// [AccessExtent.none]. True for an empty answer.
  bool get deniesEverything {
    final types = _types;
    if (types == null) {
      return false;
    }
    return types.values.every(
      (access) =>
          AccessAction.values.every((action) => !access.of(action).allows),
    );
  }

  @override
  List<Object?> get props => [_types];
}
