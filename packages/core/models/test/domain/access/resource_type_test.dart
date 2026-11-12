import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  test('systemSetting is spelled as the server spells it', () {
    expect(ResourceType.systemSetting.wireName, 'SystemSetting');
  });
}
