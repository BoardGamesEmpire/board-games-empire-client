// The wire fixtures the composed session suite (#369) answers with, each the
// success case of the suite named above it, cut to the smallest answer the
// remote accepts. Copied rather than imported: no package reaches into
// another's test directory.

/// The user [grantJson] and [sessionJson] sign in.
const String kWebUserId = 'user-1';

// `web_network/test/auth/web_auth_repository_impl_test.dart`, `_grantJson`
// and `_sessionJson`.
Map<String, dynamic> _wireUser() => {
  'id': kWebUserId,
  'name': 'webuser',
  'email': 'web@example.com',
  'emailVerified': true,
  'createdAt': '2024-01-01T00:00:00.000Z',
  'updatedAt': '2024-01-01T00:00:00.000Z',
};

/// The sign-in grant: a token and a user, but no expiry, which only the
/// session read brings.
Map<String, dynamic> grantJson() => {
  'token': 'grant-tok-web',
  'user': _wireUser(),
};

/// The session `get-session` answers with, for [kWebUserId].
Map<String, dynamic> sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': 'session-tok-web',
    'expiresAt': '2099-01-01T00:00:00.000Z',
    'userId': kWebUserId,
  },
  'user': _wireUser(),
};

/// `_kEmptyPage` in `platform/web/test/web_household_hydrate_seam_test.dart`:
/// a complete set of households with nothing in it.
const Map<String, Object?> emptyHouseholdPage = {
  'households': <Object?>[],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 0,
    'totalPages': 0,
    'hasMore': false,
  },
};

/// One household, [id], with [kWebUserId] as its member.
///
/// `_householdRow` and `_memberRow` in
/// `dio_network/test/household/household_remote_data_source_fetch_test.dart`,
/// cut to what the remote reads, in [emptyHouseholdPage]'s envelope. The
/// member is the signed-in user on purpose: the cache lists a household only
/// for the members it holds, so a row without that user never appears.
Map<String, Object?> householdPage(String id) => {
  'households': [
    {
      'id': id,
      'name': 'Game Night HQ',
      'description': null,
      'image': null,
      'languageTagId': null,
      'createdById': kWebUserId,
      'visibility': 'Private',
      'deletedAt': null,
      'createdAt': '2026-01-15T10:30:00.000Z',
      'updatedAt': '2026-01-15T10:30:00.000Z',
      'languageTag': null,
      'members': [
        {
          'id': 'hm_1',
          'userId': kWebUserId,
          'householdId': id,
          'showAllGames': true,
          'origin': 'Founder',
          'addedById': null,
          'createdAt': '2026-01-15T10:30:00.000Z',
          'updatedAt': '2026-01-15T10:30:00.000Z',
          'role': {
            'id': 'hr_1',
            'householdMemberId': 'hm_1',
            'roleId': 'role_1',
            'role': {'id': 'role_1', 'name': 'HouseholdOwner'},
          },
          'user': {
            'id': kWebUserId,
            'username': 'ada',
            'profile': {'avatarUrl': null, 'displayName': 'Ada'},
          },
        },
      ],
    },
  ],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 1,
    'totalPages': 1,
    'hasMore': false,
  },
};

/// An empty page of collections.
///
/// `dio_network/test/game_collection/game_collection_remote_data_source_impl_test.dart`,
/// as `native_platform/test/support/native_root_harness.dart` cuts it. No
/// pages for no collections, as the server derives it (`total` over `limit`,
/// rounded up), and as [emptyEventPage] has to.
const Map<String, Object?> emptyCollectionPage = {
  'collections': <Object?>[],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 0,
    'totalPages': 0,
    'hasMore': false,
  },
};

/// An empty page of events.
///
/// `dio_network/test/event/event_remote_data_source_impl_test.dart`, as
/// `native_platform/test/support/native_root_harness.dart` cuts it. An empty
/// list counts no pages: the hydrate treats a first page that counts one for
/// no events as contradicting itself, and the pass fails.
const Map<String, Object?> emptyEventPage = {
  'events': <Object?>[],
  'pagination': {
    'page': 1,
    'limit': 100,
    'total': 0,
    'totalPages': 0,
    'hasMore': false,
  },
};

/// The caller's access to the types the session asks about: DataGateway,
/// Household and SystemSetting.
///
/// `dio_network/test/user/user_remote_data_source_impl_test.dart`, the
/// `fetchAccess` success case, with the values
/// `native_platform/test/support/native_root_harness.dart` answers. It allows
/// something on purpose: an answer that denies everything makes the reader
/// ask again after its recheck delay, which would put a second request and a
/// pending timer into every test of the composed session (#369).
const Map<String, Object?> someAccess = {
  'access': {
    'DataGateway': {
      'create': 'all',
      'read': 'all',
      'update': 'some',
      'delete': 'none',
      'manage': 'none',
    },
    // The session asks about households too (#684); a reply that omits a
    // requested type is malformed, so the canned one answers both.
    'Household': {
      'create': 'none',
      'read': 'none',
      'update': 'none',
      'delete': 'none',
      'manage': 'none',
    },
    // And the server settings (#807), for the same reason.
    'SystemSetting': {
      'create': 'none',
      'read': 'none',
      'update': 'none',
      'delete': 'none',
      'manage': 'none',
    },
  },
};
