// Runs on the VM: the web root module's platform-neutral half, which needs
// no sink to register the exporters (#93).
@TestOn('vm')
library;

import 'package:app_shell/app_shell.dart';
import 'package:di/di.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/portability.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:web_platform/web.dart';

class _StubBuildInfoReader implements BuildInfoReader {
  const _StubBuildInfoReader();

  @override
  Future<BuildInfo> read() async => const BuildInfo(
    version: '1.2.3',
    buildNumber: '42',
    appName: 'Board Games Empire',
    packageName: 'com.boardgamesempire.app',
  );
}

void main() {
  testWidgets(
    'every exporter the root registers has labels for both its keys',
    (
      tester,
    ) async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);
      await registerWebRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(),
      );
      final exporters = container.get<UserDataExportRegistry>().exporters;
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            ...ShellLocalizations.localizationsDelegates,
            ...bgeFeatureLocalizationsDelegates,
          ],
          supportedLocales: ShellLocalizations.supportedLocales,
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(exporters, isNotEmpty);
      for (final exporter in exporters) {
        for (final key in [exporter.categoryNameKey, exporter.descriptionKey]) {
          final labels = bgeExportCategoryLabelResolvers
              .map((resolve) => resolve(context, key))
              .nonNulls
              .firstOrNull;
          expect(
            labels,
            isNotNull,
            reason: '${exporter.key}: no labels for $key',
          );
          expect(
            labels!.name,
            isNotEmpty,
            reason: '${exporter.key}: $key name',
          );
          expect(
            labels.description,
            isNotEmpty,
            reason: '${exporter.key}: $key description',
          );
        }
      }
    },
  );
}
