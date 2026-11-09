import 'package:models/domain.dart' show ResourceType;

/// The resource types the staff households section asks the caller-access
/// reader about (#684).
///
/// The section is shown on `read: all` of this set. The composition roots
/// hand it to `CallerAccessInstaller` beside the DataGateway types, so the
/// session asks the server once about both sections' types.
const Set<ResourceType> householdAdminResourceTypes = {ResourceType.household};
