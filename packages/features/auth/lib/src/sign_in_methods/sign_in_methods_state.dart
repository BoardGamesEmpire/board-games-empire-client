import 'package:auth/src/sign_in_methods/sign_in_method_rows.dart';
import 'package:equatable/equatable.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart' show OidcStrategy;

enum SignInMethodsStatus { loading, loaded, loadFailed }

/// How the last link or unlink ended, for the screen to word (#582). It
/// carries reasons, never text.
sealed class SignInMethodsOutcome extends Equatable {
  const SignInMethodsOutcome();
}

/// The provider is now linked.
final class SignInMethodLinked extends SignInMethodsOutcome {
  const SignInMethodLinked(this.providerId);

  final String providerId;

  @override
  List<Object?> get props => [providerId];
}

/// The method named by [label] was unlinked.
final class SignInMethodUnlinked extends SignInMethodsOutcome {
  const SignInMethodUnlinked(this.label);

  final SignInMethodLabel label;

  @override
  List<Object?> get props => [label];
}

/// A link was refused or failed. [providerId] is null when a return trip
/// did not say which provider.
final class SignInMethodLinkFailed extends SignInMethodsOutcome {
  const SignInMethodLinkFailed(this.providerId, this.reason, {this.retryAfter});

  final String? providerId;
  final ProviderLinkFailureReason reason;
  final Duration? retryAfter;

  @override
  List<Object?> get props => [providerId, reason, retryAfter];
}

/// An unlink was refused or failed.
final class SignInMethodUnlinkFailed extends SignInMethodsOutcome {
  const SignInMethodUnlinkFailed(this.reason, {this.retryAfter});

  final ProviderLinkFailureReason reason;
  final Duration? retryAfter;

  @override
  List<Object?> get props => [reason, retryAfter];
}

final class SignInMethodsState extends Equatable {
  const SignInMethodsState({
    required this.status,
    required this.linkSupported,
    this.rows = const [],
    this.linkable = const [],
    this.linkingProviderId,
    this.unlinkingId,
    this.outcome,
  });

  final SignInMethodsStatus status;
  final List<SignInMethodRow> rows;
  final List<OidcStrategy> linkable;

  /// Whether this device can start a link (#582).
  final bool linkSupported;

  /// The provider whose link is out, or null.
  final String? linkingProviderId;

  /// The row id whose unlink is out, or null.
  final String? unlinkingId;

  final SignInMethodsOutcome? outcome;

  /// This state with the fields given changed. [linkingProviderId],
  /// [unlinkingId] and [outcome] are given as a function so each can be set
  /// back to null.
  SignInMethodsState copyWith({
    SignInMethodsStatus? status,
    List<SignInMethodRow>? rows,
    List<OidcStrategy>? linkable,
    String? Function()? linkingProviderId,
    String? Function()? unlinkingId,
    SignInMethodsOutcome? Function()? outcome,
  }) => SignInMethodsState(
    status: status ?? this.status,
    linkSupported: linkSupported,
    rows: rows ?? this.rows,
    linkable: linkable ?? this.linkable,
    linkingProviderId: linkingProviderId == null
        ? this.linkingProviderId
        : linkingProviderId(),
    unlinkingId: unlinkingId == null ? this.unlinkingId : unlinkingId(),
    outcome: outcome == null ? this.outcome : outcome(),
  );

  @override
  List<Object?> get props => [
    status,
    rows,
    linkable,
    linkSupported,
    linkingProviderId,
    unlinkingId,
    outcome,
  ];
}
