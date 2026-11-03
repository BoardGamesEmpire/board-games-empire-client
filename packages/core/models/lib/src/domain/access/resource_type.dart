/// A kind of resource the server reports the caller's access to (#456).
///
/// Each feature adds the types it needs. [wireName] is sent as the server
/// spells it, and a name the server doesn't know is a 400, so a type is only
/// added once the server knows it.
enum ResourceType {
  dataGateway('DataGateway');

  const ResourceType(this.wireName);

  /// The name the server uses in `resourceTypes` and in the answer.
  final String wireName;
}
