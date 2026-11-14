# shellcheck shell=bash
#
# Backend "install recorded" check (the e2e verify endpoint), sourced by
# e2e/scripts/e2e-maestro.sh.
# Expects ROOT, APP_ID and BACKEND_URL (the chosen environment's backend, resolved from
# scripts/e2e-env.json by scripts/e2e-env.py) from the caller.
#
# The UI asserts prove where the user LANDED; this proves what the backend RECORDED for the flow's
# own click: GET /v1/e2e/clicks/<lt_click token> with X-E2E-Token. It checks that one token, never a
# global count, so parallel runs and real traffic can't skew it. Needs E2E_TOKEN (CI secret). Without
# it the check is skipped with a warning; E2E_VERIFY_REQUIRED=1 (set in CI) turns that into a failure.
# No default: the check must hit the run's own backend, so a dev run never asks prod (or the reverse).
VERIFY_BASE="${BACKEND_URL:-}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-15}"

# split_flow <flow.yaml> <out-dir>: Maestro has no shell hook, so the runner drives each flow in two
# halves: Safari (the interstitial stages lt_click=<token> on the clipboard), then the app. Between
# them it reads the token off the simulator pasteboard; the SDK clears the pasteboard once it has
# consumed the token, so after the flow it is gone. Both halves keep the flow's header (appId + env).
# A re-engagement flow (reengage_*.yaml) or a reward-events flow (reward_*.yaml) has a third part,
# after.yaml: from the first step after the app launch that leaves the app (`- pressKey: Home` or
# `- openLink:`) to the end. The runner runs it after the backend has confirmed the first install
# (see verify_reengage / verify_events); it must open a URL (`- openLink:`): the link again, or the
# app's e2e-track hook.
split_flow() {
  local src="$ROOT/scripts/$1" out="$2"
  rm -f "$out/after.yaml"
  awk -v a="$out/safari.yaml" -v b="$out/app.yaml" -v c="$out/after.yaml" '
    !body { print > a; print > b; hdr = hdr $0 "\n"; if ($0 == "---") body = 1; next }
    /^- launchApp: \{ *appId: *io\.linktrail\.kickflipdemo/ { app = 1 }
    app && !re && /^- (pressKey: Home|openLink:)/ { re = 1; printf "%s", hdr > c }
    { if (re) print > c; else if (app) print > b; else print > a }
  ' "$src"
  grep -q '^- launchApp: { *appId: *io.linktrail.kickflipdemo' "$out/app.yaml" \
    || { echo "ERROR: $1 has no '- launchApp: { appId: $APP_ID ... }' step to split on" >&2; return 1; }
  case "$1" in
    reengage_*|reward_*) grep -q '^- openLink:' "$out/after.yaml" 2>/dev/null \
      || { echo "ERROR: $1 is a re-engagement / reward flow but has no '- openLink:' step after the app launch" >&2; return 1; } ;;
    *) [ ! -f "$out/after.yaml" ] \
      || { echo "ERROR: $1 leaves the app after launching it, but only reengage_*.yaml / reward_*.yaml flows have a third part" >&2; return 1; } ;;
  esac
}

# add_product_assert <app.yaml> <product regex>: with an expected product (the expect_product input),
# the click-token allow flows (the ones that assert ${EXPECT_VOUCHER_TEXT}) must also show its name.
# Appended by the runner because Maestro has no "assert only if set"; the name is written as a JSON
# string, which is valid YAML, so quotes and colons in it cannot break the flow.
add_product_assert() {
  local app="$1" product="$2"
  [ -n "$product" ] || return 0
  grep -q 'EXPECT_VOUCHER_TEXT}' "$app" || return 0
  python3 -I -c 'import json, sys; print("- extendedWaitUntil: { visible: { text: %s }, timeout: 10000, optional: false }" % json.dumps(sys.argv[1]))' "$product" >> "$app"
}

# add_meta_assert <app.yaml> <link type> <source regex>: for a link-type matrix run, the allow flows
# (the ones that assert ${EXPECT_VOUCHER_TEXT}) must also show the delivering link's customData in
# the example app's debug-only meta row: meta-linkType == the type, meta-source == the source.
add_meta_assert() {
  local app="$1" ltype="$2" source="$3"
  grep -q 'EXPECT_VOUCHER_TEXT}' "$app" || return 0
  python3 -I -c '
import json, sys
print("- extendedWaitUntil: { visible: { id: \"meta-linkType\", text: %s }, timeout: 10000, optional: false }" % json.dumps(sys.argv[1]))
if sys.argv[2]:
    print("- assertVisible: { id: \"meta-source\", text: %s }" % json.dumps(sys.argv[2]))
' "$ltype" "$source" >> "$app"
}

