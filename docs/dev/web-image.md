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
| `edge` | the newest commit with a `sha-<short>` tag | whenever a commit gets one |
| `sha-<short>` | one commit, named by the first 7 characters of its SHA | never |

There are no version tags yet. They arrive with #419, along with a client
version worth tagging: until then, every build reports the template version
`1.0.0`.

Pin a digest, not a tag. `edge` moves whenever a commit is tagged, and a
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

The same commit builds the same files, wherever it is checked out.

| Label | Value |
| --- | --- |
| `org.opencontainers.image.source` | this repository |
| `org.opencontainers.image.revision` | the full commit SHA |
| `org.opencontainers.image.version` | what the build wrote into `version.json` |
| `org.opencontainers.image.created` | the commit's date, not the build's |

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

## How it is published

The `publish-web` job in `.github/workflows/ci.yaml` publishes on a push to
master, once every gate job and `build-web` have passed. It builds the image
with `apps/browser/Dockerfile` from `build-web`'s artifact, the files that
job checked. It pushes by digest, checks that digest from `linux/amd64` and
`linux/arm64`, and only then moves the tags. Just before tagging, it checks
that the commit is still master's tip. Only one `publish-web` job runs at a
time and the rest wait in a queue, so no other run can write the tags
between that check and the write. If master has moved on, the image stays
untagged, so the package can hold untagged versions that no tag points at.

A `sha-<short>` never moves. "Re-run failed jobs" can retry a failed publish
for a week after the run, while `build-web`'s artifact is kept. After that,
"Re-run all jobs" builds the files again. If the failed attempt wrote
`sha-<short>`, which happens only in the job's last step, the re-run checks
and tags that image rather than pushing another. If it failed before then,
any image it pushed stays untagged, and the re-run pushes a new one.

The first publish creates the package. GitHub's documentation disagrees on
whether a package created by a workflow starts public, inheriting the
repository's visibility, or private, so check it after that run. If it is
private, an org owner makes it public in the package's settings, which cannot
be undone. Source builds of the backend need it public, and so does Renovate.

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
