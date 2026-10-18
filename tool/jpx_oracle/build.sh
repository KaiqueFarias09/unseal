#!/bin/sh
# Builds the development-only OpenJPEG oracle helper against the
# installed libopenjp2 (Homebrew layout by default). Output lives in
# build/, never in the package.
#
#   sh tool/jpx_oracle/build.sh            # -> build/tools/opj_oracle
#   OPENJPEG_PREFIX=/usr/local sh tool/jpx_oracle/build.sh
set -eu
PREFIX="${OPENJPEG_PREFIX:-/opt/homebrew}"
INCLUDE="$(ls -d "$PREFIX"/include/openjpeg-* 2>/dev/null | sort | tail -1)"
if [ -z "$INCLUDE" ]; then
  echo "openjpeg headers not found under $PREFIX/include" >&2
  exit 2
fi
mkdir -p build/tools
cc -O2 -Wall -Wextra -std=c99 -I"$INCLUDE" -L"$PREFIX/lib" \
  -o build/tools/opj_oracle tool/jpx_oracle/opj_oracle.c -lopenjp2
echo "built build/tools/opj_oracle against $INCLUDE"
