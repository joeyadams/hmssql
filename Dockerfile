# syntax=docker/dockerfile:1
#
# Build an hmssql program for Linux in Docker, and an image that runs it.
# The default builds examples/managed-identity; EXE picks another executable
# of the repository (one of the examples').
#
#   docker build -t hmssql-example .
#   docker build --build-arg EXE=hmssql-example-crud -t hmssql-example-crud .
#   docker run --rm -e MSSQL_HOST=... -e MSSQL_ACCESS_TOKEN=... hmssql-example
#
# Three stages: the toolchain (GHC and cabal on Ubuntu 24.04 via ghcup, from
# scripts/linux-toolchain.sh; cached across builds), the build (the
# dependencies from the .cabal files alone, cached until those change, then
# the working tree, .dockerignore leaving the build directories out), and the
# runtime image (stock Ubuntu with the executable, its shared libraries and a
# certificate store, so the server's certificate validates by default).
#
# On an Apple Silicon Mac, --platform linux/amd64 builds for the x86-64 hosts
# most of Azure runs; GHC under emulation is slow but works.
# scripts/azure-managed-identity.sh runs the same steps in Azure Container
# Instances, which can't build images, from a tarball of the working tree.

ARG UBUNTU_IMAGE=mcr.microsoft.com/mirror/docker/library/ubuntu:24.04

FROM ${UBUNTU_IMAGE} AS toolchain
ARG GHC_VERSION=9.12.4
COPY scripts/linux-toolchain.sh /tmp/linux-toolchain.sh
RUN GHC_VERSION=${GHC_VERSION} bash /tmp/linux-toolchain.sh
ENV PATH=/root/.ghcup/bin:/root/.cabal/bin:${PATH}
# The package index, in a layer of its own: a code change doesn't fetch it
# again.
RUN cabal update

FROM toolchain AS build
ARG EXE=hmssql-example-managed-identity
WORKDIR /build
# The dependencies first, from the package descriptions alone, so that a
# source change rebuilds only the packages of this repository.  With every
# package of cabal.project as the target, only the packages from Hackage
# count as dependencies (naming one executable would make the repository's
# own packages it uses dependencies too, and they have no sources yet).
COPY cabal.project ./
COPY hmssql/hmssql.cabal hmssql/
COPY hmssql-tests/hmssql-tests.cabal hmssql-tests/
COPY hmssql-bench/hmssql-bench.cabal hmssql-bench/
COPY hmssql-bench-azure/hmssql-bench-azure.cabal hmssql-bench-azure/
COPY examples/shop-db/hmssql-example-shop-db.cabal examples/shop-db/
COPY examples/crud/hmssql-example-crud.cabal examples/crud/
COPY examples/odata/hmssql-example-odata.cabal examples/odata/
COPY examples/bulk-copy/hmssql-example-bulk-copy.cabal examples/bulk-copy/
COPY examples/managed-identity/hmssql-example-managed-identity.cabal examples/managed-identity/
RUN cabal build -j --only-dependencies all
COPY . .
RUN cabal build -j ${EXE}:exe:${EXE} \
  && mkdir -p /out && cp "$(cabal list-bin ${EXE})" /out/${EXE} \
  && strip /out/${EXE} && ldd /out/${EXE}

FROM ${UBUNTU_IMAGE}
ARG EXE=hmssql-example-managed-identity
RUN apt-get update -qq \
  && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y --no-install-recommends \
       ca-certificates libgmp10 libffi8 zlib1g >/dev/null \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/${EXE} /usr/local/bin/${EXE}
# ENTRYPOINT can't expand a build argument; an env variable can.
ENV EXE=${EXE}
ENTRYPOINT ["/bin/sh", "-c", "exec \"/usr/local/bin/$EXE\" \"$@\"", "--"]
