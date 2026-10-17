/// Whose unsent changes the sign-in screen mentions on one server, and how
/// many there are (#142).
///
/// When a session ends without the user signing out, whether the server
/// rejected it or the app had to sign out to recover, their queued offline
/// changes stay on the device (#147) and nothing on the sign-in screen says
/// so. This is what lets it.
///
/// ## Where it lives
///
/// The per-server scope, not the user's. It has to answer on the sign-in
/// screen, after the user's scope has been torn down, and at a cold start,
/// before anyone has signed in.
///
/// ## What it may touch
///
/// It counts sync-queue rows and never writes them, so nothing here can
/// send or change a change outside its owner's session. The one thing it
/// writes is its own record of whose changes to count.
///
/// ## Whose changes it counts
///
/// A session's start records its user, and a deliberate sign-out retires
/// them, so any other ending leaves them recorded. That includes the app
/// being killed while they were signed in and the server rejecting the
/// session at the next launch: no one is in memory to name then, so the
/// record has to be written while someone is.
///
/// Of the users recorded, the count is the latest one's who still has
/// something unsent. On a shared device, A may leave changes behind and B
/// may then lose a session with changes of their own. The count is then
/// B's, because the person in front of the screen is most likely B, and
/// B's sign-in is the one that would send it. When B signs out on purpose,
/// it goes back to A's.
///
/// The screen never learns who it is, only the count. On a shared device,
/// the next person to see that screen may not be the user who left the
/// changes behind.
abstract class UnsentChangesNoticeRepository {
  /// [userId]'s session on this server has started. Records them as the
  /// latest user, leaving everyone recorded before them in place.
  Future<void> recordSessionStarted(String userId);

  /// [userId] signed out on purpose. Retires their record: a deliberate
  /// sign-out shows no notice. Anyone recorded before them is counted again.
  Future<void> recordSignedOut(String userId);

  /// How many of one user's changes haven't reached the server: the latest
  /// recorded user who has any.
  ///
  /// Counts every entry in their queue that hasn't completed, including
  /// those parked at the retry limit, which haven't reached the server
  /// either. Zero when no recorded user has anything unsent.
  Future<int> unsentChangesCount();
}
