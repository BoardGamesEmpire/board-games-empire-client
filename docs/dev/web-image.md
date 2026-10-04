# The published web image

CI publishes the web client's release build as a container image, so the
backend can copy it into its own image and serve it from the API origin
(BoardGamesEmpire/board-games-empire-backend#598). The image holds files and
nothing else, and it is never run.

```
ghcr.io/boardgamesempire/bge-client-web
```

## Tags

| Tag | Points at | Moves |
| --- | --- | --- |
| `edge` | the files of master's newest published commit | when those files change |
| `sha-<short>` | one commit, named by the first 7 characters of its SHA | never |

A commit that changes no built file, such as a docs-only one, gets its
`sha-<short>` but leaves `edge` where it is. So `edge`'s `revision` label
names the commit that moved it, normally the first to build its files, and
it can be older than master's newest commit.

There are no version tags yet. They arrive with #419, along with a client
version worth tagging: until then, every build reports the template version
`1.0.0`.

Pin a digest, not a tag. `edge` moves whenever the built files change, and a
digest names exactly one image:

```dockerfile
COPY --from=ghcr.io/boardgamesempire/bge-client-web:edge@sha256:<digest> /web /srv/web
```

The tag in front of the digest is for readers and for Renovate, which uses
it to find the next digest. Docker resolves the digest alone.

## What the image holds

The release build of `apps/browser`, at `/web`:

- Built to be served at `/`, with no `--base-href`. Serving it under a
  sub-path needs a build with one.
- JavaScript only. The wasm build waits until the browser suites run under
  wasm (#420).
- CanvasKit, the renderer, and its Roboto fallback font, served from the
  page's own origin rather than gstatic.com, so an instance with no internet
  access still renders. Glyphs that Roboto lacks may still be fetched from
  fonts.gstatic.com (#421).
- No service-worker registration. Flutter's service worker is deprecated
  and only unregisters itself, so the bootstrap leaves it out. The stub
  `flutter_service_worker.js` still ships, unused.
- `sqlite3.wasm` and `drift_worker.js`, checked against the SHA-256s
  committed in `tool/fetch_web_assets.dart`.
- No tooling dotfiles.

The same commit builds the same files, wherever it is checked out. Flutter
writes one map into `flutter_bootstrap.js` in the order the filesystem lists
the CanvasKit files, which differs between machines, so the build script
sorts it.

| Label | Value |
| --- | --- |
| `org.opencontainers.image.source` | this repository |
| `org.opencontainers.image.revision` | the full commit SHA |
| `org.opencontainers.image.version` | what the build wrote into `version.json` |
| `org.opencontainers.image.created` | the commit's date, not the build's |
| `io.github.boardgamesempire.web.files` | a hash of the files under `/web`, below |

The image is a single manifest, not an index, so `COPY --from` works the
same on every platform. A build for any platform other than the image's own
(`linux/amd64`) gets an `InvalidBaseImagePlatform` warning from BuildKit,
but copies the same files.

## Inspecting an image

A `FROM scratch` image has no command, so `docker create` needs a
placeholder argument. Nothing runs: the container only gives `docker cp`
something to copy from.

```sh
id=$(docker create ghcr.io/boardgamesempire/bge-client-web:edge placeholder)
docker cp "$id:/web" ./web
docker rm "$id"
```

To read the digest and labels without pulling the files:

```sh
docker buildx imagetools inspect ghcr.io/boardgamesempire/bge-client-web:edge
docker buildx imagetools inspect ghcr.io/boardgamesempire/bge-client-web:edge \
  --format '{{json .Image.Config.Labels}}'
```

The `files` label is `sha256:` followed by the first field this prints, run
in a copy of `/web`. It hashes each file's path and contents, and nothing
else:

```sh
find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
```

## How it is published

The `publish-web` job in `.github/workflows/ci.yaml` publishes on a push to
master, once every gate job and `build-web` have passed. It builds the image
with `apps/browser/Dockerfile` from `build-web`'s artifact, the files that
job checked. It pushes by digest, checks that digest from `linux/amd64` and
`linux/arm64`, and only then writes the tags.

Every commit that gets that far gets its `sha-<short>`. `edge` moves to the
commit's image only when all three of these hold:

- The commit is on master: master's tip is the commit or a descendant of it.
- No newer commit on master has a `sha-<short>`. An older commit's publish
  that runs late, or a re-run of one, leaves `edge` where it is, so `edge`
  never moves back.
- The image's `files` label differs from `edge`'s. When there is no `edge`
  yet, or it has no `files` label, they count as different.

The job reads everything it decides on before it writes a tag, so a run
that fails while reading writes nothing, and its commit does not count as
published. It writes `sha-<short>` before moving `edge`. The job's summary
says whether `edge` moved, and which condition held it back when it did not.
Only one `publish-web` job runs at a time and the rest wait in a queue, so
no other run can write a tag between this run reading the tags and writing
its own.

This relies on CI building the same files for commits that change none of
them. If that stops being true, `edge` moves on every commit, as it did
before #424, rather than staying behind.

A `sha-<short>` never moves. "Re-run failed jobs" can retry a failed publish
for a week after the run, while `build-web`'s artifact is kept. After that,
"Re-run all jobs" builds the files again. If the failed attempt wrote
`sha-<short>`, which happens only in the job's last step, the re-run checks
and tags that image rather than pushing another. If it failed before then,
any image it pushed stays untagged, and the re-run pushes a new one.

The package is public, so source builds of the backend and Renovate pull it
without credentials. A public package cannot be made private again.

## Building it locally

To try the image before CI publishes it:

```sh
melos run build-web
docker build -f apps/browser/Dockerfile -t bge-client-web:local apps/browser/build
```

`melos run build-web` fetches the drift runtime files, then runs
`tool/build_web.dart`, the same script CI's `build-web` job runs. It empties
the output first, because `flutter build web` keeps files from earlier
builds. It builds with the published flags, removes the tooling dotfiles,
and checks the result. With codegen current, its files are the ones a
published build of the same commit holds.
