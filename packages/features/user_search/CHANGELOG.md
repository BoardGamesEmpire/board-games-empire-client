## 0.0.1

* Initial release (#455, #499): the user search the household invite form had
  to itself, as a package both it and the event create form share.
  `UserSearchBloc` asks a `UserRemoteDataSource` for who matches as the person
  types, once typing pauses and the query has two characters, and
  `UserSearchResultList` shows the answer as rows to pick from, any number of
  which can be picked. The search field and the pick stay each form's own.
