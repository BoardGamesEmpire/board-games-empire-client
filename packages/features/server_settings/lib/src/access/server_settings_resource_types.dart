import 'package:models/domain.dart' show ResourceType;

/// The resource types the server settings screen asks the caller-access
/// reader about (#807).
///
/// The composition roots hand this to `CallerAccessInstaller`, so the session
/// asks the server once about exactly the types this screen gates its
/// controls on.
const Set<ResourceType> serverSettingsResourceTypes = {
  ResourceType.systemSetting,
};
