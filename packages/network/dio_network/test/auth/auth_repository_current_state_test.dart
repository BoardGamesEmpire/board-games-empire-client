import 'package:bge_test_support/domain.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../support/in_memory_session_tombstone_store.dart';

ServerIdentity _identity() =>
    testServerIdentity().copyWith(serverId: 'bge-uuid-1');

/// #97: [AuthRepositoryImpl.currentAuthState] is the synchronous mirror
/// of the in-memory state `watchAuthState` replays on subscribe — the
/// seam the feedback target resolver reads per submit/drain.
void main() {
  group('AuthRepositoryImpl.currentAuthState', () {
    test('starts Unknown and matches the value watchAuthState '
        'replays', () async {
      final repository = AuthRepositoryImpl(
        identity: _identity(),
        serverUrl: 'https://bge.example.com',
        tokenStorage: TokenStorageService(
          serverId: 'bge-uuid-1',
          tombstones: InMemorySessionTombstoneStore(),
        ),
        dio: Dio(),
      );
      addTearDown(repository.onDispose);

      expect(repository.currentAuthState, isA<AuthStateUnknown>());
      expect(
        await repository.watchAuthState().first,
        repository.currentAuthState,
      );
    });
  });
}
