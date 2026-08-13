## 0.0.1

* Add `HouseholdRemoteDataSourceImpl` (#39): `POST /api/households` over the
  shared per-server Dio, unwrapping the `{ message, household }` envelope,
  with transient/permanent failure classification
  (`HouseholdRemoteTransientException` / `HouseholdRemotePermanentException`)
  and registration in `registerServerNetwork` alongside the feedback
  transport.
