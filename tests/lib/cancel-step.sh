#!/usr/bin/env bash
# The step "A cancelled run does not count as a test result" of mpv-auto-update.yml, run
# case by case against stand-ins for gh and jq: which branches does it delete?
# One line per case, then "<n> failed"; exits with that number.
#   bash tests/lib/cancel-step.sh .github/workflows/mpv-auto-update.yml
set -u
script=$(awk '
  /name: A cancelled run does not count as a test result/ { found = 1 }
  found && /^        run: \|/ { grab = 1; next }
  grab && /^ {0,8}[^ ]/ { exit }
  grab { sub(/^          /, ""); print }' "$1")
if [ -z "$script" ]; then
  echo "the step was not found in $1"
  exit 1
fi

LOG=$(mktemp)
# gh: DELETE is recorded; the branch's mpv-build.json is $OFFERED (none: no branch); the
# open pull request is $PR (fail: the lookup fails)
gh() {
  if [ "$1 $2" = "api -X" ]; then echo "DELETE ${4##*/heads/}" >> "$LOG"; return 0; fi
  if [ "$1 $2" = "api -H" ]; then
    if [ "$OFFERED" = none ]; then echo '{"message":"Not Found"}'; return 1; fi
    printf '{"tag":"%s"}\n' "$OFFERED"
    return 0
  fi
  if [ "$1 $2" = "pr list" ]; then
    if [ "$PR" = fail ]; then return 1; fi
    printf '%s\n' "$PR"
    return 0
  fi
  echo "unexpected: gh $*" >&2
  return 99
}
jq() {
  if [ "$*" != "-r .tag" ]; then echo "unexpected: jq $*" >&2; return 99; fi
  sed -n 's/.*"tag":"\([^"]*\)".*/\1/p'
}
export -f gh jq

failed=0
check() { # case, mpv-update's build, open pull request, the deletions expected
  : > "$LOG"
  OFFERED=$2 PR=$3 GH_REPO=o/r BRANCH=mpv/20261023 PR_BRANCH=mpv-update LOG=$LOG \
    bash -e -c "$script" 2> /dev/null
  got=$(sort "$LOG" | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$4" ]; then
    echo "PASS $1"
  else
    echo "FAIL $1: deleted '$got', expected '$4'"
    failed=$((failed + 1))
  fi
}
check "mpv-update offers this build with no pull request" 20261023 '' "DELETE mpv-update DELETE mpv/20261023"
check "mpv-update offers an older build (its pull request closed)" 20261021 '' "DELETE mpv/20261023"
check "a pull request is open" 20261023 17 "DELETE mpv/20261023"
check "no mpv-update branch" none '' "DELETE mpv/20261023"
check "the pull request lookup fails" 20261023 fail "DELETE mpv/20261023"
rm -f "$LOG"
echo "$failed failed"
exit "$failed"
