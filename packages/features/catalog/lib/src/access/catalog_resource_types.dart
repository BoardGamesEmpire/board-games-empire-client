import 'package:models/domain.dart' show ResourceType;

/// The resource types the catalog's screens ask the caller-access reader
/// about (#713): whether the caller may read and import a game.
///
/// The composition roots hand this to `CallerAccessInstaller`, so the
/// session asks the server once about exactly the types these screens gate
/// their controls on.
const Set<ResourceType> catalogResourceTypes = {ResourceType.game};
