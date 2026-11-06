# The golden-test image: the pinned Flutter on a pinned Ubuntu, so every
# machine renders the committed golden baselines the same way (#159).
#
# Ahem-rendered goldens still differ by host: macOS and Linux anti-alias
# the edges of the same shapes differently, so a baseline rendered on one
# fails on the other. The container is the one host that owns the
# baselines. Contributors render and compare in it, and so does CI's
# `goldens` job. A macOS or Windows host runs linux/amd64 under emulation,
# which is slower. The emulated CPU still matters: Skia picks its raster
# code from the CPU's features, and CI's runners all have AVX2 and FMA.
# Docker Desktop's Rosetta emulation reports both, and tool/goldens.dart
# warns when the container's CPU lacks either.
#
# Don't build or run this by hand. tool/goldens.dart builds it under a tag
# that hashes this file and the two install files, and mounts the checkout
# read-only so the container's resolution never reaches the host:
#   dart run tool/goldens.dart [--update]
#
# The build context is tool/, so the install script and the digest it
# checks are the only files the image sees.

FROM --platform=linux/amd64 ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

# What flutter test needs on a bare Ubuntu: curl, xz and unzip for the SDK
# and its artifacts, git for the SDK's own version checks, and the GL
# library the Flutter tester links against.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    curl xz-utils git unzip ca-certificates libglu1-mesa \
  && rm -rf /var/lib/apt/lists/*

# The SDK archive is owned by whoever packed it, and the checkout by the
# host user; git refuses both as "dubious ownership" without this.
RUN git config --system --add safe.directory '*'

# One layer for the install and the precache. In a layer of its own,
# every SDK file precache rewrites is stored a second time. `--universal`
# is named because `--no-<platform>` flags select nothing: with no flag
# turned on, precache fetches every enabled platform. `flutter test`
# needs only the universal artifacts. Together the two changes took
# about 220 MB off the image.
ENV PATH=/opt/flutter/bin:$PATH
COPY install_flutter.sh flutter_sdk.sha256 /tmp/flutter/
RUN /tmp/flutter/install_flutter.sh /opt/flutter \
  && rm -rf /tmp/flutter \
  && flutter --disable-analytics \
  && flutter precache --universal

WORKDIR /work