# prepare_flow <flow.yaml> <out-dir> <product regex> [<link type> <source regex>]: split the flow into
# its halves and append the extra allow-flow asserts (expected product; for a link-type run, the meta
# row) to each app part that shows the voucher: app.yaml, and after.yaml for a re-engagement flow.
prepare_flow() {
  local part
  split_flow "$1" "$2" || return 1
  for part in "$2/app.yaml" "$2/after.yaml"; do
    [ -f "$part" ] || continue
    add_product_assert "$part" "$3" || return 1
    [ -z "${4:-}" ] || add_meta_assert "$part" "$4" "${5:-}" || return 1
  done
}

# capture_token <device>: the 32-hex lt_click token the interstitial staged, or nothing.
capture_token() {
  { xcrun simctl pbpaste "$1" 2>/dev/null || true; } | grep -oE 'lt_click=[0-9a-fA-F]{32}' | head -1 | cut -d= -f2 || true
}

# expect_for <flow.yaml>: "allow click_token" | "allow probabilistic" | "deny". A re-engagement or
# reward flow (reengage_*, reward_*) starts with a click-token deferred install, so it maps like one.
expect_for() {
  case "$1" in
    *_deny_*)     echo "deny" ;;
    *problistic*) echo "allow probabilistic" ;;
    *)            echo "allow click_token" ;;
  esac
}

