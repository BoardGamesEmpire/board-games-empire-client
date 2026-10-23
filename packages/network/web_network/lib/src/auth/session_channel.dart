/// What one tab tells the others happened to the shared session cookie
/// (#432).
///
/// The kind of change and nothing else. A receiving tab never takes a
/// message's word for *who* is signed in: it re-reads the cookie for that.
/// A message naming a user would be a second, unverified answer to a
/// question the session endpoint already answers, and a stale or forged one
/// would be believed.
enum SessionChange {
  /// This tab's credential grant replaced the cookie.
  signedIn,

  /// This tab signed out. Its revocation may still be in flight, or may have
  /// failed; a receiver cannot tell which, and treats it as failed.
  signedOut,
}

/// The transport that carries [SessionChange]s between tabs of one origin
/// (#432).
///
/// A `BroadcastChannel` in the browser, which `web_network` cannot name: it
/// reaches `dart:js_interop`, and this package compiles for every target.
/// `web_platform` supplies the real one, and tests supply a fake.
///
/// A message posted here reaches every other channel of the same name in
/// the origin, including another one in the same page, and never the
/// channel that posted it. Delivery is not guaranteed to a frozen or
/// discarded page, which is why the session monitor re-checks on focus as
/// well.
abstract interface class SessionChannel {
  /// Sends [change] to every other tab.
  void post(SessionChange change);

  /// What the other tabs post. Messages this channel cannot read are
  /// dropped rather than surfaced as errors: they come from another build of
  /// the app, and nothing here can act on them.
  Stream<SessionChange> get changes;

  /// Stops listening. Nothing is delivered afterwards.
  Future<void> close();
}

/// The browser half of the session monitor, supplied by `web_platform`
/// (#432).
///
/// Both are factories rather than values, so nothing browser-side is opened
/// until a server scope is built, and each scope opens its own.
final class WebSessionBindings {
  const WebSessionBindings({
    required this.openChannel,
    required this.attention,
  });

  /// Opens the channel the monitor posts and listens on, under [name].
  final SessionChannel Function(String name) openChannel;

  /// A stream that fires when the page regains the user's attention: the
  /// window gaining focus, or the page turning visible.
  ///
  /// Once per return to the page, after it lost focus or was hidden. The
  /// monitor reads the cookie for every event, so a return that fires both
  /// must arrive as one.
  final Stream<void> Function() attention;
}
