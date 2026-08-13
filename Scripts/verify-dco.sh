#!/bin/bash

set -euo pipefail

if (( $# != 2 )); then
  printf 'Usage: %s <base-commit> <head-commit>\n' "$0" >&2
  exit 2
fi

CAMENYA_BASE=$1
CAMENYA_HEAD=$2
CAMENYA_FAILURES=0

while IFS= read -r commit; do
  author_name=$(git show -s --format=%an "$commit")
  author_email=$(git show -s --format=%ae "$commit")
  required_signoff="Signed-off-by: $author_name <$author_email>"

  if ! git show -s --format=%B "$commit" | grep -Fqx "$required_signoff"; then
    printf 'Missing matching DCO sign-off in commit %s by %s <%s>.\n' \
      "$commit" "$author_name" "$author_email" >&2
    CAMENYA_FAILURES=$((CAMENYA_FAILURES + 1))
  fi
done < <(git rev-list --reverse "$CAMENYA_BASE..$CAMENYA_HEAD")

if (( CAMENYA_FAILURES > 0 )); then
  exit 1
fi

printf 'DCO sign-offs passed.\n'