# judge <response.json> <expectation> [<link type>] [<baseline>]: prints "PASS <fields>", "WAIT
# <fields>" (not there yet: keep polling) or "FAIL <reason>" (can never pass: stop now).
#   <link type>: a link-type matrix run also checks the link's reward and this click's earning
#     (the e2e verify endpoint, "SDK e2e use"). The reward MODEL each type's link must have
#     is in scripts/e2e-env.json link_type_rewards (null = no reward); the AMOUNT is never hardcoded,
#     it is read from the response's own `reward`:
#       per_install allow: earning.counted == true and earning.amountMinor == reward.amountMinor;
#       no reward (general, campaign): reward == null and earning.amountMinor == 0;
#       per_event allow, after the events (REWARD_STAGE=events): earning.amountMinor == 2 × reward.amountMinor;
#       rev_share allow, after the events: earning.amountMinor == floor(revenue_minor × reward.rateBps / 10000)
#         (revenue_minor: reward_events in scripts/e2e-env.json);
#       per_event / rev_share right after the install (REWARD_STAGE unset): the reward's terms, and
#         earning.amountMinor == 0 (no event yet). earning.counted is not checked here: it says the
#         install counts (true on allow, the e2e verify endpoint), not that anything was
#         earned, so counted true with 0 is the expected baseline (as the Android SDK's e2e-verify.py);
#       any deny, and no reward: earning.counted == false (missing or null fails), amountMinor == 0.
#     A response with no `earning` field FAILS at once: the backend predates the field.
#     linkType: the response's linkType must be the link's REAL type, scripts/e2e-env.json
#       link_type_kinds (event and revshare are pseudo-types: their links are influencer and partner).
#     Events (REWARD_STAGE=events, backend_checks.events; the e2e verify endpoint "Events and
#       revenue on the click"): per_event allow: events.byName[reward.eventName] == 2,
#       byName[other_event] == 1, count == 3; rev_share allow: revenue has revenue_minor in the reward's
#       currency AND in the other currency (recorded, though it earns nothing), count == 2; no reward
#       (general) allow: byName[revenue_event] == 2, byName[other_event] == 1, count == 3; any deny:
#       count == 0. revenue must be exactly what was sent (rev_share: those two currencies only;
#       everything else: []). A missing `events` object, or one whose count is not an integer,
#       byName not an object or revenue not a list, FAILS at once. With E2E_CHECK_EVENTS=0 it is skipped.
#   Fraud, on every counted allow install (installRecorded true), when the earning check is on
#     (E2E_CHECK_EARNING, default on): earning.excludedAsFraud == false and fraudReasons == []; a
#     flagged install FAILS at once, naming the reasons. Off: skipped.
#   Each of those checks adds "check:<link_type|events|fraud>=<pass|fail|skip>" to the line, which the
#   e2e report shows as its own row (scripts/e2e-report.py checks_from).
#   <baseline> "open=<n> install=<m> [earning_counted=… earning_amount=… earning_currency=…]": the
#     state right after the first install, for the re-engagement check: allow needs openCount == n+1,
#     deny openCount == n; installCount must stay m, and the earning (counted, amountMinor, currency)
#     must be exactly the same, so the open paid no second reward.
judge() {
  E2E_ENV_CONFIG="${E2E_ENV_CONFIG:-$ROOT/scripts/e2e-env.json}" \
  E2E_CHECK_EARNING="${E2E_CHECK_EARNING:-1}" E2E_CHECK_EVENTS="${E2E_CHECK_EVENTS:-1}" python3 -I -c '
import json, os, sys
d = json.load(open(sys.argv[1])); exp = sys.argv[2].split()
ltype = sys.argv[3] if len(sys.argv) > 3 else ""
base = dict(kv.split("=", 1) for kv in (sys.argv[4].split() if len(sys.argv) > 4 else []))
if not isinstance(d, dict):
    raise ValueError("not an object")
deny = exp[0] == "deny"
got = "installRecorded=%s attributed=%s matchType=%s installCount=%s" % (
    d.get("installRecorded"), d.get("attributed"), d.get("matchType"), d.get("installCount"))
if deny:
    ok = d.get("installRecorded") is False and d.get("installCount") == 0
else:
    ok = (d.get("installRecorded") is True and d.get("attributed") is True
          and d.get("installCount") == 1 and d.get("matchType") == exp[1])
def fail(msg, check=""):
    print("FAIL %s. Got %s%s" % (msg, got, (" check:%s=fail" % check) if check else "")); sys.exit(0)
def positive(v):
    return isinstance(v, int) and not isinstance(v, bool) and v > 0
if base:
    want_open = int(base["open"]) + (0 if deny else 1)
    got += " openCount=%s (was %s)" % (d.get("openCount"), base["open"])
    ok = ok and d.get("openCount") == want_open and d.get("installCount") == int(base["install"])
    if "earning_counted" in base:
        # No second reward: the earning after the open is exactly the one after the install.
        e = d.get("earning") if isinstance(d.get("earning"), dict) else {}
        now = (str(e.get("counted")), str(e.get("amountMinor")), str(e.get("currency")))
        was = (base["earning_counted"], base["earning_amount"], base["earning_currency"])
        got += " earning=%s,%s,%s (was %s,%s,%s)" % (now + was)
        ok = ok and now == was
if ltype:
    rewards = json.load(open(os.environ["E2E_ENV_CONFIG"])).get("link_type_rewards") or {}
    if ltype not in rewards:
        fail("no reward model for link type %r in scripts/e2e-env.json link_type_rewards" % ltype)
    model = rewards[ltype]
    reward = d.get("reward"); earning = d.get("earning")
    if isinstance(reward, dict):
        rtext = "%s:%s%s" % (reward.get("model"), reward.get("amountMinor"), (" " + reward["currency"]) if reward.get("currency") else "")
    else:
        rtext = json.dumps(reward)
    got += " linkType=%s reward=%s" % (d.get("linkType"), rtext)
    if "earning" not in d:
        fail("backend has no earning field (GET /v1/e2e/clicks/:token must return linkType, reward and earning: "
             "the e2e verify endpoint); deploy the backend change")
    if not isinstance(earning, dict):
        fail("backend earning field is %s, not an object" % json.dumps(earning))
    counted = earning.get("counted"); amount = earning.get("amountMinor")
    got += " earning=counted:%s,amountMinor:%s%s" % (counted, amount, (" " + earning["currency"]) if earning.get("currency") else "")
    # Which backend rule flagged the install (ip_velocity, device_repeat, ...), when it was excluded as fraud.
    if earning.get("excludedAsFraud") is True:
        got += " excludedAsFraud:%s" % (",".join(map(str, d.get("fraudReasons") or [])) or "?")
    if model is None:
        if reward is not None:
            fail("the %s link must have no reward (reward == null), but has %s" % (ltype, rtext))
    else:
        if not isinstance(reward, dict) or reward.get("model") != model:
            fail("the %s link must have a %s reward, but has %s" % (ltype, model, rtext))
        r_amount = reward.get("amountMinor")
        if model == "per_install" and not positive(r_amount):
            fail("the %s link reward has no positive amountMinor" % ltype)
    if deny or model is None:
        # Not counted means counted == false: a missing or null counted is not an answer.
        ok = ok and counted is False and amount == 0
    elif model == "per_install":
        ok = ok and counted is True and amount == reward["amountMinor"]
    elif model in ("per_event", "rev_share"):
        stage = os.environ.get("REWARD_STAGE", "")
        if model == "per_event":
            if not positive(r_amount) or not reward.get("eventName"):
                fail("the %s link per_event reward needs a positive amountMinor and an eventName" % ltype)
            want = 2 * r_amount
        else:
            bps = reward.get("rateBps")
            if not (positive(bps) and bps <= 10000) or not reward.get("currency"):
                fail("the %s link rev_share reward needs rateBps (1-10000) and a currency" % ltype)
            revenue = (json.load(open(os.environ["E2E_ENV_CONFIG"])).get("reward_events") or {}).get("revenue_minor")
            want = revenue * bps // 10000
        if stage == "events":
            got += " want=%s" % want
            ok = ok and amount == want
        elif stage:
            fail("unknown REWARD_STAGE %r" % stage)
        else:
            # Right after the install, before any event: nothing earned yet. The install itself
            # counts (counted true is fine); only the amount says whether anything was paid.
            ok = ok and amount == 0
    else:
        fail("no earning rule for a %s reward" % model)
    cfg = json.load(open(os.environ["E2E_ENV_CONFIG"]))
    kind = (cfg.get("link_type_kinds") or {}).get(ltype)
    if not kind:
        fail("no real link type for %r in scripts/e2e-env.json link_type_kinds" % ltype, "link_type")
    if d.get("linkType") != kind:
        fail("the %s link must have linkType %s (scripts/e2e-env.json link_type_kinds), but has %s"
             % (ltype, kind, json.dumps(d.get("linkType"))), "link_type")
    got += " check:link_type=pass"
    if os.environ.get("REWARD_STAGE", "") == "events":
        if os.environ.get("E2E_CHECK_EVENTS") != "1":
            got += " check:events=skip"
        else:
            ev = d.get("events")
            if (not isinstance(ev, dict) or not isinstance(ev.get("count"), int) or isinstance(ev.get("count"), bool)
                    or not isinstance(ev.get("byName"), dict) or not isinstance(ev.get("revenue"), list)):
                fail("backend has no events object with count, byName and revenue (GET /v1/e2e/clicks/:token, "
                     "the e2e verify endpoint \"Events and revenue on the click\"); deploy the backend change "
                     "or set backend_checks.events to false", "events")
            re_ = cfg.get("reward_events") or {}
            names, revenue = {}, {}
            if deny:
                pass
            elif model == "per_event":
                names = {reward["eventName"]: 2}
                names[re_.get("other_event")] = names.get(re_.get("other_event"), 0) + 1
            elif model == "rev_share":
                names = {re_.get("revenue_event"): 2}
                cur = str(reward.get("currency")).upper()
                other = next((c.upper() for c in re_.get("other_currencies") or [] if c.upper() != cur), None)
                revenue = {cur: re_.get("revenue_minor"), other: re_.get("revenue_minor")}
            else:
                names = {re_.get("revenue_event"): 2}
                names[re_.get("other_event")] = names.get(re_.get("other_event"), 0) + 1
            want_count = sum(names.values())
            by = ev["byName"]
            got_rev = {}
            for r in ev["revenue"]:
                if isinstance(r, dict):
                    got_rev[str(r.get("currency")).upper()] = r.get("amountMinor")
            got += " events=count:%s,byName:%s,revenue:%s" % (
                ev.get("count"), ",".join("%s=%s" % kv for kv in sorted(by.items())) or "-",
                ",".join("%s=%s" % kv for kv in sorted(got_rev.items())) or "-")
            # revenue must be exactly what was sent: rev_share both currencies at revenue_minor, and
            # nothing for per_event, no reward or deny (their events carry no value).
            ev_ok = (ev.get("count") == want_count and all(by.get(n) == c for n, c in names.items())
                     and len(got_rev) == len(ev["revenue"]) and got_rev == revenue)
            if not ev_ok:
                got += " events_want=count:%s,byName:%s%s" % (want_count, ",".join("%s=%s" % kv for kv in sorted(names.items())) or "-",
                    (",revenue:" + ",".join("%s=%s" % kv for kv in sorted(revenue.items()))) if revenue else "")
            got += " check:events=%s" % ("pass" if ev_ok else "fail")
            ok = ok and ev_ok
if not deny and d.get("installRecorded") is True:
    # A counted allow install must not be fraud-flagged (the e2e verify endpoint fraudReasons).
    if os.environ.get("E2E_CHECK_EARNING") != "1":
        got += " check:fraud=skip"
    else:
        e = d.get("earning")
        reasons = d.get("fraudReasons")
        if not isinstance(e, dict) or not isinstance(e.get("excludedAsFraud"), bool) or not isinstance(reasons, list):
            fail("backend has no earning.excludedAsFraud and fraudReasons for the install (the e2e verify endpoint); "
                 "deploy the backend change", "fraud")
        if e["excludedAsFraud"] or reasons:
            fail("the install was flagged as fraud (excludedAsFraud %s, fraudReasons %s): an e2e install must be clean"
                 % (str(e["excludedAsFraud"]).lower(), ", ".join(map(str, reasons)) or "none"), "fraud")
        got += " check:fraud=pass"
print(("PASS " if ok else "WAIT ") + got)
' "$@" 2>/dev/null || echo "WAIT unparseable response"
}

