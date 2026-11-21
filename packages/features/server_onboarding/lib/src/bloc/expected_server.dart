import 'package:flutter/foundation.dart' show immutable;

/// The server a server link names (#971): where it says the server is, and
/// which server it says that is.
///
/// Given to `ServerOnboardingBloc`, which refuses an add whose server answers
/// with a different id. The check is tied to [address]: it applies only while
/// the submitted address normalizes to it.
@immutable
final class ExpectedServer {
  const ExpectedServer({required this.address, required this.bgeServerId});

  /// The link's address, already through `normalizeServerUrl`, so it compares
  /// equal to a submitted address that normalizes the same way.
  final String address;

  /// The `bgeServerId` the link names.
  final String bgeServerId;

  @override
  bool operator ==(Object other) =>
      other is ExpectedServer &&
      other.address == address &&
      other.bgeServerId == bgeServerId;

  @override
  int get hashCode => Object.hash(address, bgeServerId);
}
