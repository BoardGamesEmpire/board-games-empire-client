import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/notifications/notification_target_location.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:notifications/notifications.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

const _id = 'hh_1';

/// The sent invites on their Declined filter, where a decline shows (#475).
const _sentDeclined = '/invites/sent?filter=declined';

HouseholdMember _viewer(HouseholdRole? role) => HouseholdMember(
  id: 'm-me',
  userId: 'u-me',
  householdId: _id,
  role: role,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// Where each notification target opens (#475). The router's own tests pin
/// that each location builds its screen; this pins which one a target gets.
void main() {
  late _MockHouseholdRepository households;

  setUp(() => households = _MockHouseholdRepository());

  /// The local cache answers [member] for the viewer's role in [_id].
  void viewerIs(HouseholdMember? member) => when(
    () => households.getCurrentUserMember(_id),
  ).thenAnswer((_) async => member);

  test('an invite opens the invite inbox', () async {
    expect(
      await notificationTargetLocation(
        const InviteInboxTarget(),
        households: households,
      ),
      AppRoutes.invites,
    );
  });

  test("a DataGateway notification opens the DataGateway's own page", () async {
    expect(
      await notificationTargetLocation(
        const DataGatewayTarget('gw 1'),
        households: households,
      ),
      AppRoutes.dataGatewayDetailOf('gw 1'),
    );
    expect(
      AppRoutes.dataGatewayDetailOf('gw 1'),
      '/admin/data-gateways/gw%201',
    );
  });

  test('a household notification opens the household', () async {
    expect(
      await notificationTargetLocation(
        const HouseholdTarget(_id),
        households: households,
      ),
      AppRoutes.householdDetailOf(_id),
    );
  });

  test("an invite awaiting approval opens the household's invites on the "
      'awaiting filter', () async {
    expect(
      await notificationTargetLocation(
        const HouseholdInvitesTarget(_id, awaitingApproval: true),
        households: households,
      ),
      AppRoutes.householdInvitesOf(_id, awaitingApproval: true),
    );
  });

  test("a household's invites open on Open when not asked for the awaiting "
      'filter', () async {
    expect(
      await notificationTargetLocation(
        const HouseholdInvitesTarget(_id, awaitingApproval: false),
        households: households,
      ),
      AppRoutes.householdInvitesOf(_id),
    );
  });

  group('a declined invite (#475)', () {
    for (final role in [
      HouseholdRole.householdOwner,
      HouseholdRole.householdAdmin,
    ]) {
      test("for the household's ${role.name} opens the household's "
          'invites on Declined', () async {
        viewerIs(_viewer(role));

        expect(
          await notificationTargetLocation(
            const DeclinedInviteTarget(_id),
            households: households,
          ),
          '/household/$_id/invites?filter=declined',
        );
      });
    }

    test('declined for a member opens the sent invites on Declined', () async {
      viewerIs(_viewer(HouseholdRole.householdMember));

      expect(
        await notificationTargetLocation(
          const DeclinedInviteTarget(_id),
          households: households,
        ),
        _sentDeclined,
      );
    });

    // A guest, a role the server named that this version doesn't know, and
    // a member with no role binding may not read the household's invites.
    for (final role in [
      HouseholdRole.householdGuest,
      HouseholdRole.unknown,
      null,
    ]) {
      test('declined for a member whose role is ${role?.name ?? 'unset'} '
          'opens the sent invites on Declined', () async {
        viewerIs(_viewer(role));

        expect(
          await notificationTargetLocation(
            const DeclinedInviteTarget(_id),
            households: households,
          ),
          _sentDeclined,
        );
      });
    }

    test(
      'declined with no local member opens the sent invites on Declined',
      () async {
        viewerIs(null);

        expect(
          await notificationTargetLocation(
            const DeclinedInviteTarget(_id),
            households: households,
          ),
          _sentDeclined,
        );
      },
    );

    test(
      'declined with no household cache opens the sent invites on Declined',
      () async {
        expect(
          await notificationTargetLocation(
            const DeclinedInviteTarget(_id),
            households: null,
          ),
          _sentDeclined,
        );
      },
    );

    test('declined where the cache read fails opens the sent invites on '
        'Declined, and never throws', () async {
      // A repository disposed with its session answers this way.
      when(
        () => households.getCurrentUserMember(_id),
      ).thenThrow(StateError('disposed'));

      expect(
        await notificationTargetLocation(
          const DeclinedInviteTarget(_id),
          households: households,
        ),
        _sentDeclined,
      );
    });

    test('declined where the cache read fails later opens the sent '
        'invites on Declined', () async {
      when(
        () => households.getCurrentUserMember(_id),
      ).thenAnswer((_) => Future.error(Exception('database closed')));

      expect(
        await notificationTargetLocation(
          const DeclinedInviteTarget(_id),
          households: households,
        ),
        _sentDeclined,
      );
    });
  });
}
