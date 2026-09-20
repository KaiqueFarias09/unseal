#!/bin/sh

set -eu

release_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$release_root"

release_operation=${1:-}
release_version=${VERSION:-}
release_package=unseal
release_tag="v$release_version"
release_dart_bin=
release_dart_version_file=.dart-version
release_notes_file=

cleanup() {
  if [ -n "$release_notes_file" ] && [ -f "$release_notes_file" ]; then
    rm -f -- "$release_notes_file"
  fi
}

trap cleanup EXIT HUP INT TERM

fail() {
  printf 'release error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

resolve_dart() {
  if [ -n "${DART_BIN:-}" ]; then
    [ -x "$DART_BIN" ] || fail "DART_BIN is not executable: $DART_BIN"
    release_dart_bin=$DART_BIN
    return
  fi

  if [ -f .fvmrc ]; then
    if [ ! -x .fvm/flutter_sdk/bin/dart ]; then
      fail 'the project FVM SDK is unavailable; run fvm install before releasing.'
    fi
    release_dart_bin=.fvm/flutter_sdk/bin/dart
    return
  fi

  if command -v dart >/dev/null 2>&1; then
    release_dart_bin=$(command -v dart)
    return
  fi

  if [ -n "${HOME:-}" ] && [ -x "$HOME/fvm/default/bin/dart" ]; then
    release_dart_bin=$HOME/fvm/default/bin/dart
    return
  fi

  fail 'Dart was not found. Install Dart or run make with DART_BIN=/path/to/dart.'
}

require_dart_version() {
  [ -f "$release_dart_version_file" ] ||
    fail "$release_dart_version_file is missing"

  release_expected_dart_version=$(tr -d '[:space:]' <"$release_dart_version_file")
  [ -n "$release_expected_dart_version" ] ||
    fail "$release_dart_version_file is empty"

  release_actual_dart_version=$(
    "$release_dart_bin" --version 2>&1 | awk '{ print $4; exit }'
  )
  [ "$release_actual_dart_version" = "$release_expected_dart_version" ] ||
    fail "Dart $release_actual_dart_version is active; expected $release_expected_dart_version. Run fvm install."
}

require_version_metadata() {
  [ -n "$release_version" ] ||
    fail 'VERSION is required. Example: make release-check VERSION=1.1.0'

  printf '%s\n' "$release_version" |
    grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' ||
    fail "invalid semantic version: $release_version"

  release_tag="v$release_version"
  release_pubspec_version=$(awk '$1 == "version:" { print $2; exit }' pubspec.yaml)
  [ "$release_pubspec_version" = "$release_version" ] ||
    fail "pubspec.yaml is $release_pubspec_version; expected $release_version"

  awk -v version="$release_version" '
    index($0, "## " version " ") == 1 || $0 == "## " version { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' CHANGELOG.md || fail "CHANGELOG.md has no section for $release_version"
}

require_clean_main() {
  release_branch=$(git symbolic-ref --quiet --short HEAD) ||
    fail 'HEAD is detached; check out main before releasing.'
  [ "$release_branch" = main ] || fail "release must run from main, not $release_branch"

  [ -z "$(git status --porcelain)" ] ||
    fail 'working tree is not clean; commit or restore all changes before releasing.'
}

fetch_and_require_synced_main() {
  require_command git
  git fetch --quiet origin main --tags

  release_head=$(git rev-parse HEAD)
  release_origin_main=$(git rev-parse --verify origin/main) ||
    fail 'origin/main was not found after fetching.'
  [ "$release_head" = "$release_origin_main" ] ||
    fail "main is not synchronized with origin/main (HEAD $release_head, origin/main $release_origin_main). Push or reconcile it first."
}

published_status() {
  require_command curl
  release_http_status=$(curl -sS --connect-timeout 10 --max-time 30 \
    -o /dev/null -w '%{http_code}' \
    "https://pub.dev/api/packages/$release_package/versions/$release_version") ||
    fail 'could not contact pub.dev to check the requested version.'

  case "$release_http_status" in
    200) return 0 ;;
    404) return 1 ;;
    *) fail "pub.dev returned HTTP $release_http_status while checking $release_version" ;;
  esac
}

run_release_gate() {
  require_command git
  require_version_metadata
  require_clean_main
  resolve_dart
  require_dart_version

  printf 'release-check: validating unseal %s\n' "$release_version"
  "$release_dart_bin" format --output=none --set-exit-if-changed .
  "$release_dart_bin" analyze --fatal-infos
  "$release_dart_bin" test --exclude-tags fuzz
  "$release_dart_bin" test -p chrome test/web/
  "$release_dart_bin" test --tags fuzz
  "$release_dart_bin" run tool/fuzz_corpus_inventory.dart --check-manifest

  if published_status; then
    printf 'release-check: unseal %s is already published; skipping pub.dev dry-run.\n' \
      "$release_version"
  else
    "$release_dart_bin" pub publish --dry-run
  fi

  printf 'release-check: unseal %s passed all release gates.\n' "$release_version"
  printf 'commit: %s\n' "$(git rev-parse HEAD)"
}

