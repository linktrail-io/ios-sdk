#!/usr/bin/env bash
#
# Deferred-deep-link E2E — ALL IN MAESTRO. Twelve flows: {custom domain, subdomain} × {allow, deny}
# × {automatic, pasteButton, problistic}, plus the re-engagement flows (reengage_*.yaml: the app is
# installed and launched once, then the link is opened again), which run once per link type. Every flow drives the real, complete path in Safari and the app:
#   type the campaign link in Safari → the web interstitial stages the lt_click token on the clipboard
#   → fresh install of the app (clearState) → consent → assert where the user lands.
# The app is built against the PUBLISHED SDK: the binary package at this repo's SPM release tag
# (exactVersion in e2e/example/project.yml, the one place the tested version lives), resolved from
# GitHub exactly as a customer app resolves it.
#
# E2E_BUILD_ONLY=1 stops after the builds (no simulator, no flows): CI uses it to prove the published
# package still resolves and compiles when no SDK key is available (fork pull requests).
#
# The consent modes (each flow declares its own in its `env:` block — see below):
#   • automatic   — the SDK reads the clipboard itself, so iOS raises the "Allow Paste" system alert;
#                   the flow taps "Allow Paste" / "Don't Allow Paste".
#   • pasteButton — no auto-read and NO system alert; the app opens on a consent gate and the flow
#                   taps the native "Paste" control (the tap is the consent) or "Not now".
#   • none        — the clipboard is never touched; the app asks for tracking consent instead.
#
# Each flow file declares the build it needs:
#     env:
#       LINKTRAIL_TOKEN_SOURCE: automatic | pasteButton | none
# Every distinct mode is built ONCE up front and parked as a ready-to-install .app, so running a flow
# only costs an install (a couple of seconds). That is what lets ANY flow run on ANY device.
#
# Run ALL flows, or just the one(s) you name (full filename, bare name, or any unique substring).
# Either way the build a flow needs is installed first — which is why you should run flows through
# this script rather than `maestro test <flow>.yaml` directly (Maestro has no build hook and cannot
# shell out, so running a yaml on its own just uses whatever happens to be installed):
#     LINKTRAIL_KEY=lt_live_… bash e2e/scripts/e2e-maestro.sh                          # all, serially
#     LINKTRAIL_KEY=lt_live_… bash e2e/scripts/e2e-maestro.sh custom_allow_pastebutton # just one
#
# PARALLEL=<n> spreads the flows over n simulators (booting more as needed); DEVICES=<udid,udid,…>
# picks specific ones. Builds still happen serially up front — concurrent xcodebuilds would race on
# the shared .xcodeproj and DerivedData.
#     LINKTRAIL_KEY=lt_live_… PARALLEL=4 bash e2e/scripts/e2e-maestro.sh
# Caveat: every extra booted simulator is another competing WebDriverAgent, which is itself a source
# of the transport drops described below — fastest is not automatically most reliable.
#
# The workspace API key comes from the environment (never committed):
#     LINKTRAIL_KEY=lt_live_… bash e2e/scripts/e2e-maestro.sh
# It is REQUIRED: the allow flows assert the user lands on the linked product, which only happens
# when the backend accepts the key and resolves the deferred link.
#
# Maestro's XCUITest transport (WebDriverAgent) intermittently dies on iOS 26 sims — you see
# `Transport unreachable` / `Connection refused`, and it can surface on ANY step (often the first
# Safari tap), not just the paste dialog. A dead driver stays dead, so a plain retry hits the same
# corpse; on that error this runner kills the stale driver and retries with --reinstall-driver.
# Each flow gets RETRIES attempts.
#
# Requires: Xcode, XcodeGen, mobile.dev Maestro (~/.maestro/bin).
set -euo pipefail
export PATH="$HOME/.maestro/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"   # CI non-login shell

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/example"
APP_ID="io.linktrail.kickflipdemo"
DERIVED="$EXAMPLE/.build-e2e"
STAGE="$DERIVED/staged"                 # one ready-to-install .app per mode
RETRIES="${RETRIES:-3}"
PARALLEL="${PARALLEL:-1}"

# Which environment and links this run tests. Every host, slug and backend URL lives in ONE file,
# e2e/scripts/e2e-env.json; e2e/scripts/e2e-env.py resolves it from these variables (all optional,
# empty = the default) and fails fast on a bad value, e.g. a link host the environment does not allow:
#   LINKTRAIL_ENV                  prod (the only environment: the published SDK talks to production)
#   E2E_CUSTOM_LINK, E2E_SUBDOMAIN_LINK, E2E_CUSTOM_PROBLISTIC_LINK, E2E_SUBDOMAIN_PROBLISTIC_LINK
#                                  a full https URL, or a bare slug on the environment's host
#   E2E_EXPECT_PRODUCT, E2E_EXPECT_VOUCHER   what the click-token allow flows must show
# The flows are host-neutral: they type ${LINK_URL} and assert ${EXPECT_VOUCHER_TEXT}, both passed
# with -e. (A flow must NOT carry its own default for them: an in-file `env:` value takes precedence
# over -e and would pin it.)
ENV_PY="$ROOT/scripts/e2e-env.py"
TARGETS="$(python3 -I "$ENV_PY" resolve)" || exit 1
eval "$TARGETS"   # shell-quoted by e2e-env.py: E2E_ENV_NAME, BACKEND_URL, SET_SDK_BASE, KEY_SECRET, hosts, links, EXPECT_*

