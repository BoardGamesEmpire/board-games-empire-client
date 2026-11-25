import 'package:api_keys/api_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';

void main() {
  const max = ApiKeyRemoteDataSource.maxNameLength;

  /// The control holding [name], with every check run.
  FormControl<String> holding(String? name) =>
      apiKeyNameControl()..value = name;

  group('apiKeyNameControl', () {
    test('starts empty, or with the name it is given', () {
      expect(apiKeyNameControl().value, isNull);
      expect(apiKeyNameControl(initial: 'CI deploy').value, 'CI deploy');
      expect(apiKeyNameControl(initial: 'CI deploy').valid, isTrue);
    });

    test('a name is required', () {
      for (final empty in [null, '', '   ']) {
        final control = holding(empty);

        expect(control.invalid, isTrue, reason: '"$empty"');
        expect(
          control.hasError(ValidationMessage.required),
          isTrue,
          reason: '"$empty"',
        );
      }
    });

    test('$max characters are the most it takes', () {
      expect(max, 32);
      expect(holding('a' * max).valid, isTrue);

      final long = holding('a' * (max + 1));
      expect(long.invalid, isTrue);
      expect(long.hasError(ApiKeyNameErrors.tooLong), isTrue);
      expect(long.hasError(ValidationMessage.required), isFalse);
    });

    test('spaces at either end are not counted, as the server trims them', () {
      expect(holding('  ${'a' * max}  ').valid, isTrue);
      expect(holding('  ${'a' * (max + 1)}  ').invalid, isTrue);
    });

    test('length is counted in UTF-16 units, as String.length gives it', () {
      // One die face is two units: sixteen of them are 32, seventeen 34.
      const die = '\u{1F3B2}';
      expect(die.length, 2);

      expect(holding(die * 16).valid, isTrue);
      expect(
        holding(die * 17).hasError(ApiKeyNameErrors.tooLong),
        isTrue,
      );
    });
  });
}
