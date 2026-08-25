import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

Map<String, dynamic> _envelope({
  List<Map<String, dynamic>> rows = const [],
  Map<String, dynamic>? pagination,
}) => {
  'widgets': rows,
  'pagination':
      pagination ??
      const {
        'page': 1,
        'limit': 25,
        'total': 0,
        'totalPages': 0,
        'hasMore': false,
      },
};

void main() {
  group('PaginationMeta.fromJson', () {
    test('reads the backend list envelope', () {
      final meta = PaginationMeta.fromJson(const {
        'page': 2,
        'limit': 25,
        'total': 137,
        'totalPages': 6,
        'hasMore': true,
      });

      expect(meta.page, 2);
      expect(meta.limit, 25);
      expect(meta.total, 137);
      expect(meta.totalPages, 6);
      expect(meta.hasMore, isTrue);
    });

    test('throws FormatException naming the field when one is missing', () {
      expect(
        () => PaginationMeta.fromJson(const {
          'page': 1,
          'limit': 25,
          'total': 0,
          'totalPages': 0,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('hasMore'),
          ),
        ),
      );
    });
  });

  group('PaginatedResult.fromEnvelope', () {
    test('maps every row under the resource key and reads the meta', () {
      final result = PaginatedResult.fromEnvelope(
        _envelope(
          rows: [
            {'id': 'a'},
            {'id': 'b'},
          ],
          pagination: const {
            'page': 1,
            'limit': 25,
            'total': 2,
            'totalPages': 1,
            'hasMore': false,
          },
        ),
        key: 'widgets',
        item: (json) => json['id'] as String,
      );

      expect(result.items, ['a', 'b']);
      expect(result.meta.total, 2);
      expect(result.meta.hasMore, isFalse);
    });

    test('throws FormatException when a row is not an object', () {
      // The documented contract is FormatException for anything that is not
      // the API's own shape. A raw TypeError escaping here would be caught by
      // whatever `on Object` net the caller happens to have, and the next
      // consumer of this shared type may not have one.
      expect(
        () => PaginatedResult.fromEnvelope(
          _envelope(rows: const [])..['widgets'] = const ['oops'],
          key: 'widgets',
          item: (json) => json,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('widgets'),
          ),
        ),
      );
    });

    test('throws FormatException when the resource key is absent', () {
      expect(
        () => PaginatedResult.fromEnvelope(
          _envelope(),
          key: 'households',
          item: (json) => json,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('households'),
          ),
        ),
      );
    });
  });
}
