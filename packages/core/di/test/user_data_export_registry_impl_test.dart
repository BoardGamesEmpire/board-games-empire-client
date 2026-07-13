import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';

final class _StubExporter implements UserDataExporter {
  _StubExporter(this.key);

  @override
  final String key;

  @override
  String get categoryNameKey => '${key}CategoryName';

  @override
  String get descriptionKey => '${key}Description';

  @override
  Future<Map<String, Object?>?> export(ServerContext context) async => null;
}

void main() {
  group('UserDataExportRegistryImpl', () {
    late UserDataExportRegistryImpl registry;

    setUp(() {
      registry = UserDataExportRegistryImpl();
    });

    test('starts empty', () {
      expect(registry.exporters, isEmpty);
    });

    test('exposes registered exporters in registration order', () {
      final profile = _StubExporter('profile');
      final collection = _StubExporter('gameCollection');

      registry
        ..register(profile)
        ..register(collection);

      expect(registry.exporters, [profile, collection]);
    });

    test('exporters view is unmodifiable', () {
      registry.register(_StubExporter('profile'));

      expect(
        () => registry.exporters.add(_StubExporter('other')),
        throwsUnsupportedError,
      );
    });

    test('duplicate key throws ArgumentError and registers nothing', () {
      final original = _StubExporter('profile');
      registry.register(original);

      expect(
        () => registry.register(_StubExporter('profile')),
        throwsArgumentError,
      );
      expect(registry.exporters, [original]);
    });

    test('distinct keys still register after a duplicate rejection', () {
      registry.register(_StubExporter('profile'));
      expect(
        () => registry.register(_StubExporter('profile')),
        throwsArgumentError,
      );

      final collection = _StubExporter('gameCollection');
      registry.register(collection);

      expect(registry.exporters, hasLength(2));
      expect(registry.exporters.last, collection);
    });
  });
}
