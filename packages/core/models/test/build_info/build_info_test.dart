import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

/// Red-phase tests for the `BuildInfo` value (issue #35).
///
/// `BuildInfo` is an immutable, JSON-serializable value (not a service):
/// it's read once at startup and consumed synchronously by version
/// negotiation (#13), and serialized into feedback reports (#69) and the
/// #11 export bundle (`bgeClientVersion`). The JSON assertions check
/// round-trip symmetry and value presence rather than exact key strings,
/// so they don't pin the package-wide json_serializable field-rename
/// config. Deliberate deferral: the JSON key names become a wire
/// contract only when the first wire consumer lands (#69 feedback DTO /
/// #11 `bgeClientVersion`) — pin them with explicit key assertions then,
/// or a future field_rename would silently change the wire keys while
/// this round-trip stays green.
void main() {
  const sample = BuildInfo(
    version: '1.2.3',
    buildNumber: '42',
    appName: 'Board Games Empire',
    packageName: 'com.boardgamesempire.app',
  );

  group('BuildInfo', () {
    test('serializes to and from JSON symmetrically', () {
      final json = sample.toJson();

      expect(json, isA<Map<String, dynamic>>());
      expect(
        json.values,
        containsAll(<String>[
          '1.2.3',
          '42',
          'Board Games Empire',
          'com.boardgamesempire.app',
        ]),
      );
      expect(BuildInfo.fromJson(json), sample);
    });

    test(
      'values with identical fields are equal (Freezed value semantics)',
      () {
        const other = BuildInfo(
          version: '1.2.3',
          buildNumber: '42',
          appName: 'Board Games Empire',
          packageName: 'com.boardgamesempire.app',
        );

        expect(other, sample);
        expect(other.hashCode, sample.hashCode);
      },
    );

    group('unknown', () {
      test('carries legible, semver-parseable fallback values', () {
        expect(BuildInfo.unknown.version, '0.0.0');
        expect(BuildInfo.unknown.buildNumber, '0');
        expect(BuildInfo.unknown.appName, 'Unknown App Name');
        expect(BuildInfo.unknown.packageName, 'Unknown Package Name');
      });

      test('is a canonical const value', () {
        expect(identical(BuildInfo.unknown, BuildInfo.unknown), isTrue);
      });
    });
  });
}