# verify_install <flow.yaml> <token>: poll the verify endpoint until the expectation holds or
# VERIFY_TIMEOUT seconds pass (install processing can lag). Prints one VERIFY OK/FAIL line.
# Neither the secret nor the full click token is ever printed.
#   VERIFY_LINK_TYPE=<type>  also check the link's reward and this click's earning (see judge).
#   VERIFY_BASELINE="open=<n> install=<m>"  the re-engagement check (see judge); the line says [reengage …].
#   VERIFY_STATE=<file>  on a pass, write that response's counts there as a baseline ("open=<n> install=<m>"),
#     plus the reward's model, eventName, currency and rateBps (URL-encoded) for events_url.
#   REWARD_STAGE=events  judge a per_event / rev_share earning after the events (see judge).
verify_install() {
  local flow="$1" token="$2" name expect label deadline body code verdict="WAIT no response"
  name="${VERIFY_NAME:-$(basename "$flow" .yaml)}"; expect="$(expect_for "$flow")"
  label="$expect"; [ -z "${VERIFY_BASELINE:-}" ] || label="reengage ${expect%% *}"
  [ "${REWARD_STAGE:-}" != events ] || label="events ${expect%% *}"
  deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
  body="$(mktemp -t e2everify)"
  while :; do
    # The secret goes to curl through a stdin config, so it never appears in argv or `ps`.
    code="$(printf 'header = "X-E2E-Token: %s"\n' "$E2E_TOKEN" \
      | curl -sS -o "$body" -w '%{http_code}' --max-time 10 --config - "$VERIFY_BASE/v1/e2e/clicks/$token" 2>/dev/null || true)"
    case "$code" in
      404)
        rm -f "$body"
        echo "VERIFY FAIL: $name — e2e verify endpoint refused the request (404 from $VERIFY_BASE: the endpoint is off on this backend, the E2E_TOKEN secret is wrong, or the click is not from the e2e app)"
        return 1 ;;
      200)
        verdict="$(judge "$body" "$expect" "${VERIFY_LINK_TYPE:-}" ${VERIFY_BASELINE:+"$VERIFY_BASELINE"})"
        case "$verdict" in
          PASS*)
            [ -z "${VERIFY_STATE:-}" ] || python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
