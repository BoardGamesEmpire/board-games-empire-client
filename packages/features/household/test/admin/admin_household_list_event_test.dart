import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';

void main() {
  group('AdminHouseholdListEvent (#685)', () {
    test('an event with nothing to carry equals any other of its kind', () {
      const load = AdminHouseholdListLoadRequested();
      const more = AdminHouseholdListMoreRequested();
      const dismissed = AdminHouseholdListOutcomeDismissed();

      for (final event in [load, more, dismissed]) {
        expect(event.props, isEmpty);
      }
      expect(load.hashCode, const AdminHouseholdListLoadRequested().hashCode);
      expect(load, isNot(more));
      expect(more, isNot(dismissed));
    });

    test('a search change is equal by the text typed', () {
      final text = ['a', 'b'].join();

      expect(AdminHouseholdListSearchChanged(text).props, ['ab']);
      expect(
        AdminHouseholdListSearchChanged(text),
        const AdminHouseholdListSearchChanged('ab'),
      );
      expect(
        AdminHouseholdListSearchChanged(text),
        isNot(const AdminHouseholdListSearchChanged('ab ')),
      );
    });

    test('a settled search is equal by its text, and is not a change', () {
      final text = ['a', 'b'].join();

      expect(AdminHouseholdListSearchSettled(text).props, ['ab']);
      expect(
        AdminHouseholdListSearchSettled(text),
        const AdminHouseholdListSearchSettled('ab'),
      );
      expect(
        AdminHouseholdListSearchSettled(text),
        isNot(const AdminHouseholdListSearchSettled('abc')),
      );
      expect(
        AdminHouseholdListSearchSettled(text),
        isNot(const AdminHouseholdListSearchChanged('ab')),
      );
    });

    test('a status change is equal by its status', () {
      final status = AdminHouseholdStatus.values.byName('deleted');

      expect(AdminHouseholdListStatusChanged(status).props, [status]);
      expect(
        AdminHouseholdListStatusChanged(status),
        const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
      );
      expect(
        AdminHouseholdListStatusChanged(status),
        isNot(const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all)),
      );
    });

    test('a sort change is equal by its sort', () {
      final sort = AdminHouseholdSort.values.byName('newest');

      expect(AdminHouseholdListSortChanged(sort).props, [sort]);
      expect(
        AdminHouseholdListSortChanged(sort),
        const AdminHouseholdListSortChanged(AdminHouseholdSort.newest),
      );
      expect(
        AdminHouseholdListSortChanged(sort),
        isNot(const AdminHouseholdListSortChanged(AdminHouseholdSort.members)),
      );
    });

    test('a restore request is equal by its household id', () {
      final id = ['h', '1'].join();

      expect(AdminHouseholdListRestoreRequested(id).props, ['h1']);
      expect(
        AdminHouseholdListRestoreRequested(id),
        const AdminHouseholdListRestoreRequested('h1'),
      );
      expect(
        AdminHouseholdListRestoreRequested(id),
        isNot(const AdminHouseholdListRestoreRequested('h2')),
      );
    });
  });
}