# Simulator-wide environment for the app (Maestro launches it and cannot pass env vars, so it is set
# on the SIMULATOR and every app launched afterwards inherits it). The published SDK always uses its
# built-in production host; override_backend is false for prod, so LINKTRAIL_BASE is only ever unset.
set_backend() {
  local device="$1"
  # The app copies its stdout to its container so the report can show the [LinkTrail] lines.
  xcrun simctl spawn "$device" launchctl setenv E2E_CONSOLE_LOG 1 2>/dev/null || true
  if [ "$SET_SDK_BASE" = "1" ]; then
    xcrun simctl spawn "$device" launchctl setenv LINKTRAIL_BASE "$BACKEND_URL" 2>/dev/null || true
  else
    xcrun simctl spawn "$device" launchctl unsetenv LINKTRAIL_BASE 2>/dev/null || true
  fi
}

# link_url <flow.yaml> — the campaign link a flow drives: its slot (scripts/e2e-flows.json) resolved
# for this run by e2e-env.py, exported as E2E_URL_<flow name>.
link_url() {
  local var
  var="E2E_URL_$(basename "$1" .yaml)"
  [ -n "${!var:-}" ] || { echo "ERROR: no link for $1 — give it a 'slot' in scripts/e2e-flows.json" >&2; return 1; }
  echo "${!var}"
}
# reengage_url <https link>: what a re-engagement flow opens (Maestro openLink, i.e. simctl openurl).
# The e2e build is unsigned, so it has no Associated Domains and iOS would hand the https link to
# Safari; the DEBUG example app's kickflip://e2e-universal-link?url=<link> forwarder passes it to the
# SDK exactly like a Universal Link (example/KickFlipDemo/SDK/AttributionCoordinator.swift).
reengage_url() {
  python3 -I -c 'import sys, urllib.parse; print("kickflip://e2e-universal-link?url=" + urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}
# Maestro's default wait for the XCUITest driver to come up is short, and a loaded machine (several
# simulators, a build running) blows straight through it — "iOS driver not ready in time".
export MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-120000}"

# Run order and the report's row metadata (link, match, consent, expected) live in ONE table:
# e2e/scripts/e2e-flows.json.
REPORT_PY="$ROOT/scripts/e2e-report.py"
ALL_FLOWS="$(python3 -I "$REPORT_PY" list-flows)" || { echo "ERROR: could not read scripts/e2e-flows.json"; exit 1; }

# Per-attempt results for the e2e report (scripts/e2e-report.py renders them; the workflow publishes
# the table to the run summary, an artifact and the PR comment). One JSON line per attempt.
E2E_REPORT_DIR="${E2E_REPORT_DIR:-$DERIVED/report}"
RESULTS="$E2E_REPORT_DIR/results.jsonl"
# Where the example app copies its stdout (the SDK's [LinkTrail] lines) when E2E_CONSOLE_LOG=1 is
# set on the simulator — see example/KickFlipDemo/App/E2EConsoleLog.swift. Relative to the app's data
# container; read after each attempt, before the next uninstall wipes it.
APP_CONSOLE_LOG="Library/Caches/e2e-console.log"

# The published SDK version under test: the package's exactVersion in e2e/example/project.yml.
SDK_VERSION="$(sed -n 's/^ *exactVersion: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$EXAMPLE/project.yml" | head -1)"
[ -n "$SDK_VERSION" ] || { echo "ERROR: no 'exactVersion:' for the LinkTrail package in e2e/example/project.yml"; exit 1; }
echo "-- published SDK under test: $SDK_VERSION"

command -v xcodegen >/dev/null 2>&1 || { echo "ERROR: xcodegen not found (brew install xcodegen)"; exit 1; }
[ "${E2E_BUILD_ONLY:-0}" = "1" ] || command -v maestro >/dev/null 2>&1 || { echo "ERROR: Maestro (mobile.dev) not found: curl -Ls https://get.maestro.mobile.dev | bash"; exit 1; }
# The environment's SDK key comes from the variable named by key_secret in e2e/scripts/e2e-env.json
# (LINKTRAIL_KEY for prod); CI passes that secret in LINKTRAIL_KEY.
if [ "$KEY_SECRET" != "LINKTRAIL_KEY" ] && [ -n "${!KEY_SECRET:-}" ]; then
  LINKTRAIL_KEY="${!KEY_SECRET}"
