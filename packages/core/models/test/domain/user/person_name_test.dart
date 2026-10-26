import 'package:test/test.dart';
import 'package:models/domain.dart';

void main() {
  group('personName', () {
    test('the display name wins over the username', () {
      expect(
        personName(displayName: 'Alex Doe', username: 'alexd'),
        'Alex Doe',
      );
    });

    test('a blank display name falls back to the username', () {
      expect(personName(displayName: '   ', username: 'alexd'), 'alexd');
      expect(personName(displayName: '', username: 'alexd'), 'alexd');
    });

    test('names are trimmed', () {
      expect(personName(displayName: ' Alex ', username: null), 'Alex');
      expect(personName(displayName: null, username: ' alexd '), 'alexd');
    });

    test('nothing usable is null', () {
      expect(personName(displayName: null, username: ' '), isNull);
      expect(personName(), isNull);
    });
  });
}
