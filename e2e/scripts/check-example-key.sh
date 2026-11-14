#!/usr/bin/env bash
#
# Refuse to build the KickFlip example without a usable workspace SDK key, so nobody ends up with an
# app whose every install/open/event call comes back 401. One script, three callers:
#
#   bash scripts/check-example-key.sh              # XcodeGen preGenCommand (example/project.yml):
#                                                  # a non-zero exit aborts `xcodegen generate`
#   bash scripts/check-example-key.sh --resolved   # the "Check LinkTrail SDK key" build phase: checks
#                                                  # $LINKTRAIL_API_KEY, the value the build resolved
#   bash scripts/check-example-key.sh --secrets FILE   # use another Secrets.xcconfig (tests)
#
# Which key the build uses (mirrors example/Config/KickFlip.xcconfig):
#   - LINKTRAIL_API_KEY in example/Config/Secrets.xcconfig (gitignored) wins when it is set there;
#   - otherwise $LINKTRAIL_KEY.
#   - Exception: e2e/scripts/e2e-maestro.sh exports LINKTRAIL_KEY_FROM_ENV=1
#     and build with an override xcconfig, so for them $LINKTRAIL_KEY always wins.
#
# A valid key starts with `lt_live_`, is at least 24 characters and contains no whitespace.
# The key value is never printed, on success or on any error path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/example/Config/Secrets.xcconfig"
RESOLVED=0
MIN_LENGTH=24
PREFIX="lt_live_"

usage() { echo "usage: $0 [--resolved] [--secrets FILE]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --resolved) RESOLVED=1; shift ;;
    --secrets)  [ $# -ge 2 ] || usage; SECRETS="$2"; shift 2 ;;
    *) usage ;;
  esac
done

help_text() {
  cat >&2 <<EOF

Set your workspace SDK key (LinkTrail dashboard -> Settings -> SDK keys) one of two ways:

  1. Environment variable (command line / scripts):
       LINKTRAIL_KEY=lt_live_... bash e2e/scripts/e2e-maestro.sh

  2. Gitignored xcconfig (building from Xcode; wins over the environment variable):
       cp e2e/example/Config/Secrets.xcconfig.example e2e/example/Config/Secrets.xcconfig
       # then set LINKTRAIL_API_KEY = lt_live_... in it

See e2e/README.md.
EOF
}

# die <message> — Xcode shows `error: ...` lines as build errors.
die() { echo "error: $*" >&2; help_text; exit 1; }

# validate <key> <where> — reject empty, blank, whitespace, placeholder and malformed keys.
validate() {
  local key="$1" where="$2"
  [ -n "$key" ] || die "the LinkTrail SDK key from $where is empty."
  if [[ "$key" =~ ^[[:space:]]+$ ]]; then die "the LinkTrail SDK key from $where is only whitespace."; fi
  if [[ "$key" =~ [[:space:]] ]]; then
    die "the LinkTrail SDK key from $where contains whitespace (leading, trailing or inside it)."
  fi
  case "$key" in
    *REPLACE*|*'…'*|*...*)
      die "the LinkTrail SDK key from $where is still the placeholder; the backend rejects it (401)." ;;
  esac
  [[ "$key" == "$PREFIX"* ]] || die "the LinkTrail SDK key from $where does not start with '$PREFIX'."
  [ "${#key}" -ge "$MIN_LENGTH" ] || die "the LinkTrail SDK key from $where is too short to be an SDK key (under $MIN_LENGTH characters)."
}

if [ "$RESOLVED" = 1 ]; then
  validate "${LINKTRAIL_API_KEY:-}" "the LINKTRAIL_API_KEY build setting"
  echo "LinkTrail SDK key: set"
  exit 0
fi

if [ "${LINKTRAIL_KEY_FROM_ENV:-}" = 1 ]; then
  [ -n "${LINKTRAIL_KEY:-}" ] || die "no LinkTrail SDK key: \$LINKTRAIL_KEY is not set."
  validate "$LINKTRAIL_KEY" "\$LINKTRAIL_KEY"
  echo "LinkTrail SDK key: using \$LINKTRAIL_KEY"
  exit 0
fi

name="$(basename "$SECRETS")"
if [ -f "$SECRETS" ]; then
  # Strip CR (Windows line endings) and `// comments`, then look at LINKTRAIL_API_KEY assignments.
  body="$(tr -d '\r' < "$SECRETS" | sed -E 's#//.*$##')"
  if printf '%s\n' "$body" | grep -qE '^[[:space:]]*LINKTRAIL_API_KEY[[:space:]]*\['; then
    die "$name sets LINKTRAIL_API_KEY conditionally (e.g. [config=Debug]); set it unconditionally: LINKTRAIL_API_KEY = lt_live_..."
  fi
  assignments="$(printf '%s\n' "$body" | grep -E '^[[:space:]]*LINKTRAIL_API_KEY[[:space:]]*=' || true)"
  if [ -n "$assignments" ]; then
    # Last assignment wins, like xcconfig itself; surrounding whitespace is not part of the value.
    key="$(printf '%s\n' "$assignments" | tail -1 \
           | sed -E 's#^[[:space:]]*LINKTRAIL_API_KEY[[:space:]]*=[[:space:]]*##; s#[[:space:]]+$##')"
    [ -n "$key" ] || die "$name sets LINKTRAIL_API_KEY to an empty value (which also hides \$LINKTRAIL_KEY)."
    validate "$key" "$name"
    echo "LinkTrail SDK key: using $name"
    exit 0
  fi
  if printf '%s\n' "$body" | grep -qE '^[[:space:]]*#include'; then
    die "$name does not set LINKTRAIL_API_KEY itself, and this check does not follow #include. Set LINKTRAIL_API_KEY = lt_live_... directly in $name."
  fi
  # The file exists but does not assign the key: the xcconfig falls through to $LINKTRAIL_KEY.
  [ -n "${LINKTRAIL_KEY:-}" ] \
    || die "no LinkTrail SDK key: $name has no LINKTRAIL_API_KEY line and \$LINKTRAIL_KEY is not set."
  validate "$LINKTRAIL_KEY" "\$LINKTRAIL_KEY"
  echo "LinkTrail SDK key: using \$LINKTRAIL_KEY"
  exit 0
fi

[ -n "${LINKTRAIL_KEY:-}" ] \
  || die "no LinkTrail SDK key: \$LINKTRAIL_KEY is not set and there is no $name. Without a key every install/open/event call is rejected (401)."
validate "$LINKTRAIL_KEY" "\$LINKTRAIL_KEY"
echo "LinkTrail SDK key: using \$LINKTRAIL_KEY"
