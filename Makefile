.PHONY: help release-check release-github publish

VERSION ?=
YES ?= 0
DART_BIN ?=

help:
	@printf '%s\n' \
	  'Unseal release commands:' \
	  '  make release-check VERSION=1.1.0' \
	  '      Validate metadata, repository state, formatting, analysis, tests,' \
	  '      deterministic fuzzing, corpus manifest, and pub.dev dry-run.' \
	  '  make release-github VERSION=1.1.0' \
	  '      Re-run the release gate, require main == origin/main, then create' \
	  '      and push vVERSION and create the matching GitHub Release.' \
	  '  make publish VERSION=1.1.0' \
	  '      Re-run the release gate, require the matching remote tag and' \
	  '      GitHub Release, then start the interactive pub.dev publication.' \
	  '' \
	  'Options:' \
	  '  YES=1                 Skip the release-github confirmation.' \
	  '  DART_BIN=/path/dart  Override Dart executable discovery.'

release-check:
	@VERSION='$(VERSION)' DART_BIN='$(DART_BIN)' sh tool/release.sh check

release-github:
	@VERSION='$(VERSION)' YES='$(YES)' DART_BIN='$(DART_BIN)' sh tool/release.sh github

publish:
	@VERSION='$(VERSION)' DART_BIN='$(DART_BIN)' sh tool/release.sh publish