from urllib.parse import quote
r = d.get("reward") if isinstance(d.get("reward"), dict) else {}
extra = "".join(" %s=%s" % (k, quote(str(r[k]), safe="")) for k in ("model", "eventName", "currency", "rateBps") if r.get(k) not in (None, ""))
e = d.get("earning")
if isinstance(e, dict):
    extra = " earning_counted=%s earning_amount=%s earning_currency=%s" % (e.get("counted"), e.get("amountMinor"), e.get("currency")) + extra
print("open=%d install=%d%s" % (int(d.get("openCount") or 0), int(d.get("installCount") or 0), extra))' "$body" > "$VERIFY_STATE" 2>/dev/null \
              || { rm -f "$body"; echo "VERIFY FAIL: $name [$label] click ${token:0:8}… — could not read openCount/installCount for the re-engagement baseline"; return 1; }
            rm -f "$body"; echo "VERIFY OK: $name [$label] click ${token:0:8}… ${verdict#PASS }"; return 0 ;;
          FAIL*)
            rm -f "$body"; echo "VERIFY FAIL: $name [$label] click ${token:0:8}… — ${verdict#FAIL }"; return 1 ;;
        esac ;;
      *) verdict="WAIT HTTP ${code:-000}" ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      rm -f "$body"
      echo "VERIFY FAIL: $name [$label] click ${token:0:8}… after ${VERIFY_TIMEOUT}s — got ${verdict#WAIT }"
      return 1
    fi
    sleep 2
  done
}

# verify_flow <flow.yaml> <token>: the per-flow check, including the no-token / no-secret cases.
verify_flow() {
  local flow="$1" token="$2" name
  name="${VERIFY_NAME:-$(basename "$flow" .yaml)}"
  if [ -z "${E2E_TOKEN:-}" ]; then
    if [ "${E2E_VERIFY_REQUIRED:-0}" = "1" ]; then
      echo "VERIFY FAIL: $name — E2E_TOKEN is not set (required: E2E_VERIFY_REQUIRED=1)"; return 1
    fi
    echo "VERIFY SKIP: $name — not checked: E2E_TOKEN not set"; return 0
  fi
  if [ -z "$token" ]; then
    case "$flow" in
      *problistic*)
        # Probabilistic flows never reach the interstitial's Continue button, so no lt_click token
        # lands on the device: they are checked by SDK device id instead (verify_device).
        echo "VERIFY FAIL: $name — a probabilistic flow is checked by device id (verify_device), not by click token"
        return 1 ;;
      *) echo "VERIFY FAIL: $name — no lt_click token on the clipboard after the Safari step"; return 1 ;;
    esac
  fi
  if [ -z "$VERIFY_BASE" ]; then
    echo "VERIFY FAIL: $name — no backend URL for this environment (BACKEND_URL is empty; see scripts/e2e-env.json)"; return 1
  fi
  if [ -n "${VERIFY_LINK_TYPE:-}" ] && ! check_enabled earning; then
    # The install is still checked; only the reward/earning part waits for this backend.
    local out
    out="$(VERIFY_LINK_TYPE="" verify_install "$flow" "$token")" || { echo "$out"; return 1; }
    echo "$out; $(not_deployed "$name" "reward/earning check" earning)"; return 0
  fi
  verify_install "$flow" "$token"
}

# check_enabled <earning|device_lookup|reengagement_open_count|events>: is this newer verify-endpoint
# check deployed on the run's backend (backend_checks in scripts/e2e-env.json, exported by e2e-env.py
# as E2E_CHECK_EARNING / E2E_CHECK_DEVICE_LOOKUP / E2E_CHECK_OPEN_COUNT / E2E_CHECK_EVENTS)? Unset means required: a
# missing deploy on an environment that claims the check fails rather than skips.
check_enabled() {
  local v
  case "$1" in
    earning) v="${E2E_CHECK_EARNING:-1}" ;;
    device_lookup) v="${E2E_CHECK_DEVICE_LOOKUP:-1}" ;;
    reengagement_open_count) v="${E2E_CHECK_OPEN_COUNT:-1}" ;;
    events) v="${E2E_CHECK_EVENTS:-1}" ;;
    *) return 0 ;;
  esac
  [ "$v" = 1 ]
}

