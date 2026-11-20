import 'package:auth/src/sign_in_methods/sign_in_method_rows.dart';
import 'package:equatable/equatable.dart';
import 'package:models/domain.dart' show OidcStrategy;

sealed class SignInMethodsEvent extends Equatable {
  const SignInMethodsEvent();

  @override
  List<Object?> get props => const [];
}

/// Loads the list, and retries a failed load (#582). The first one also
/// reads the result of a link attempt that arrived with the page load.
final class SignInMethodsRequested extends SignInMethodsEvent {
  const SignInMethodsRequested();
}

/// A write to the server: a link or an unlink. One is out at a time (#582),
/// so the bloc handles them as one stream and drops any that arrive while
/// another is out.
sealed class SignInMethodWriteRequested extends SignInMethodsEvent {
  const SignInMethodWriteRequested();
}

/// Starts linking the provider [strategy] names (#582).
final class SignInMethodLinkRequested extends SignInMethodWriteRequested {
  const SignInMethodLinkRequested(this.strategy);

  final OidcStrategy strategy;

  @override
  List<Object?> get props => [strategy];
}

/// Unlinks [row] (#582).
final class SignInMethodUnlinkRequested extends SignInMethodWriteRequested {
  const SignInMethodUnlinkRequested(this.row);

  final SignInMethodRow row;

  @override
  List<Object?> get props => [row];
}

/// Retires the outcome the screen has shown (#582).
final class SignInMethodsOutcomeCleared extends SignInMethodsEvent {
  const SignInMethodsOutcomeCleared();
}