fi
[ -n "${LINKTRAIL_KEY:-}" ] || { echo "ERROR: no SDK key for environment '$E2E_ENV_NAME' (set $KEY_SECRET, or LINKTRAIL_KEY). The allow flows assert the deferred link routes to the product, which needs a real key:"; echo "         LINKTRAIL_KEY=lt_live_… bash e2e/scripts/e2e-maestro.sh"; exit 1; }
# The key reaches the build through the environment only: LINKTRAIL_KEY_FROM_ENV tells the key check
# (scripts/check-example-key.sh, also xcodegen's preGenCommand) to use it, and XCODE_XCCONFIG_FILE makes
# it win over a local Secrets.xcconfig. Never pass it as an xcodebuild argument: xcodebuild echoes
# command-line build settings into the build log, which this script tails on failure.
export LINKTRAIL_KEY LINKTRAIL_KEY_FROM_ENV=1
export XCODE_XCCONFIG_FILE="$EXAMPLE/Config/EnvOverride.xcconfig"
bash "$ROOT/scripts/check-example-key.sh" || exit 1

# $LINKTRAIL_KEY reaches Info.plist through the LINKTRAIL_API_KEY build setting, so no source
# file is ever mutated: nothing to back up or restore, and concurrent builds can't race.

# mode_of <flow.yaml> — the build a flow declares in its env: block.
mode_of() {
  local mode
  mode="$(grep -m1 'LINKTRAIL_TOKEN_SOURCE:' "$ROOT/scripts/$1" | sed 's/.*: *//' | tr -d '"'"'"' \r')"
  case "$mode" in
    automatic|pasteButton|none) echo "$mode" ;;
    *) echo "ERROR: $1 must declare 'LINKTRAIL_TOKEN_SOURCE: automatic|pasteButton|none' in its env: block (got '$mode')" >&2; return 1 ;;
  esac
}

# resolve_flow <name> — accept a full filename, a bare name, or any unique substring.
resolve_flow() {
  local q="$1" hits
  [ -f "$ROOT/scripts/$q" ] && { echo "$q"; return 0; }
  [ -f "$ROOT/scripts/$q.yaml" ] && { echo "$q.yaml"; return 0; }
  hits=$(cd "$ROOT/scripts" && ls deferred_*.yaml reengage_*.yaml reward_*.yaml | grep -i -- "$q" || true)
  case "$(printf '%s' "$hits" | grep -c .)" in
    1) echo "$hits"; return 0 ;;
    0) echo "ERROR: no flow matches '$q'. Available:" >&2; (cd "$ROOT/scripts" && ls deferred_*.yaml reengage_*.yaml reward_*.yaml) >&2; return 1 ;;
    *) echo "ERROR: '$q' is ambiguous:" >&2; echo "$hits" >&2; return 1 ;;
  esac
}

# stage_mode <mode> — build once, park the .app so every device can just install it.
# Serial by design: parallel xcodebuilds would race on the shared .xcodeproj and DerivedData.
stage_mode() {
  local mode="$1" app
  echo "-- building the example against the published SDK $SDK_VERSION (clickTokenSource: $mode, linkHost: $SUBDOMAIN_HOST)"
  ( cd "$EXAMPLE" && xcodegen generate >/dev/null )
  mkdir -p "$DERIVED"
  # Non-secret build settings are passed as xcodebuild ARGUMENTS: those win over the project's own
  # values. The key comes from the environment via XCODE_XCCONFIG_FILE (see above).
  xcodebuild -project "$EXAMPLE/KickFlipDemo.xcodeproj" -scheme KickFlipDemo \
    LINKTRAIL_TOKEN_SOURCE="$mode" LINKTRAIL_LINK_HOST="$SUBDOMAIN_HOST" LINKTRAIL_CUSTOM_LINK_HOST="$CUSTOM_HOST" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build \
    > "$DERIVED/build-$mode.log" 2>&1 \
    || { echo "ERROR: build failed ($mode):"; tail -25 "$DERIVED/build-$mode.log"; exit 1; }
  app="$(/usr/bin/find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$app" ] || { echo "ERROR: built .app not found ($mode)"; exit 1; }
  mkdir -p "$STAGE"; rm -rf "$STAGE/$mode.app"; cp -R "$app" "$STAGE/$mode.app"
  echo "-- staged $mode"
}

# shellcheck source=e2e/scripts/e2e-verify.sh
source "$ROOT/scripts/e2e-verify.sh"

# record_attempt <flow name> <attempt> <pass|fail> <started epoch> [record options…]: one JSON line
# in $RESULTS for the report. Never fails the run: a report problem must not mask the flow result.
record_attempt() {
  local name="$1" attempt="$2" status="$3" started="$4"; shift 4
  python3 -I "$REPORT_PY" record --results "$RESULTS" --flow "$name" --attempt "$attempt" --status "$status" --link "${url:-}" \
    --duration "$(( $(date +%s) - started ))" "$@" >/dev/null 2>&1 \
    || echo "WARN: could not record $name attempt $attempt for the e2e report"
}

