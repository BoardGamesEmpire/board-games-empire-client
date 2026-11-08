import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('ExpansionLink', () {
    test('round-trips through JSON', () {
      final json = {'gameId': 'g1', 'isStandalone': true};

      final link = ExpansionLink.fromJson(json);

      expect(link, const ExpansionLink(gameId: 'g1', isStandalone: true));
      expect(link.toJson(), json);
    });
  });
}
