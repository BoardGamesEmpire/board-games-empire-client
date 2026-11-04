import 'package:models/domain.dart' show ResourceType;

/// The resource types the DataGateway screens ask the caller-access reader
/// about (#456).
///
/// The composition roots hand this to `CallerAccessInstaller`, so the
/// session asks the server once about exactly the types these screens
/// gate their controls on.
const Set<ResourceType> dataGatewayResourceTypes = {ResourceType.dataGateway};