# copy_app_log <device> <applog>: the app's console (its [LinkTrail] lines) from its data container.
copy_app_log() {
  local container
  : > "$2"
  container="$(xcrun simctl get_app_container "$1" "$APP_ID" data 2>/dev/null || true)"
  if [ -n "$container" ] && [ -f "$container/$APP_CONSOLE_LOG" ]; then cp "$container/$APP_CONSOLE_LOG" "$2"; fi
}

# read_device_id <device>: the SDK device id the DEBUG example app shows on its e2e-device-id label
# and writes to its data container (example/KickFlipDemo/App/E2EDebug.swift), or nothing.
read_device_id() {
  local container
  container="$(xcrun simctl get_app_container "$1" "$APP_ID" data 2>/dev/null || true)"
  [ -n "$container" ] && [ -f "$container/Library/Caches/e2e-device-id.txt" ] && tr -d ' \n\r' < "$container/Library/Caches/e2e-device-id.txt" || true
}

# failure_evidence <device> <name> <attempt> <applog>: screenshot the simulator and copy the app's
# console to <applog>. Prints the screenshot path relative to the report dir.
failure_evidence() {
  local device="$1" name="$2" attempt="$3" applog="$4" shot
  shot="screenshots/$name-attempt$attempt.png"
  mkdir -p "$E2E_REPORT_DIR/screenshots"
  xcrun simctl io "$device" screenshot "$E2E_REPORT_DIR/$shot" >/dev/null 2>&1 || shot=""
  copy_app_log "$device" "$applog"
  echo "$shot"
}

