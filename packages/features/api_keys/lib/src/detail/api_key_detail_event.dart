import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Input to a key's own page (#1028).
sealed class ApiKeyDetailEvent extends Equatable {
  const ApiKeyDetailEvent();

  @override
  List<Object?> get props => [];
}

/// Read the key and the permissions the user may grant from the server.
final class ApiKeyDetailRequested extends ApiKeyDetailEvent {
  const ApiKeyDetailRequested();
}

/// Turn the key on or off, straight away: re-enabling a key asks for nothing.
final class ApiKeyEnabledChanged extends ApiKeyDetailEvent {
  const ApiKeyEnabledChanged({required this.enabled});

  final bool enabled;

  @override
  List<Object?> get props => [enabled];
}

/// Delete the key. The page has asked the user already.
final class ApiKeyDeleteRequested extends ApiKeyDetailEvent {
  const ApiKeyDeleteRequested();
}

/// Save what the page's form changed, straight away (#1028).
///
/// Each part is null when the user left it as the key has it, and is then
/// not sent. All of them null is nothing to save, and sends nothing.
final class ApiKeySaveRequested extends ApiKeyDetailEvent {
  const ApiKeySaveRequested({
    this.name,
    this.scopes,
    this.expiresInDays,
    this.confirmCritical = false,
  });

  /// The new name, trimmed.
  final String? name;

  /// The key's whole new list of scopes. Only sent when the user changed the
  /// permissions: an edit replaces the whole list, and one the user may no
  /// longer give would be refused.
  final List<ApiKeyScope>? scopes;

  /// The new lifetime, in days from now.
  final int? expiresInDays;

  /// Whether the user said yes to the key being given a Critical permission
  /// it doesn't hold yet. Sent to the server only when set, and no change on
  /// its own.
  final bool confirmCritical;

  @override
  List<Object?> get props => [name, scopes, expiresInDays, confirmCritical];
}

/// Retire the last write's outcome.
final class ApiKeyDetailOutcomeCleared extends ApiKeyDetailEvent {
  const ApiKeyDetailOutcomeCleared();
}
