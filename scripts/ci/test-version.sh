#!/bin/sh
# A test build takes the workspace version and adds -dev. and the CI run's
# number (0.0.0-dev.42). A release build sets the version from its tag.
#   scripts/ci/test-version.sh
set -eu
version=$(sed -n 's/^version = "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*"/\1/p' Cargo.toml | head -1)
v="${version:?no workspace version in Cargo.toml}-dev.${GITHUB_RUN_NUMBER:-0}"
perl -pi -e 's/^version = "[^"]*"/version = "'"$v"'"/ && ($done = 1) unless $done' Cargo.toml
grep -m1 '^version = ' Cargo.toml
