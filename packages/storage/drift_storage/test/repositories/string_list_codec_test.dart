import 'dart:convert';

import 'package:drift_storage/src/repositories/string_list_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeStringList', () {
    test('reads back what jsonEncode wrote', () {
      const names = ['Strategy', 'Family', ''];
      expect(decodeStringList(jsonEncode(names)), names);
      expect(decodeStringList('[]'), isEmpty);
    });

    test('reads malformed JSON as an empty list', () {
      expect(decodeStringList('["a",'), isEmpty);
    });

    test('reads a value that is not a list as an empty list', () {
      expect(decodeStringList('{"a":"b"}'), isEmpty);
      expect(decodeStringList('"a"'), isEmpty);
    });

    test('reads a list with an element that is not a string as an empty '
        'list', () {
      expect(decodeStringList('["a", 1]'), isEmpty);
    });
  });
}