# not_deployed <name> <what> <flag>: the SKIP line for a check this environment's backend lacks.
not_deployed() {
  echo "VERIFY SKIP: $1 — $2 not on ${E2E_ENV_NAME:-this} backend yet (backend_checks.$3 is false in scripts/e2e-env.json)"
}

# row_status <flow.yaml> <link type> <verify detail>: "skipped" or "pass" for a row whose UI passed
# and whose backend checks did not fail. A link-type (reward), re-engagement, reward-events or
# probabilistic row whose backend check was skipped (no E2E_TOKEN, or not on this backend yet) is
# "skipped": its point is that check, so it never counts as a pass. Other rows pass as before.
row_status() {
  case "$3" in *"VERIFY SKIP"*) ;; *) echo pass; return 0 ;; esac
  if [ -n "$2" ]; then echo skipped; return 0; fi
  case "$(basename "$1")" in reengage_*|reward_*|*problistic*) echo skipped ;; *) echo pass ;; esac
}


# verify_reengage <flow.yaml> <token> <baseline>: after a re-engagement flow's openLink part, the
# same click must show exactly one more open (allow) or none (deny), and the same install count as
# right after the first install, so the open paid no second reward. <baseline> comes from the first
# check's VERIFY_STATE file. Without E2E_TOKEN it is skipped exactly like verify_flow.
verify_reengage() {
  local flow="$1" token="$2" baseline="$3" name
  name="${VERIFY_NAME:-$(basename "$flow" .yaml)}"
  if [ -z "${E2E_TOKEN:-}" ]; then
    if [ "${E2E_VERIFY_REQUIRED:-0}" = "1" ]; then
      echo "VERIFY FAIL: $name — E2E_TOKEN is not set (required: E2E_VERIFY_REQUIRED=1)"; return 1
    fi
    echo "VERIFY SKIP: $name — re-engagement not checked: E2E_TOKEN not set"; return 0
  fi
  if ! check_enabled reengagement_open_count; then not_deployed "$name" "re-engagement openCount check" reengagement_open_count; return 0; fi
  case "$baseline" in
    open=[0-9]*\ install=[0-9]*) ;;
    *) echo "VERIFY FAIL: $name — no openCount/installCount baseline from the first install check"; return 1 ;;
  esac
  [ -n "$token" ] || { echo "VERIFY FAIL: $name — no lt_click token on the clipboard after the Safari step"; return 1; }
  [ -n "$VERIFY_BASE" ] || { echo "VERIFY FAIL: $name — no backend URL for this environment (BACKEND_URL is empty; see scripts/e2e-env.json)"; return 1; }
  VERIFY_BASELINE="$baseline" VERIFY_STATE="" verify_install "$flow" "$token"
}

