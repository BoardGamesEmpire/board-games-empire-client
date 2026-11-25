import 'package:api_keys/src/widgets/scope_picker.dart';
import 'package:equatable/equatable.dart';

/// Input to the page that makes an API key (#1028).
///
/// None carries a key's secret: that is only ever in the state the server's
/// answer makes.
sealed class ApiKeyCreateEvent extends Equatable {
  const ApiKeyCreateEvent();

  @override
  List<Object?> get props => [];
}

/// Read the permissions the user may give a key from the server.
final class ApiKeyCreateStarted extends ApiKeyCreateEvent {
  const ApiKeyCreateStarted();
}

/// Make the key. The page has checked the form, and asked the user about
/// any Critical permission already.
final class ApiKeyCreateSubmitted extends ApiKeyCreateEvent {
  const ApiKeyCreateSubmitted({
    required this.name,
    required this.selection,
    required this.days,
    this.confirmCritical = false,
  });

  /// The key's name.
  final String name;

  /// The permissions the key is to hold.
  final ScopeSelection selection;

  /// How many days from now the key lasts.
  final int days;

  /// Whether the user said yes to the key holding a Critical permission.
  /// Sent to the server only when set.
  final bool confirmCritical;

  @override
  List<Object?> get props => [name, selection, days, confirmCritical];
}

/// Retire the last create's failure: what it described has changed.
final class ApiKeyCreateFailureCleared extends ApiKeyCreateEvent {
  const ApiKeyCreateFailureCleared();
}