# run_flow <device> <flow.yaml[@link type]> — install the build this flow needs, then run it (with
# driver recovery). With @<type> it is a link-type matrix run, reported as <flow>__<type>: the flow
# types that type's link (scripts/e2e-env.json link_types) and, on allow, must also show the
# link-type expectations (product, voucher, and the debug meta row: linkType == <type>, source).
# Every attempt is recorded for the report (record_attempt), with the failed step, the app's last
# [LinkTrail] lines and a screenshot when it fails.
run_flow() {
  local -a after_env=()
  local device="$1" flow="${2%@*}" ltype="" name attempt log reinstall="" mode parts token started applog shot vout vout2 vok b url rurl state after_ok after_check eurl consent status
  local vtext="$EXPECT_VOUCHER_TEXT" ptext="$EXPECT_PRODUCT_TEXT"
  [ "$flow" = "$2" ] || ltype="${2#*@}"
  name="$(basename "$flow" .yaml)${ltype:+__$ltype}"
  [ -z "$ltype" ] || { vtext="$LT_EXPECT_VOUCHER_TEXT"; ptext="$LT_EXPECT_PRODUCT_TEXT"; }
  started="$(date +%s)"
  if ! mode="$(mode_of "$flow")"; then
    record_attempt "$name" 1 fail "$started" --failed-step "read the flow's LINKTRAIL_TOKEN_SOURCE" --device "$device"
    return 1
  fi
  if ! url="$(link_url "$name")"; then
    record_attempt "$name" 1 fail "$started" --failed-step "resolve the flow's link (scripts/e2e-flows.json slot)" --device "$device"
    return 1
  fi
  parts="$(mktemp -d -t maestroparts)"
  if ! prepare_flow "$flow" "$parts" "$ptext" "$ltype" "$LT_EXPECT_SOURCE_TEXT"; then
    rm -rf "$parts"
    record_attempt "$name" 1 fail "$started" --failed-step "split the flow into its Safari and app halves" --device "$device"
    echo "ERROR: $name — could not prepare the flow (split + extra asserts)"; return 1
  fi
  log="$(mktemp -t maestroflow)"
  applog="$(mktemp -t e2eapplog)"
  rurl="$(reengage_url "$url")"
  state="$parts/verify-state"
  for attempt in $(seq 1 "$RETRIES"); do
    started="$(date +%s)"
    : > "$log"
    set_backend "$device"                                                # point the SDK at this environment's API
    xcrun simctl uninstall "$device" "$APP_ID" >/dev/null 2>&1 || true   # true first-time install, no leftover state
    # An install that fails means the device is gone, shutting down, or wedged — not that the flow is
    # broken. Unguarded it would trip `set -e` and abort the whole run mid-suite (which is how run
    # 33262884851 ended: another job's cleanup shut the simulator down under us). Try to bring the
    # device back and spend an attempt on it instead.
    if ! xcrun simctl install "$device" "$STAGE/$mode.app" >/dev/null; then
      echo "WARN: $name — could not install on ${device%%-*} (attempt $attempt/$RETRIES); the simulator is down or shutting down. Rebooting it."
      record_attempt "$name" "$attempt" fail "$started" --device "$device" \
        --failed-step "install the app on the simulator" --error "simctl install failed; the simulator is down or shutting down"
      xcrun simctl boot       "$device" >/dev/null 2>&1 || true
      xcrun simctl bootstatus "$device" -b >/dev/null 2>&1 || true
      sleep 5
      continue
    fi
    printf '' | xcrun simctl pbcopy "$device"       # empty clipboard; the flow's Safari step stages the token
    echo "==== $name [$mode] $url on ${device%%-*} (attempt $attempt/$RETRIES) ===="
    # Safari half, then read the staged token off the pasteboard, then the app half (see split_flow).
    if maestro ${reinstall:+$reinstall} --device "$device" test -e LINK_URL="$url" -e EXPECT_VOUCHER_TEXT="$vtext" "$parts/safari.yaml" 2>&1 | tee "$log"; then
      token="$(capture_token "$device")"
      if [ -n "$token" ]; then echo "-- $name: lt_click token captured (${token:0:8}…)"; else echo "-- $name: lt_click token not on the clipboard"; fi
      if maestro --device "$device" test -e LINK_URL="$url" -e EXPECT_VOUCHER_TEXT="$vtext" "$parts/app.yaml" 2>&1 | tee "$log"; then
        # The UI passed; now the backend must agree. Not retried: a re-run would be a new click.
        # A link-type run also checks the link's reward and this click's earning (VERIFY_LINK_TYPE);
        # a flow with a third part keeps this check's counts and reward (VERIFY_STATE) for it.
        rm -f "$state"
        after_ok=1
        if [ "$mode" = none ]; then
          # Probabilistic: no click token reaches the device, so look the install up by the SDK
          # device id the app shows on its debug label (and writes to its container).
          vout="$(VERIFY_NAME="$name" verify_device "$flow" "$(read_device_id "$device")" "$url")" && vok=1 || vok=0
          if [ "$vok" = 1 ] && [[ "$flow" == *_deny_* ]]; then
            # The backend must show nothing, and the app must show that the denial did go out: one
            # consent:false install (an SDK that sent nothing at all would also leave the backend empty).
            copy_app_log "$device" "$applog"
            if ! denied_install_sent "$applog"; then
              vout="$vout; VERIFY FAIL: $name — the app's [LinkTrail] log has no consent:false install (\"$(denied_install_line)\")"; vok=0
            fi
          fi
        else
          vout="$(VERIFY_NAME="$name" VERIFY_LINK_TYPE="$ltype" VERIFY_STATE="$([ -f "$parts/after.yaml" ] && echo "$state")" verify_flow "$flow" "$token")" && vok=1 || vok=0
        fi
        if [ "$vok" != 1 ]; then
          echo "$vout"
          shot="$(failure_evidence "$device" "$name" "$attempt" "$applog")"
          record_attempt "$name" "$attempt" fail "$started" --device "$device" --backend fail --backend-detail "$vout" \
            --failed-step "backend install check (scripts/e2e-verify.sh)" --app-log "$applog" --screenshot "$shot"
          rm -f "$log" "$applog"; rm -rf "$parts"
          echo "ERROR: $name [$mode] failed the backend install check"; return 1
        fi
        echo "$vout"
        vout2=""
        if [ -f "$parts/after.yaml" ]; then
          case "$flow" in
            reengage_*)
              # Re-engagement: the app is installed and was launched once; open the same link again.
              echo "-- $name: re-engagement open (${rurl%%\?*}?url=…)"
              after_env=(-e REENGAGE_URL="$rurl"); after_check=verify_reengage ;;
            *)
              # Reward events: what the app sends depends on the link's reward, read by the first check.
              if ! check_enabled earning; then
                after_env=(); after_check=""   # the backend has no earning yet: nothing to judge the events by
                vout="$vout; $(not_deployed "$name" "reward events" earning)"
              elif [ ! -s "$state" ]; then
                after_env=(); after_check=""   # no backend check (VERIFY SKIP): nothing to build the events from
              elif ! eurl="$(events_url "$(cat "$state")")"; then
                echo "$eurl"
                shot="$(failure_evidence "$device" "$name" "$attempt" "$applog")"
                record_attempt "$name" "$attempt" fail "$started" --device "$device" --backend fail --backend-detail "$vout" \
                  --failed-step "build the reward events (scripts/e2e-verify.sh events_url)" --error "$eurl" --app-log "$applog" --screenshot "$shot"
                rm -f "$log" "$applog"; rm -rf "$parts"
                echo "ERROR: $name [$mode] could not build the reward events"; return 1
              else
                echo "-- $name: reward events ($(events_count "$eurl")): ${eurl#*\?}"
                consent=allow; [[ "$flow" == *_deny_* ]] && consent=deny
                after_env=(-e EVENTS_URL="$eurl" -e EXPECT_EVENTS_TEXT="$(events_expect "$eurl" "$consent")"); after_check=verify_events
              fi ;;
          esac
          if [ -z "${after_check:-}" ]; then
            echo "-- $name: backend check skipped, so the reward events are not sent"
          elif maestro --device "$device" test -e LINK_URL="$url" -e EXPECT_VOUCHER_TEXT="$vtext" "${after_env[@]}" "$parts/after.yaml" 2>&1 | tee "$log"; then
            if [ "$after_check" = verify_reengage ]; then
              vout2="$(VERIFY_NAME="$name" VERIFY_LINK_TYPE="$ltype" verify_reengage "$flow" "$token" "$(cat "$state" 2>/dev/null)")" && vok=1 || vok=0
            else
              vout2="$(VERIFY_NAME="$name" VERIFY_LINK_TYPE="$ltype" verify_events "$flow" "$token")" && vok=1 || vok=0
            fi
            if [ "$vok" != 1 ]; then
              echo "$vout2"
              shot="$(failure_evidence "$device" "$name" "$attempt" "$applog")"
              record_attempt "$name" "$attempt" fail "$started" --device "$device" --backend fail --backend-detail "$vout; $vout2" \
                --failed-step "backend ${after_check#verify_} check (scripts/e2e-verify.sh)" --app-log "$applog" --screenshot "$shot"
              rm -f "$log" "$applog"; rm -rf "$parts"
              echo "ERROR: $name [$mode] failed the backend ${after_check#verify_} check"; return 1
            fi
            echo "$vout2"
          else
            # A UI failure in the third part: like any other UI failure, the whole flow is retried
            # below (fresh install, new click), so the next attempt starts from zero again.
            after_ok=0
          fi
        fi
        if [ "$after_ok" = 1 ]; then
          case "$vout" in VERIFY\ OK*) b=ok ;; *) b=skip ;; esac
          # A row whose point is a backend check that was skipped is "skipped", never a pass.
          status="$(row_status "$flow" "$ltype" "$vout${vout2:+; $vout2}")"
          [ "$status" = pass ] || b=skip
          copy_app_log "$device" "$applog"   # only counted on a pass: proves the capture works
          record_attempt "$name" "$attempt" "$status" "$started" --device "$device" --backend "$b" --backend-detail "$vout${vout2:+; $vout2}" --app-log "$applog"
          rm -f "$log" "$applog"; rm -rf "$parts"
          if [ "$status" = pass ]; then echo "OK: $name [$mode]"; else echo "SKIPPED: $name [$mode] — backend check not run (see the VERIFY SKIP line)"; fi
          return 0
        fi
      fi
    elif [ -n "$ltype" ] && link_missing "$url"; then
      # The Safari half failed on a link-type run and the link itself answers 404: the link has
      # not been created yet. Say so, and don't retry: no attempt can pass.
      shot="$(failure_evidence "$device" "$name" "$attempt" "$applog")"
      record_attempt "$name" "$attempt" fail "$started" --device "$device" --failed-step "open the link in Safari" \
        --error "$E2E_ENV_NAME link ${url##*/} not created (404 from $url)" --screenshot "$shot"
      rm -f "$log" "$applog"; rm -rf "$parts"
      echo "ERROR: $name — $E2E_ENV_NAME link ${url##*/} not created (404 from $url)"; return 1
    fi
    shot="$(failure_evidence "$device" "$name" "$attempt" "$applog")"
    record_attempt "$name" "$attempt" fail "$started" --device "$device" --maestro-log "$log" --app-log "$applog" --screenshot "$shot"
    # "App crashed or stopped" is a black box until someone reads the crash report off the runner —
    # so surface it in the run output itself: name, exception, termination reason, top frames.
    # Something OTHER than the app can be the victim too (Safari has died mid-flow on CI), so take
    # the newest reports regardless of process, not just KickFlipDemo's.
    if grep -q "App crashed or stopped" "$log"; then
      for crash in $(ls -t "$HOME"/Library/Logs/DiagnosticReports/*.ips 2>/dev/null | head -3); do
        # only reports from the last few minutes — stale ones would misdirect the diagnosis
        [ -z "$(find "$crash" -mmin -5 2>/dev/null)" ] && continue
        echo "---- crash report: $(basename "$crash") ----"
        python3 - "$crash" <<'PYCRASH' || head -c 600 "$crash"
import json, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n", 1)
hdr = json.loads(lines[0]); body = json.loads(lines[1])
print(f"  process: {hdr.get('app_name')}  at {hdr.get('timestamp')}")
exc = body.get("exception", {})
print(f"  exception: {exc.get('type')} ({exc.get('signal')}) — {exc.get('subtype') or ''}")
term = body.get("termination", {})
print(f"  termination: {term.get('indicator') or term.get('reasons') or term}")
faulting = next((t for t in body.get("threads", []) if t.get("triggered")), None)
images = body.get("usedImages", [])
for frame in (faulting or {}).get("frames", [])[:6]:
    img = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex", -1) < len(images) else "?"
    print(f"    {img} + {frame.get('imageOffset')}  {frame.get('symbol') or ''}")
PYCRASH
      done
    fi
    # A dead XCUITest driver stays dead: retrying as-is just hits the same corpse (that's why the
    # step it dies on looks random — often the very first Safari tap). Reinstall the driver first.
    #
    # "App crashed or stopped" belongs in this bucket, not the flow-failure one: the automation
    # session (XCTAutomationSupport) intermittently SEGFAULTS SpringBoard on iOS 26 sims, which
    # takes the foreground app down with it and kills anything launched during the respawn — the
    # app is the victim, not the cause (crash reports on both dev machines and CI show SpringBoard
    # dying in -[XCTAutomationSession initWithAccessibilityFramework:], with the failing flow moving
    # run to run). Retrying through a fresh driver, after SpringBoard has respawned, is what works.
    if grep -qiE "Transport unreachable|became unreachable|Connection refused|driver status check|driver not ready in time|IOSDriverTimeout|App crashed or stopped" "$log"; then
      echo "WARN: $name — the XCUITest driver/automation session died; restarting it before the retry"
      pkill -f 'XCTestRunner|WebDriverAgent' >/dev/null 2>&1 || true   # a half-dead driver blocks the next start
      reinstall="--reinstall-driver"
      sleep 15   # long enough for SpringBoard to respawn before the next launch
    else
      echo "WARN: $name failed (attempt $attempt/$RETRIES) — a real flow/assertion failure; retrying"
      reinstall=""
    fi
  done
  rm -f "$log" "$applog"; rm -rf "$parts"
  echo "ERROR: $name [$mode] failed after $RETRIES attempts"; return 1
}

# pick_devices <n> — explicit DEVICES=…, otherwise reuse booted sims and boot more up to n.
pick_devices() {
  local want="$1" booted have extra udid
  if [ -n "${DEVICES:-}" ]; then printf '%s\n' ${DEVICES//,/ }; return 0; fi
  booted="$(xcrun simctl list devices booted | grep -oiE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' || true)"
  have="$(printf '%s\n' "$booted" | grep -c . || true)"
  if [ "$have" -lt "$want" ]; then
    extra="$(xcrun simctl list devices available | grep 'iPhone ' \
             | grep -oiE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' \
             | { [ -n "$booted" ] && grep -v -F "$booted" || cat; } | head -n $((want - have)) || true)"
    for udid in $extra; do
      echo "-- booting $udid" >&2
      xcrun simctl boot "$udid" >/dev/null 2>&1 || true
      xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    done
    booted="$(printf '%s\n%s' "$booted" "$extra")"
  fi
  printf '%s\n' "$booted" | grep . | head -n "$want"
}

# ---- pick the flows ----------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  FLOWS=""
  for arg in "$@"; do
    f="$(resolve_flow "$arg")" || exit 1
    FLOWS="$FLOWS$f
"
  done
  FLOWS="$(printf '%s' "$FLOWS" | grep . || true)"
else
  FLOWS="$ALL_FLOWS"
fi
# Link-type matrix: every selected flow marked link_type_matrix in scripts/e2e-flows.json runs once
# more per link type (E2E_LINK_TYPES) it runs on (true: every type whose reward needs no events; or
# a list), as the job <flow.yaml>@<type>. e2e-env.py names them <flow>@<type>, without the .yaml
# that run_flow, mode_of and the report's plan (.yaml@ -> __) need. Types with no link in this
# environment were dropped (with a NOTICE) by e2e-env.py. A link_type_only flow (the re-engagement
# flows) runs ONLY as those per-type jobs, never on its slot's own link.
JOBS=""
for f in $FLOWS; do
  case " $LINK_TYPE_ONLY_FLOWS " in *" ${f%.yaml} "*) ;; *) JOBS="$JOBS$f
" ;; esac
done
JOBS="$(printf '%s' "$JOBS" | grep . || true)"
for j in $LINK_TYPE_JOBS; do   # <flow>@<type>, type-major, already filtered to E2E_LINK_TYPES by e2e-env.py
  case "
$FLOWS
" in *"
${j%@*}.yaml
"*) JOBS="$JOBS
${j%@*}.yaml@${j#*@}" ;; esac
done
# (A type skipped for this environment was already reported as a NOTICE line by e2e-env.py above.)
JOBS="$(printf '%s\n' "$JOBS" | grep . || true)"
FLOW_COUNT="$(printf '%s\n' "$JOBS" | grep -c . || true)"
[ "$FLOW_COUNT" -gt 0 ] || { echo "ERROR: no flows to run (a link_type_only flow needs at least one link type for environment '$E2E_ENV_NAME'; see E2E_LINK_TYPES)"; exit 1; }

# ---- start this run's report: the planned flows (rows for flows that never ran) and no results yet
mkdir -p "$E2E_REPORT_DIR"
rm -rf "$E2E_REPORT_DIR/screenshots"
printf '%s\n' "$JOBS" | sed -e 's/\.yaml@/__/' > "$E2E_REPORT_DIR/plan.txt"
# The run's environment, backend and links, for the report header and its per-row links.
python3 -I "$ENV_PY" resolve --write "$E2E_REPORT_DIR/targets.json" >/dev/null 2>&1 || exit 1
echo "-- environment: $E2E_ENV_NAME · backend: $BACKEND_URL$([ "$SET_SDK_BASE" = 1 ] && echo ' (LINKTRAIL_BASE)')"
: > "$RESULTS"

# ---- build every mode those flows need, once, before anything runs -----------------------------
for m in $(for f in $JOBS; do mode_of "${f%@*}"; done | sort -u); do stage_mode "$m"; done
if [ "${E2E_BUILD_ONLY:-0}" = "1" ]; then
  echo "OK: built every mode against the published SDK $SDK_VERSION (E2E_BUILD_ONLY=1: no flows run)"
  exit 0
fi

# ---- run ---------------------------------------------------------------------------------------
# Probabilistic flows (LINKTRAIL_TOKEN_SOURCE: none) are matched by IP, so another simulator's click
# or install from the same machine could be matched to them: they run SERIALLY, one at a time on one
# device, after every other flow has finished (also with PARALLEL>1).
PROB_JOBS=""; TOKEN_JOBS=""
for f in $JOBS; do
  if [ "$(mode_of "${f%@*}")" = none ]; then PROB_JOBS="$PROB_JOBS $f"; else TOKEN_JOBS="$TOKEN_JOBS $f"; fi
done
if [ "$PARALLEL" -le 1 ]; then
  DEVICE="${DEVICE:-$(xcrun simctl list devices booted | grep -oiE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' | head -1)}"
  [ -n "$DEVICE" ] || { echo "ERROR: no booted simulator. Run 'open -a Simulator', boot one, then retry."; exit 1; }
  echo "-- device: $DEVICE"
  # Keep going after a failed flow (as PARALLEL>1 always has), so the report has a row for every flow;
  # the run still fails at the end.
  FAIL=0
  for f in $TOKEN_JOBS $PROB_JOBS; do run_flow "$DEVICE" "$f" || FAIL=1; done
  [ "$FAIL" -eq 0 ] || { echo; echo "ERROR: one or more flows failed — see the e2e report ($E2E_REPORT_DIR)"; exit 1; }
  echo "OK: all $FLOW_COUNT flow(s) passed"
else
  [ "$PARALLEL" -le "$FLOW_COUNT" ] || PARALLEL="$FLOW_COUNT"
  DEVICE_LIST="$(pick_devices "$PARALLEL")"
  NDEV="$(printf '%s\n' "$DEVICE_LIST" | grep -c .)"
  [ "$NDEV" -ge 1 ] || { echo "ERROR: no simulators available"; exit 1; }
  echo "-- running $FLOW_COUNT flow(s) across $NDEV device(s):"; printf '     %s\n' $DEVICE_LIST

  WORK="$(mktemp -d -t e2epar)"
  for k in $(seq 0 $((NDEV - 1))); do : > "$WORK/queue.$k"; done
  i=0
  for f in $TOKEN_JOBS; do                          # round-robin — any flow runs on any device
    echo "$f" >> "$WORK/queue.$(( i % NDEV ))"; i=$((i + 1))
  done

  pids=""; slot=0
  for dev in $DEVICE_LIST; do
    ( set +e; rc=0
      while read -r f; do run_flow "$dev" "$f" || rc=1; done < "$WORK/queue.$slot"
      exit $rc
    ) > "$WORK/log.$slot" 2>&1 &
    pids="$pids $!"; slot=$((slot + 1))
  done

  FAIL=0
  for p in $pids; do wait "$p" || FAIL=1; done
  # Then the probabilistic flows, serially, on the first device (nothing else is running now).
  if [ -n "${PROB_JOBS// /}" ]; then
    first="$(printf '%s\n' "$DEVICE_LIST" | head -1)"
    ( set +e; rc=0
      for f in $PROB_JOBS; do run_flow "$first" "$f" || rc=1; done
      exit $rc
    ) > "$WORK/log.serial" 2>&1 || FAIL=1
  fi
  for l in "$WORK"/log.*; do echo; echo "########## device $(basename "$l" | cut -d. -f2) ##########"; cat "$l"; done
  echo; echo "########## summary ##########"
  grep -h -E "^(OK|SKIPPED|ERROR|VERIFY [A-Z]+): " "$WORK"/log.* | sort || true
  rm -rf "$WORK"
  [ "$FAIL" -eq 0 ] || { echo "ERROR: one or more flows failed"; exit 1; }
  echo "OK: all $FLOW_COUNT flow(s) passed across $NDEV device(s)"
fi
