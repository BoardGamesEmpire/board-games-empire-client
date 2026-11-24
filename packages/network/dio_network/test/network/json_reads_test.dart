import 'package:dio_network/src/network/json_reads.dart';
import 'package:dio_network/src/network/user_projection.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _formatException(String message) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', message),
);

void main() {
  group('requireObject', () {
    test('returns the map', () {
      final object = <String, dynamic>{'id': 'e1'};
      expect(requireObject(object, 'event'), same(object));
    });

    test('names the field and the type', () {
      expect(
        () => requireObject(null, 'event'),
        _formatException('"event" is Null, expected an object'),
      );
      expect(
        () => requireObject('x', 'platformGame.game'),
        _formatException('"platformGame.game" is String, expected an object'),
      );
    });

    test('reads an absent key and a null one alike', () {
      final absent = <String, dynamic>{};
      final explicitNull = <String, dynamic>{'event': null};
      for (final body in [absent, explicitNull]) {
        expect(
          () => requireObject(body['event'], 'event'),
          _formatException('"event" is Null, expected an object'),
        );
      }
    });
  });

  group('dateOrNull', () {
    test('reads null as null', () {
      expect(dateOrNull(null), isNull);
    });

    test('parses an ISO-8601 string', () {
      expect(
        dateOrNull('2026-11-23T00:00:00.000Z'),
        DateTime.utc(2026, 11, 23),
      );
    });

    test('throws a TypeError for a value that is not a string', () {
      expect(() => dateOrNull(42), throwsA(isA<TypeError>()));
    });
  });

  group('readRoleName', () {
    test('reads a null projection as no role', () {
      expect(readRoleName(null, row: 'attendee'), isNull);
    });

    test('reads the nested role name', () {
      expect(
        readRoleName({
          'role': {'name': 'Owner'},
        }, row: 'attendee'),
        'Owner',
      );
    });

    test('throws for a projection that is not an object', () {
      expect(
        () => readRoleName('x', row: 'attendee'),
        _formatException(
          'attendee "role" is String, expected the embedded role projection',
        ),
      );
    });

    test('throws for a projection without its nested role', () {
      expect(
        () => readRoleName(<String, dynamic>{}, row: 'attendee'),
        _formatException(
          'attendee "role" projection is missing its nested "role" object, '
          'got Null',
        ),
      );
    });

    test('throws for a role without a string name', () {
      expect(
        () => readRoleName({'role': <String, dynamic>{}}, row: 'attendee'),
        _formatException('attendee role is missing a "name", got Null'),
      );
    });

    test('names the row it was given', () {
      expect(
        () => readRoleName('x', row: 'member'),
        _formatException(
          'member "role" is String, expected the embedded role projection',
        ),
      );
    });
  });
}
