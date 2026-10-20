import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';

import '../support/fake_household_invite_remote.dart';

const _debounce = Duration(milliseconds: 20);
const _ana = UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B');

void main() {
  late FakeHouseholdInviteRemote remote;

  setUp(() {
    remote = FakeHouseholdInviteRemote()
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
    'clearing the query while a search waits cancels it',
    build: build,
    act: (bloc) => bloc
      ..add(const UserSearchQueryChanged('ana'))
      ..add(const UserSearchQueryChanged('')),
    wait: _debounce * 3,
    expect: () => [const UserSearchIdle()],
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
