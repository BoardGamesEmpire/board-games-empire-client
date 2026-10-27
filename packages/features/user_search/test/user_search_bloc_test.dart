import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:user_search/user_search.dart';

import 'support/fake_user_remote.dart';

const _debounce = Duration(milliseconds: 20);
const _ana = UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B');

/// The search both the household invite form (#455) and the event create
/// form's invitees (#499) type into: when it asks the server, and what it
/// shows while it waits and after.
void main() {
  late FakeUserRemote remote;

  setUp(() {
    remote = FakeUserRemote()
      ..onSearchUsers = (_, _, _) async => pageOf([_ana]);
  });

  UserSearchBloc build() => UserSearchBloc(remote: remote, debounce: _debounce);

  blocTest<UserSearchBloc, UserSearchState>(
    'a query under 2 characters, after trimming, asks nothing',
    build: build,
    act: (bloc) => bloc
      ..add(const UserSearchQueryChanged('a'))
      ..add(const UserSearchQueryChanged('  a ')),
    wait: _debounce * 3,
    expect: () => [const UserSearchIdle()],
    verify: (_) => expect(remote.calls, isEmpty),
  );

  blocTest<UserSearchBloc, UserSearchState>(
    'a query asks once the typing pauses, then shows who matched',
    build: build,
    act: (bloc) => bloc.add(const UserSearchQueryChanged('ana')),
    wait: _debounce * 3,
    expect: () => [
      const UserSearchLoading(),
      const UserSearchResults([_ana]),
    ],
    verify: (_) => expect(remote.calls, ['searchUsers(ana)']),
  );

  blocTest<UserSearchBloc, UserSearchState>(
    'typing on within the pause asks only for the last query',
    build: build,
    act: (bloc) => bloc
      ..add(const UserSearchQueryChanged('an'))
      ..add(const UserSearchQueryChanged('ana')),
    wait: _debounce * 3,
    expect: () => [
      const UserSearchLoading(),
      const UserSearchResults([_ana]),
    ],
    verify: (_) => expect(remote.calls, ['searchUsers(ana)']),
  );

  blocTest<UserSearchBloc, UserSearchState>(
    'a new query hides the last results while its pause runs',
    build: build,
    act: (bloc) async {
      bloc.add(const UserSearchQueryChanged('ana'));
      await Future<void>.delayed(_debounce * 3);
      bloc.add(const UserSearchQueryChanged('anb'));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state, const UserSearchLoading());
    },
    wait: _debounce * 3,
    expect: () => [
      const UserSearchLoading(),
      const UserSearchResults([_ana]),
      const UserSearchLoading(),
      const UserSearchResults([_ana]),
    ],
  );

  blocTest<UserSearchBloc, UserSearchState>(
    'clearing the query while a search waits cancels it',
    build: build,
    act: (bloc) => bloc
      ..add(const UserSearchQueryChanged('ana'))
      ..add(const UserSearchQueryChanged('')),
    wait: _debounce * 3,
    expect: () => [const UserSearchLoading(), const UserSearchIdle()],
    verify: (_) => expect(remote.calls, isEmpty),
  );

  blocTest<UserSearchBloc, UserSearchState>(
    'a failed search says so',
    setUp: () => remote.onSearchUsers = (_, _, _) async => throw offline(),
    build: build,
    act: (bloc) => bloc.add(const UserSearchQueryChanged('ana')),
    wait: _debounce * 3,
    expect: () => [const UserSearchLoading(), const UserSearchFailed()],
  );
}
