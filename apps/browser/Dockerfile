# The web client's release build as an assets image (#418): its files at
# /web, and nothing else. The image is never run. A backend image copies
# the files out of it by digest:
#
#   COPY --from=ghcr.io/boardgamesempire/bge-client-web:edge@sha256:<digest> /web <dest>
#
# The build context holds tool/build_web.dart's output as `web/`, which
# has no tooling dotfiles. Locally that context is apps/browser/build. CI's
# `publish-web` job assembles it from `build-web`'s artifact.
#
# FROM scratch, because the files need no runtime and have no
# architecture: a consumer on any platform copies the same bytes.
FROM scratch

ARG REVISION
ARG VERSION
ARG CREATED
ARG FILES

# `version` is whatever the build wrote into version.json, so the label and
# the running app report the same version. `created` is the commit's date,
# not the build's, so rebuilding a commit does not change it. `files` is a
# hash of the files under /web (#424): images that hold the same files
# carry the same value, whichever commit built them, and CI moves `edge`
# only when it changes.
LABEL org.opencontainers.image.source="https://github.com/BoardGamesEmpire/board-games-empire-client" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${CREATED}" \
      io.github.boardgamesempire.web.files="${FILES}"

COPY web/ /web/
