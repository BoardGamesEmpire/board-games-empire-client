import 'package:equatable/equatable.dart';

/// A notification the server holds for the caller and they have not read
/// (#807). [type] says how to read [payload].
final class UnreadNotification extends Equatable {
  const UnreadNotification({
    required this.id,
    required this.type,
    required this.payload,
    required this.createdAt,
  });

  final String id;
  final String type;
  final Map<String, Object?> payload;
  final DateTime createdAt;

  @override
  List<Object?> get props => [id, type, payload, createdAt];
}
