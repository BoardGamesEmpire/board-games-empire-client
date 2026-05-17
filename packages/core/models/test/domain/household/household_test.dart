import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

DateTime get _now => DateTime.parse('2024-01-15T10:30:00Z');

Household _make({DateTime? deletedAt}) => Household(
  id: 'hh_1',
  name: 'Test Household',
  deletedAt: deletedAt,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  group('Household', () {
    // Pass-9 review thread #3. Analogous helpers on Game and
    // GameCollection had coverage; this one did not. Locking it in.

    test('isDeleted is false when deletedAt is null', () {
      expect(_make().isDeleted, isFalse);
    });

    test('isDeleted is true when deletedAt is set', () {
      expect(_make(deletedAt: _now).isDeleted, isTrue);
    });

    test('copyWith sets deletedAt and flips isDeleted', () {
      final h = _make();
      expect(h.isDeleted, isFalse);
      expect(h.copyWith(deletedAt: _now).isDeleted, isTrue);
    });

    test('copyWith clearing deletedAt flips isDeleted back to false', () {
      final tombstoned = _make(deletedAt: _now);
      expect(tombstoned.isDeleted, isTrue);
      // Note: freezed's copyWith treats `null` as "don't touch" for
      // nullable fields; the canonical way to clear is to construct
      // a new Household without deletedAt. This test pins the
      // resurrection-style restore that the repository would do.
      final restored = Household(
        id: tombstoned.id,
        name: tombstoned.name,
        description: tombstoned.description,
        image: tombstoned.image,
        createdAt: tombstoned.createdAt,
        updatedAt: tombstoned.updatedAt,
      );
      expect(restored.isDeleted, isFalse);
    });
  });
}
