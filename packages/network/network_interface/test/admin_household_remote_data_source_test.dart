import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('AdminHouseholdRemoteDataSource.queryLength', () {
    int length(String text) => AdminHouseholdRemoteDataSource.queryLength(text);

    test('counts plain text by code unit', () {
      expect(length('ab'), 2);
      expect(length(''), 0);
    });

    test('counts a surrogate pair once, as the server does', () {
      expect(length('\u{1F600}'), 1);
      expect(length('a\u{1F600}'), 2);
    });

    test('counts a presentation sequence once', () {
      expect(length('\u{2764}\u{FE0F}'), 1);
    });
  });
}
