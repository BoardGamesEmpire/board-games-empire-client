import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

DateTime get _now => DateTime.parse('2024-01-15T10:30:00Z');

Household _make({
  DateTime? deletedAt,
  bool isDirty = false,
  bool isLocalOnly = false,
}) => Household(
  id: 'hh_1',
  name: 'Test Household',
  isDirty: isDirty,
  isLocalOnly: isLocalOnly,
  deletedAt: deletedAt,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  group('Household', () {
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

    group('sync-state flags', () {
      test('default to false', () {
        final h = _make();
        expect(h.isDirty, isFalse);
        expect(h.isLocalOnly, isFalse);
      });

      test('copyWith toggles isDirty and isLocalOnly independently', () {
        final h = _make();
        expect(h.copyWith(isLocalOnly: true).isLocalOnly, isTrue);
        expect(h.copyWith(isLocalOnly: true).isDirty, isFalse);
        expect(h.copyWith(isDirty: true).isDirty, isTrue);
        expect(h.copyWith(isDirty: true).isLocalOnly, isFalse);
      });
    });

    test('JSON round-trip preserves fields and sync flags', () {
      final h = Household(
        id: 'hh_1',
        name: 'Test Household',
        description: 'A place to play',
        image: 'https://example.test/hh.png',
        isDirty: true,
        isLocalOnly: true,
        createdAt: _now,
        updatedAt: _now,
      );

      final round = Household.fromJson(h.toJson());
      expect(round, equals(h));
      expect(round.isDirty, isTrue);
      expect(round.isLocalOnly, isTrue);
    });

    test('fromJson defaults sync flags when the server omits them', () {
      // Server payloads never carry the client-only sync flags; the
      // model must default them rather than throw.
      final round = Household.fromJson(const {
        'id': 'hh_1',
        'name': 'Server Household',
        'createdAt': '2024-01-15T10:30:00.000Z',
        'updatedAt': '2024-01-15T10:30:00.000Z',
      });
      expect(round.isDirty, isFalse);
      expect(round.isLocalOnly, isFalse);
    });
  });
}
