import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';

void main() {
  test('the staff households section asks about households only (#684)', () {
    expect(householdAdminResourceTypes, {ResourceType.household});
  });
}
