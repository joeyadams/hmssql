#!/usr/bin/env bash
#
# Install GHC and cabal on a stock Ubuntu (or Debian) image, for building
# hmssql and its examples there: the Dockerfile's toolchain stage and the
# Azure Container Instances build of scripts/azure-managed-identity.sh both
# run this.  GHC_VERSION picks the compiler (stack.yaml's snapshot has 9.12.4;
# any version in hmssql/hmssql.cabal's tested-with builds it), CABAL_VERSION the
# cabal-install (latest by default).  Everything goes under $HOME/.ghcup;
# put $HOME/.ghcup/bin and $HOME/.cabal/bin on the PATH afterwards.
#
set -euo pipefail

GHC_VERSION=${GHC_VERSION:-9.12.4}
CABAL_VERSION=${CABAL_VERSION:-latest}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# What GHC's binary distribution and hmssql's dependencies need: a C
# toolchain, GMP, libffi, zlib (for the zlib package tls pulls in),
# ncurses (GHC's own dependency), and curl and xz for ghcup.
apt-get install -qq -y --no-install-recommends \
  curl ca-certificates build-essential libgmp-dev libffi-dev zlib1g-dev \
  libncurses-dev pkg-config xz-utils >/dev/null

# ghcup, without the interactive questions and without stack (stack would
# download its own GHC).
curl -sSf https://get-ghcup.haskell.org | \
  BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_MINIMAL=1 \
  BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1 sh >/dev/null
export PATH=$HOME/.ghcup/bin:$HOME/.cabal/bin:$PATH
ghcup install ghc "$GHC_VERSION" --set >/dev/null 2>&1
ghcup install cabal "$CABAL_VERSION" --set >/dev/null 2>&1
ghc --version
cabal --version