tag_commit() {
  git rev-list -n 1 "$release_tag" 2>/dev/null || true
}

remote_tag_commit() {
  release_remote_commit=$(git ls-remote --tags origin "refs/tags/$release_tag^{}" |
    awk 'NR == 1 { print $1 }')
  if [ -z "$release_remote_commit" ]; then
    release_remote_commit=$(git ls-remote --tags origin "refs/tags/$release_tag" |
      awk 'NR == 1 { print $1 }')
  fi
  printf '%s\n' "$release_remote_commit"
}

require_tag_at_head() {
  release_head=$(git rev-parse HEAD)
  release_local_tag_commit=$(tag_commit)
  [ -n "$release_local_tag_commit" ] || fail "$release_tag does not exist locally"
  [ "$release_local_tag_commit" = "$release_head" ] ||
    fail "$release_tag points to $release_local_tag_commit, not HEAD $release_head"

  release_remote_tag_commit=$(remote_tag_commit)
  [ -n "$release_remote_tag_commit" ] || fail "$release_tag has not been pushed to origin"
  [ "$release_remote_tag_commit" = "$release_head" ] ||
    fail "$release_tag on origin points to $release_remote_tag_commit, not HEAD $release_head"
}

github_release_url() {
  gh release view "$release_tag" --json url --jq .url 2>/dev/null || true
}

confirm_github_release() {
  if [ "${YES:-0}" = 1 ]; then
    return
  fi
  [ -t 0 ] ||
    fail 'confirmation requires a terminal; rerun with YES=1 after reviewing the command.'

  printf 'Create and push %s at %s and create its GitHub Release? [y/N] ' \
    "$release_tag" "$(git rev-parse --short HEAD)"
  read -r release_answer
  case "$release_answer" in
    y|Y|yes|YES) ;;
    *) fail 'GitHub release cancelled.' ;;
  esac
}

write_release_notes() {
  release_notes_file=$(mktemp "${TMPDIR:-/tmp}/unseal-release-notes.XXXXXX")
  awk -v version="$release_version" '
    index($0, "## " version " ") == 1 || $0 == "## " version {
      found = 1
      next
    }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md >"$release_notes_file"
  [ -s "$release_notes_file" ] || fail "release notes for $release_version are empty"
}

run_github_release() {
  require_command gh
  require_version_metadata
  require_clean_main
  gh auth status >/dev/null 2>&1 || fail 'GitHub CLI is not authenticated; run gh auth login first.'
  fetch_and_require_synced_main

  release_existing_url=$(github_release_url)
  if [ -n "$release_existing_url" ]; then
    require_tag_at_head
    printf 'release-github: %s already exists at the correct commit.\n' "$release_tag"
    printf 'url: %s\n' "$release_existing_url"
    return
  fi

  run_release_gate
  fetch_and_require_synced_main

  release_head=$(git rev-parse HEAD)
  release_local_tag_commit=$(tag_commit)
  if [ -n "$release_local_tag_commit" ] && [ "$release_local_tag_commit" != "$release_head" ]; then
    fail "$release_tag already points to $release_local_tag_commit, not HEAD $release_head"
  fi

  confirm_github_release

  if [ -z "$release_local_tag_commit" ]; then
    git tag -a "$release_tag" -m "Unseal $release_version"
  fi
  git push origin "refs/tags/$release_tag"
  require_tag_at_head

  write_release_notes
  release_created_url=$(gh release create "$release_tag" \
    --verify-tag \
    --title "Unseal $release_version" \
    --notes-file "$release_notes_file")

  printf 'release-github: created %s\n' "$release_tag"
  printf 'url: %s\n' "$release_created_url"
  printf 'commit: %s\n' "$release_head"
}

run_publish() {
  require_version_metadata
  require_clean_main
  resolve_dart

  if published_status; then
    printf 'publish: unseal %s is already published; nothing to do.\n' "$release_version"
    return
  fi

  run_release_gate
  fetch_and_require_synced_main
  require_command gh
  gh auth status >/dev/null 2>&1 || fail 'GitHub CLI is not authenticated; run gh auth login first.'
  require_tag_at_head

  release_existing_url=$(github_release_url)
  [ -n "$release_existing_url" ] ||
    fail "$release_tag has no GitHub Release; run make release-github VERSION=$release_version first"

  printf 'publish: GitHub release verified: %s\n' "$release_existing_url"
  printf 'publish: starting interactive pub.dev publication for unseal %s\n' "$release_version"
  "$release_dart_bin" pub publish
}

case "$release_operation" in
  check) run_release_gate ;;
  github) run_github_release ;;
  publish) run_publish ;;
  *) fail 'usage: tool/release.sh check|github|publish (set VERSION=x.y.z)' ;;
esac
