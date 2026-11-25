import 'package:models/domain.dart';
import 'package:test/test.dart';

ApiKey _key({List<ApiKeyScope> scopes = const []}) => ApiKey(
  id: 'k_1',
  scopes: scopes,
  enabled: true,
  createdAt: DateTime.utc(2026, 11, 24),
);

void main() {
  group('RiskLevel.fromWire (#1028)', () {
    test('maps the four levels and unknown', () {
      expect(RiskLevel.fromWire('Low'), RiskLevel.low);
      expect(RiskLevel.fromWire('Medium'), RiskLevel.medium);
      expect(RiskLevel.fromWire('High'), RiskLevel.high);
      expect(RiskLevel.fromWire('Critical'), RiskLevel.critical);
      expect(RiskLevel.fromWire('critical'), RiskLevel.unknown);
      expect(RiskLevel.fromWire('Severe'), RiskLevel.unknown);
      expect(RiskLevel.fromWire(null), RiskLevel.unknown);
    });
  });

  group('ApiKeyScope (#1028)', () {
    test('pinned follows resourceId', () {
      expect(const ApiKeyScope(slug: 'game:read').pinned, isFalse);
      expect(
        const ApiKeyScope(slug: 'game:read', resourceId: 'g_1').pinned,
        isTrue,
      );
    });

    test('compares by slug and resourceId', () {
      expect(
        const ApiKeyScope(slug: 'a', resourceId: 'r'),
        const ApiKeyScope(slug: 'a', resourceId: 'r'),
      );
      expect(
        const ApiKeyScope(slug: 'a'),
        isNot(const ApiKeyScope(slug: 'a', resourceId: 'r')),
      );
    });
  });

  group('CreatedApiKey (#1028)', () {
    const secret = 'bge_secret_123';

    test('toString hides the secret', () {
      final created = CreatedApiKey(apiKey: _key(), secret: secret);

      expect(created.toString(), isNot(contains(secret)));
      expect(created.toString(), contains('CreatedApiKey'));
    });

    test('compares by key and secret', () {
      final a = CreatedApiKey(apiKey: _key(), secret: secret);
      final b = CreatedApiKey(apiKey: _key(), secret: secret);
      final other = CreatedApiKey(apiKey: _key(), secret: 'bge_other');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(other));
    });
  });

  group('GrantablePermission (#1028)', () {
    test('compares by value', () {
      const a = GrantablePermission(
        slug: 'game:read',
        description: 'Read games',
        riskLevel: RiskLevel.low,
        pinnable: true,
      );
      const b = GrantablePermission(
        slug: 'game:read',
        description: 'Read games',
        riskLevel: RiskLevel.low,
        pinnable: true,
      );

      expect(a, b);
    });
  });
}
