import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  test('compares by value', () {
    UnreadNotification notification({
      String id = 'n1',
      String type = 'MailTestResult',
      Map<String, Object?> payload = const {'outcome': 'sent'},
      int day = 12,
    }) => UnreadNotification(
      id: id,
      type: type,
      payload: payload,
      createdAt: DateTime.utc(2026, 11, day),
    );

    expect(notification(), notification());
    for (final other in [
      notification(id: 'n2'),
      notification(type: 'Other'),
      notification(payload: const {'outcome': 'failed'}),
      notification(day: 13),
    ]) {
      expect(other, isNot(notification()));
    }
  });
}
