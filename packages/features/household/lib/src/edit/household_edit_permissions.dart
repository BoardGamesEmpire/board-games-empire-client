import 'package:models/domain.dart';

/// Who may edit a household's name, description and settings (#476).
///
/// This decides whether a screen offers Edit. The server decides what
/// happens, and its refusal is shown when the two disagree, for instance
/// after the viewer's role changed on another device.
///
/// A stand-in for the role table #483 will build, which should replace it,
/// as it replaces `HouseholdInvitePermissions`. It follows the server's seed:
/// `update:household` is granted on the condition of an owner or admin
/// membership (`permission.catalog.ts`).
abstract final class HouseholdEditPermissions {
  /// Whether a viewer holding [role] may edit [household].
  ///
  /// Never while [Household.isLocalOnly]: the server has not confirmed the
  /// household yet, so an edit would name an id it never issued.
  static bool mayEdit(Household household, HouseholdRole? role) =>
      !household.isLocalOnly &&
      (role == HouseholdRole.householdOwner ||
          role == HouseholdRole.householdAdmin);
}
