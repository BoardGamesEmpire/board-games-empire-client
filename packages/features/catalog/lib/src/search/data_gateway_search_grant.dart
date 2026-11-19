/// Whether this session's searches may ask the DataGateways (#795).
///
/// The server refuses a search that includes them (403) to a user who may not
/// read DataGateways, and says so in its own words. The refusal does not
/// change within a session, so the search asks once, remembers the refusal
/// here, and from then on leaves the DataGateways out of its requests rather
/// than failing first each time.
///
/// One lives for a user session on a server: the installer registers a new
/// one on each sign-in, so a user whose role changes is asked again.
final class DataGatewaySearchGrant {
  /// A signed-in session, which asks the DataGateways until one refuses.
  DataGatewaySearchGrant() : _mayAsk = true;

  /// An anonymous session, which never asks: it may not read DataGateways, so
  /// the request would only be refused (#795).
  DataGatewaySearchGrant.signedOut() : _mayAsk = false;

  bool _mayAsk;
  String? _serverMessage;

  /// Whether a search may include the DataGateways.
  bool get mayAsk => _mayAsk;

  /// The first refusal's message, as the server worded it for this user's
  /// language. Null before a refusal, for a signed-out session, and when the
  /// refusal carried none.
  String? get serverMessage => _serverMessage;

  /// Records a refusal: [mayAsk] is false from now on. The first message
  /// stays, as a later one would only repeat it.
  void refuse(String? serverMessage) {
    if (_mayAsk) _serverMessage = serverMessage;
    _mayAsk = false;
  }
}
