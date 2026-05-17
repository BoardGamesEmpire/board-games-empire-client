import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

DateTime get _now => DateTime.parse('2024-01-15T10:30:00Z');

PlatformGame _make({int? minPlayers, int? maxPlayers}) => PlatformGame(
  id: 'pg_1',
  gameId: 'g_1',
  platformId: 'plat_1',
  platformName: 'Tabletop',
  minPlayers: minPlayers,
  maxPlayers: maxPlayers,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  group('PlatformGame', () {
    group('resolvedMinPlayers', () {
      test('returns the platform override when set', () {
        // Override wins over the parent value even when both differ
        // (override = 2, parent = 4).
        expect(_make(minPlayers: 2).resolvedMinPlayers(4), equals(2));
      });

      test('falls back to the parent value when override is null', () {
        expect(_make().resolvedMinPlayers(4), equals(4));
      });

      test('returns null when both override and parent are null', () {
        expect(_make().resolvedMinPlayers(null), isNull);
      });

      test('override of 0 is still preferred over a non-null parent '
          '(?? semantic, not truthy-style fallback)', () {
        // The implementation uses `minPlayers ?? gameMinPlayers`,
        // which only falls back on null — NOT on a falsy/zero
        // value. A zero override is a valid platform-specific
        // "this platform supports zero-player runs" declaration
        // and must be preserved. If a future refactor switched
        // to a truthy check (`minPlayers != null && minPlayers > 0
        // ? minPlayers : gameMinPlayers`), this test would fail.
        expect(_make(minPlayers: 0).resolvedMinPlayers(4), equals(0));
      });
    });

    group('resolvedMaxPlayers', () {
      test('returns the platform override when set', () {
        expect(_make(maxPlayers: 6).resolvedMaxPlayers(4), equals(6));
      });

      test('falls back to the parent value when override is null', () {
        expect(_make().resolvedMaxPlayers(8), equals(8));
      });

      test('returns null when both override and parent are null', () {
        expect(_make().resolvedMaxPlayers(null), isNull);
      });

      test('override of 0 is preferred over a non-null parent '
          '(same ?? semantic as resolvedMinPlayers)', () {
        expect(_make(maxPlayers: 0).resolvedMaxPlayers(8), equals(0));
      });
    });
  });
}
