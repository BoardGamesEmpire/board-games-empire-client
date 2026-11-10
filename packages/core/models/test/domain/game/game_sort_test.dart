import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('GameSort', () {
    test("names the orders the server's GET /games takes", () {
      expect(GameSort.values.map((s) => s.wire), ['title', 'newest']);
    });

    test('every value round-trips through its wire name', () {
      for (final sort in GameSort.values) {
        expect(GameSort.fromWire(sort.wire), sort);
      }
    });

    test('anything else reads as none, case included', () {
      expect(GameSort.fromWire(null), isNull);
      expect(GameSort.fromWire(''), isNull);
      expect(GameSort.fromWire('oldest'), isNull);
      expect(GameSort.fromWire('Newest'), isNull);
      expect(GameSort.fromWire('TITLE'), isNull);
    });
  });
}