# events_url <state> [<config>]: the kickflip://e2e-track URL a reward flow opens after its counted
# install, from the first check's VERIFY_STATE (the reward's model, eventName, currency) and
# reward_events in scripts/e2e-env.json:
#   per_event: event=<reward.eventName> twice, then event=<other_event> once (the other adds nothing);
#   rev_share: one event=<revenue_event> worth revenue_minor in the reward's currency, then the same
#     revenue in another currency (reward_events.other_currencies, the first that differs), each sent
#     as a major-unit value (ISO 4217 minor digits), the unit LinkTrail.trackEvent takes. Only the
#     reward-currency one may count: a revenue event in another currency adds nothing.
#   no reward (a general link on the reward flows; the state has no model): event=<revenue_event>
#     twice, then event=<other_event> once, with no value: counted as the click's events, earning 0.
# Each event=<name> starts a new event; the value= and currency= after it belong to it.
# Prints the URL, or one ERROR line and fails.
events_url() {
  python3 -I - "$1" "${2:-$ROOT/scripts/e2e-env.json}" <<'PYEV'
import json, sys
from decimal import Decimal
from urllib.parse import quote, unquote
state = dict(kv.split("=", 1) for kv in sys.argv[1].split() if "=" in kv)
state = {k: unquote(v) for k, v in state.items()}
cfg = json.load(open(sys.argv[2])).get("reward_events") or {}
model = state.get("model")
q = lambda v: quote(v, safe="")
if model == "per_event":
    name, other = state.get("eventName"), cfg.get("other_event")
    if not name:
        sys.exit(print("ERROR: the per_event reward has no eventName") or 1)
    if not other or other == name:
        sys.exit(print("ERROR: reward_events.other_event must be set and differ from the reward's eventName (%s)" % name) or 1)
    print("kickflip://e2e-track?event=%s&event=%s&event=%s" % (q(name), q(name), q(other)))
elif model == "rev_share":
    cur, minor, name = state.get("currency"), cfg.get("revenue_minor"), cfg.get("revenue_event")
    if not cur:
        sys.exit(print("ERROR: the rev_share reward has no currency (the workspace currency)") or 1)
    if not isinstance(minor, int) or minor <= 0 or not name:
        sys.exit(print("ERROR: reward_events needs revenue_event and a positive revenue_minor") or 1)
    other = next((c for c in cfg.get("other_currencies") or [] if c.upper() != cur.upper()), None)
    if not other:
        sys.exit(print("ERROR: reward_events.other_currencies needs a currency other than %s" % cur) or 1)
    digits = {"BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0, "KRW": 0, "PYG": 0, "RWF": 0,
              "UGX": 0, "UYI": 0, "VND": 0, "VUV": 0, "XAF": 0, "XOF": 0, "XPF": 0,
              "BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3}
    major = lambda c: Decimal(minor).scaleb(-digits.get(c.upper(), 2))
    print("kickflip://e2e-track?event=%s&value=%s&currency=%s&event=%s&value=%s&currency=%s"
          % (q(name), major(cur), q(cur), q(name), major(other), q(other)))
elif not model:
    name, other = cfg.get("revenue_event"), cfg.get("other_event")
    if not name or not other or name == other:
        sys.exit(print("ERROR: reward_events needs revenue_event and a different other_event") or 1)
    print("kickflip://e2e-track?event=%s&event=%s&event=%s" % (q(name), q(name), q(other)))
else:
    sys.exit(print("ERROR: no events to send for a %s reward" % model) or 1)
PYEV
}

# events_count <events url>: how many events that URL asks for.
events_count() { printf '%s' "$1" | grep -oE '(\?|&)event=' | wc -l | tr -d ' '; }

# events_expect <events url> <allow|deny>: what the app's debug-events footer must show once the
# SDK has answered every event (example/KickFlipDemo/App/E2EDebug.swift). Allow: every event sent
# (acknowledged with an id) and attributed. Deny: none sent and none attributed (the SDK drops
# them); a leaking SDK would show a non-zero count and fail the flow.
events_expect() {
  local n; n="$(events_count "$1")"
  if [ "$2" = deny ]; then echo "E2E events: requested $n · sent 0 · attributed 0"
  else echo "E2E events: requested $n · sent $n · attributed $n"; fi
}

# verify_events <flow.yaml> <token>: after a reward flow's events, poll until the earning matches
# the reward's formula (allow) or stays 0 (deny). Without E2E_TOKEN it is skipped like verify_flow.
verify_events() {
  local flow="$1" token="$2" name
  name="${VERIFY_NAME:-$(basename "$flow" .yaml)}"
  if [ -z "${E2E_TOKEN:-}" ]; then
    if [ "${E2E_VERIFY_REQUIRED:-0}" = "1" ]; then
      echo "VERIFY FAIL: $name — E2E_TOKEN is not set (required: E2E_VERIFY_REQUIRED=1)"; return 1
    fi
    echo "VERIFY SKIP: $name — earning not checked: E2E_TOKEN not set"; return 0
  fi
  if ! check_enabled earning; then not_deployed "$name" "reward/earning check" earning; return 0; fi
  [ -n "$token" ] || { echo "VERIFY FAIL: $name — no lt_click token on the clipboard after the Safari step"; return 1; }
  [ -n "${VERIFY_LINK_TYPE:-}" ] || { echo "VERIFY FAIL: $name — a reward-events check needs its link type"; return 1; }
  [ -n "$VERIFY_BASE" ] || { echo "VERIFY FAIL: $name — no backend URL for this environment (BACKEND_URL is empty; see scripts/e2e-env.json)"; return 1; }
  REWARD_STAGE=events VERIFY_STATE="" VERIFY_BASELINE="" verify_install "$flow" "$token"
}

# judge_device <response.json> <allow|deny> <link slug>: PASS/WAIT/FAIL for the device lookup
# (the e2e verify endpoint, "Device lookup"): allow needs installCount 1 and its install
# attributed, matchType probabilistic, linkSlug == the flow's link, and its earning present as
# {counted:false, amountMinor:0} (the probabilistic links carry no reward); a missing earning fails
# at once. Deny needs installCount 0.
judge_device() {
  E2E_CHECK_EARNING="${E2E_CHECK_EARNING:-1}" python3 -I -c '
import json, os, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]; slug = sys.argv[3]
if not isinstance(d, dict):
    raise ValueError("not an object")
inst = d.get("installs") if isinstance(d.get("installs"), list) else []
first = inst[0] if inst and isinstance(inst[0], dict) else {}
got = "installCount=%s attributed=%s matchType=%s linkSlug=%s" % (d.get("installCount"), first.get("attributed"), first.get("matchType"), first.get("linkSlug"))
if want == "deny":
    ok = d.get("installCount") == 0
else:
    ok = (d.get("installCount") == 1 and first.get("attributed") is True
          and first.get("matchType") == "probabilistic" and first.get("linkSlug") == slug)
    if first:
        e = first.get("earning")
        if not isinstance(e, dict):
            print("FAIL backend has no installs[0].earning object (contract Device lookup). Got " + got); sys.exit(0)
        got += " earning=counted:%s,amountMinor:%s" % (e.get("counted"), e.get("amountMinor"))
        if e.get("excludedAsFraud") is True:
            got += " excludedAsFraud:%s" % (",".join(map(str, first.get("fraudReasons") or [])) or "?")
        ok = ok and e.get("counted") is False and e.get("amountMinor") == 0
        if want == "allow" and d.get("installCount") == 1 and os.environ.get("E2E_CHECK_EARNING") != "1":
            got += " check:fraud=skip"   # follows backend_checks.earning, as on the click check
        elif want == "allow" and d.get("installCount") == 1:
            # The counted install must not be fraud-flagged (excludedAsFraud false, fraudReasons []).
            reasons = first.get("fraudReasons")
            if not isinstance(e.get("excludedAsFraud"), bool) or not isinstance(reasons, list):
                print("FAIL backend has no installs[0].earning.excludedAsFraud and installs[0].fraudReasons (contract Device lookup). Got " + got + " check:fraud=fail"); sys.exit(0)
            if e["excludedAsFraud"] or reasons:
                print("FAIL the install was flagged as fraud (excludedAsFraud %s, fraudReasons %s): an e2e install must be clean. Got %s check:fraud=fail"
                      % (str(e["excludedAsFraud"]).lower(), ", ".join(map(str, reasons)) or "none", got)); sys.exit(0)
            got += " check:fraud=pass"
print(("PASS " if ok else "WAIT ") + got)
' "$@" 2>/dev/null || echo "WAIT unparseable response"
}

