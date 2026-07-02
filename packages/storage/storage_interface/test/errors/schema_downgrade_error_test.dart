import 'package:storage_interface/storage_interface.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaDowngradeError', () {
    test('exposes the on-disk and supported versions', () {
      const error = SchemaDowngradeError(onDisk: 3, supported: 2);
      expect(error.onDisk, 3);
      expect(error.supported, 2);
    });

    test('is an Exception', () {
      expect(
        const SchemaDowngradeError(onDisk: 2, supported: 1),
        isA<Exception>(),
      );
    });

    test('toString names both versions', () {
      const error = SchemaDowngradeError(onDisk: 5, supported: 3);
      expect(error.toString(), allOf(contains('5'), contains('3')));
    });
  });
}
