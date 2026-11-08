import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/repositories/expansion_links_codec.dart';

void main() {
  group('decodeExpansionLinks', () {
    test('reads back what encodeExpansionLinks wrote', () {
      const links = [
        ExpansionLink(gameId: 'a', isStandalone: false),
        ExpansionLink(gameId: 'b', isStandalone: true),
      ];
      expect(decodeExpansionLinks(encodeExpansionLinks(links)), links);
    });

    test('reads malformed JSON as no links', () {
      expect(decodeExpansionLinks('[{"gameId":'), isEmpty);
    });

    test('reads a value that is not a list as no links', () {
      expect(
        decodeExpansionLinks('{"gameId":"a","isStandalone":false}'),
        isEmpty,
      );
    });

    test('reads a list with an element that is not a map as no links', () {
      expect(
        decodeExpansionLinks('[{"gameId":"a","isStandalone":false}, 1]'),
        isEmpty,
      );
    });
  });
}
