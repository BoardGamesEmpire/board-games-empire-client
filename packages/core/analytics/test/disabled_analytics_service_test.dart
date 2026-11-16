import 'package:analytics/analytics.dart';
import 'package:test/test.dart';

import 'support/catalog_samples.dart';

void main() {
  test('records every catalog event without throwing', () {
    const service = DisabledAnalyticsService();
    for (final e in catalogSamples) {
      expect(() => service.record(e), returnsNormally);
    }
  });

  test('is a const AnalyticsService', () {
    expect(
      identical(
        const DisabledAnalyticsService(),
        const DisabledAnalyticsService(),
      ),
      isTrue,
    );
    expect(const DisabledAnalyticsService(), isA<AnalyticsService>());
  });
}
