/// Why a held deep link was given up on, reported to the shell so it can say
/// so (#984).
///
/// The cases are the ones the user can do nothing about by waiting; a link
/// dropped on purpose (its server stopped being active after the switch to
/// it) is not one, because the user has already moved elsewhere.
sealed class DeepLinkFailure {
  const DeepLinkFailure();
}

/// The lookup of the link's server threw, for example on a registry read
/// error.
final class DeepLinkLookupFailed extends DeepLinkFailure {
  const DeepLinkLookupFailed();
}

/// Making the link's server active threw, for example with
/// `ServerCapacityExceededException`.
final class DeepLinkActivationFailed extends DeepLinkFailure {
  const DeepLinkActivationFailed(this.error);

  final Object error;
}
