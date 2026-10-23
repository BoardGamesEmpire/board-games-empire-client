## 0.0.1

* Initial release (#42): `GameBrowseBloc` pages the server's catalog and
  writes each page to the games cache, reading the cache in the catalog's
  order when the server fails. `GameSearchBloc` searches the server and its
  DataGateways in two sections, narrowed by content and platform type, and
  falls back to the cache when the server fails. `GameDetailBloc` reads one
  game and its platform games.
* The three screens over them, with the description rendered as Markdown
  (#472).