# verify_device <flow.yaml> <device id> <link url>: a probabilistic flow has no click token, so it is
# checked by the SDK device id the example app shows on its debug label (and writes to its
# container): poll GET /v1/e2e/devices/<id> until judge_device passes or VERIFY_TIMEOUT runs out.
verify_device() {
  local flow="$1" device_id="$2" link="$3" name want slug deadline body code verdict="WAIT no response"
  name="${VERIFY_NAME:-$(basename "$flow" .yaml)}"
  case "$flow" in *_deny_*) want=deny ;; *) want=allow ;; esac
  if [ -z "${E2E_TOKEN:-}" ]; then
    if [ "${E2E_VERIFY_REQUIRED:-0}" = "1" ]; then
      echo "VERIFY FAIL: $name — E2E_TOKEN is not set (required: E2E_VERIFY_REQUIRED=1)"; return 1
    fi
    echo "VERIFY SKIP: $name — device lookup not checked: E2E_TOKEN not set"; return 0
  fi
  if ! check_enabled device_lookup; then not_deployed "$name" "device lookup" device_lookup; return 0; fi
  [ -n "$VERIFY_BASE" ] || { echo "VERIFY FAIL: $name — no backend URL for this environment (BACKEND_URL is empty; see scripts/e2e-env.json)"; return 1; }
  [[ "$device_id" =~ ^[0-9A-Fa-f-]{36}$ ]] \
    || { echo "VERIFY FAIL: $name — no SDK device id from the app's debug label (e2e-device-id)"; return 1; }
  slug="${link##*/}"
  deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
  body="$(mktemp -t e2everify)"
  while :; do
    code="$(printf 'header = "X-E2E-Token: %s"\n' "$E2E_TOKEN" \
      | curl -sS -o "$body" -w '%{http_code}' --max-time 10 --config - "$VERIFY_BASE/v1/e2e/devices/$device_id" 2>/dev/null || true)"
    case "$code" in
      404)
        rm -f "$body"
        echo "VERIFY FAIL: $name — e2e device lookup refused the request (404 from $VERIFY_BASE: the lookup is off on this backend or the E2E_TOKEN secret is wrong)"
        return 1 ;;
      200)
        verdict="$(judge_device "$body" "$want" "$slug")"
        case "$verdict" in
          PASS*) rm -f "$body"; echo "VERIFY OK: $name [device $want] device ${device_id:0:8}… ${verdict#PASS }"; return 0 ;;
          FAIL*) rm -f "$body"; echo "VERIFY FAIL: $name [device $want] device ${device_id:0:8}… — ${verdict#FAIL }"; return 1 ;;
        esac ;;
      *) verdict="WAIT HTTP ${code:-000}" ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      rm -f "$body"
      echo "VERIFY FAIL: $name [device $want] device ${device_id:0:8}… after ${VERIFY_TIMEOUT}s — got ${verdict#WAIT }"
      return 1
    fi
    sleep 2
  done
}

# link_missing <url>: true when the link's own host answers 404 for it (the link is not created).
# Used only after a Safari half fails, so a healthy run makes no extra click.
link_missing() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -A 'linktrail-e2e-probe' "$1" 2>/dev/null || true)" = "404" ]
}

# denied_install_line: the SDK's log line for a consent:false install. denied_install_sent <app log>: the app's [LinkTrail] lines show that install went out.
denied_install_line() { printf '%s' 'Sending install event… (consent: false)'; }
denied_install_sent() { [ -f "$1" ] && grep -F '[LinkTrail]' "$1" | grep -qF "$(denied_install_line)"; }
