import 'package:equatable/equatable.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

/// What a Sign-in methods row is called (#582). The screen turns each label
/// into copy; a removed provider's id is never shown.
sealed class SignInMethodLabel extends Equatable {
  const SignInMethodLabel();
}

/// The row that holds the user's password.
final class PasswordLabel extends SignInMethodLabel {
  const PasswordLabel();

  @override
  List<Object?> get props => const [];
}

/// A provider the server's discovery still lists, named as discovery names it.
final class ProviderLabel extends SignInMethodLabel {
  const ProviderLabel(this.displayName);

  final String displayName;

  @override
  List<Object?> get props => [displayName];
}

/// A provider the server no longer lists.
final class RemovedProviderLabel extends SignInMethodLabel {
  const RemovedProviderLabel();

  @override
  List<Object?> get props => const [];
}

/// One row of the Sign-in methods screen, with what the screen needs to
/// offer, or withhold, Unlink (#582).
final class SignInMethodRow extends Equatable {
  const SignInMethodRow({
    required this.method,
    required this.label,
    required this.isWayIn,
    required this.canUnlink,
    required this.unlinkIsLastWayIn,
  });

  final SignInMethod method;
  final SignInMethodLabel label;

  /// Whether this row counts as a way in: a password while the server offers
  /// email and password sign-in, or a provider discovery still lists.
  final bool isWayIn;

  /// False for the password row, and for a provider row whose removal would
  /// leave no way in.
  final bool canUnlink;

  /// A provider row whose Unlink is withheld because it is the last way in.
  final bool unlinkIsLastWayIn;

  @override
  List<Object?> get props => [
    method,
    label,
    isWayIn,
    canUnlink,
    unlinkIsLastWayIn,
  ];
}

/// Describes [methods] against what discovery lists in [strategies] (#582).
///
/// Rows run password first, then listed providers in discovery order, then
/// removed providers. `linkable` is every strategy with no row, in discovery
/// order. A provider row offers Unlink only while another way in remains, so
/// a removed provider alone is withheld too.
///
/// The password row counts as a way in only while [passwordSignInOffered]:
/// a server that has turned email and password sign-in off refuses the
/// password, as it does a provider it no longer lists. The server's own
/// guard counts rows, so it would let the last working provider go.
({List<SignInMethodRow> rows, List<OidcStrategy> linkable})
describeSignInMethods(
  List<SignInMethod> methods,
  List<OidcStrategy> strategies, {
  required bool passwordSignInOffered,
}) {
  final password = methods.where((m) => m.isPassword).toList();
  final providers = methods.where((m) => !m.isPassword).toList();
  bool isListed(SignInMethod m) =>
      strategies.any((s) => s.providerId == m.providerId);

  final listed = [
    for (final strategy in strategies)
      for (final method in providers)
        if (method.providerId == strategy.providerId) (method, strategy),
  ];
  final removed = providers.where((m) => !isListed(m)).toList();
  final waysIn = (passwordSignInOffered ? password.length : 0) + listed.length;

  SignInMethodRow providerRow(SignInMethod method, SignInMethodLabel label) {
    final isWayIn = label is ProviderLabel;
    final canUnlink = waysIn - (isWayIn ? 1 : 0) >= 1;
    return SignInMethodRow(
      method: method,
      label: label,
      isWayIn: isWayIn,
      canUnlink: canUnlink,
      unlinkIsLastWayIn: !canUnlink,
    );
  }

  final rows = [
    for (final method in password)
      SignInMethodRow(
        method: method,
        label: const PasswordLabel(),
        isWayIn: passwordSignInOffered,
        canUnlink: false,
        unlinkIsLastWayIn: false,
      ),
    for (final (method, strategy) in listed)
      providerRow(method, ProviderLabel(strategy.displayName)),
    for (final method in removed)
      providerRow(method, const RemovedProviderLabel()),
  ];

  final linked = {for (final m in methods) m.providerId};
  return (
    rows: rows,
    linkable: [
      for (final strategy in strategies)
        if (!linked.contains(strategy.providerId)) strategy,
    ],
  );
}
