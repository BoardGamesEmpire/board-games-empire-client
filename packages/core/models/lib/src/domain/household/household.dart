import 'package:freezed_annotation/freezed_annotation.dart';

part 'household.freezed.dart';
part 'household.g.dart';

@freezed
abstract class Household with _$Household {
  const Household._();

  const factory Household({
    required String id,
    required String name,
    String? description,
    String? image,
    DateTime? deletedAt,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _Household;

  factory Household.fromJson(Map<String, dynamic> json) =>
      _$HouseholdFromJson(json);

  bool get isDeleted => deletedAt != null;
}
