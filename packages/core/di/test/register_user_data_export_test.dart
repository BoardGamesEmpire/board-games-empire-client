import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:models/domain.dart';

final class _StubExporter implements UserDataExporter {
  _StubExporter(this.key);

  @override
  final String key;

  @override
  String get categoryNameKey => '${key}CategoryName';

  @override
  String get descriptionKey => '${key}Description';

  @override
  Future<UserDataExport?> export(
    ActiveServer server, {
    bool refresh = false,
  }) async => null;
}

const _buildInfo = BuildInfo(
  version: '0.1.0',
  buildNumber: '42',
  appName: 'Board Games Empire',
  packageName: 'com.example.bge',
);

void main() {
  group('registerUserDataExport', () {
    late DependencyContainerImpl container;

    setUp(() => container = DependencyContainerImpl());
    tearDown(() => container.dispose());

    test('registers the exporters in order', () {
      final profile = _StubExporter('profile');
      final collection = _StubExporter('gameCollection');

      registerUserDataExport(container, exporters: [profile, collection]);

      expect(container.get<UserDataExportRegistry>().exporters, [
        profile,
        collection,
      ]);
    });

    test('the bundler resolves lazily, after BuildInfo', () {
      registerUserDataExport(container, exporters: const []);
      container.registerSingleton<BuildInfo>(_buildInfo);

      expect(container.get<UserDataExportBundler>(), isNotNull);
    });
  });
}
