import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/server_settings.dart';

void main() {
  test('the screen asks about system settings alone (#807)', () {
    expect(serverSettingsResourceTypes, {ResourceType.systemSetting});
  });
}
