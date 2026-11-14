#!/usr/bin/env python3
"""E2E results report for the Maestro flows (stdlib only, Python 3.9+).

    e2e-report.py list-flows [--flows F]          flow files in run order (one per line)
    e2e-report.py record --results F --flow N ...  append one attempt as a JSON line
    e2e-report.py render --dir D [--env E ...]     results.jsonl -> report.md / .json / .html

scripts/e2e-maestro.sh calls `record` after every flow attempt; the e2e workflow calls `render`
(always, even when flows fail) and publishes report.md to the run summary and the PR comment.
The flow metadata (link, match, consent, expected) lives in ONE place: scripts/e2e-flows.json.
The run's environment, backend and tested links come from targets.json in the report dir, written
by scripts/e2e-env.py (the hosts and slugs themselves live in scripts/e2e-env.json).

Nothing secret reaches a report: API keys and the e2e token are removed, and click tokens are cut
to their first 4 characters plus an ellipsis, both when an attempt is recorded and when it is
rendered.
"""
import argparse
import html
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FLOWS = os.path.join(HERE, "e2e-flows.json")
MARKER = "<!-- linktrail-e2e-report -->"
LOG_TAIL = 30
ELLIPSIS = "\u2026"
SECRET_ENV = ("LINKTRAIL_KEY", "LINKTRAIL_TEST_KEY", "E2E_TOKEN", "LINKTRAIL_API_KEY")

# ---- redaction ---------------------------------------------------------------------------------

_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_API_KEY = re.compile(r"\blt_(?:live|test)_[A-Za-z0-9_\-]+")
_HEADER = re.compile(r"(?i)\b(x-e2e-token|x-api-key|authorization)(\s*[:=]\s*)\S+")
# A click token is 32 hex chars; also catch the runner's own 8-char "abcd1234…" prefixes.
_HEX_TOKEN = re.compile(r"\b([0-9a-fA-F]{4})[0-9a-fA-F]{28,}\b")
_HEX_PREFIX = re.compile(r"\b([0-9a-fA-F]{4})[0-9a-fA-F]{4,}" + ELLIPSIS)
_CLICK_PARAM = re.compile(r"(lt_click=)([A-Za-z0-9_\-]{4})[A-Za-z0-9_\-]+")


def redact(text):
    if text is None:
        return None
    s = _ANSI.sub("", str(text))
    s = _HEADER.sub(lambda m: m.group(1) + m.group(2) + "[redacted]", s)
    s = _API_KEY.sub("[redacted API key]", s)
    for name in SECRET_ENV:
        value = os.environ.get(name, "")
        if len(value) >= 6:
            s = s.replace(value, "[redacted]")
    s = _CLICK_PARAM.sub(lambda m: m.group(1) + m.group(2) + ELLIPSIS, s)
    s = _HEX_TOKEN.sub(lambda m: m.group(1) + ELLIPSIS, s)
    s = _HEX_PREFIX.sub(lambda m: m.group(1) + ELLIPSIS, s)
    return s


# ---- flow table --------------------------------------------------------------------------------

def load_flows(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    flows = data.get("flows") if isinstance(data, dict) else None
    if not isinstance(flows, list) or not flows:
        raise ValueError("%s: expected a non-empty 'flows' list" % path)
    for f in flows:
        for key in ("flow", "link", "match", "consent", "expected"):
            if not isinstance(f.get(key), str) or not f[key]:
                raise ValueError("%s: flow entry %r is missing '%s'" % (path, f.get("flow"), key))
    return flows


def cmd_list_flows(args):
    for f in load_flows(args.flows):
        print(f["flow"] + ".yaml")
    return 0


# ---- record ------------------------------------------------------------------------------------

def read_text(path):
    if not path or not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def failed_step_from_maestro(log):
    """('<step>', '<error>') from Maestro's console output: '<step>... FAILED' then the message."""
    lines = [_ANSI.sub("", l).rstrip() for l in log.splitlines()]
    for i, line in enumerate(lines):
        if line.endswith("... FAILED"):
            error = next((l.strip() for l in lines[i + 1:] if l.strip()), "")
            return line[: -len("... FAILED")].strip(), error
    for line in lines:
        if re.search(r"Transport unreachable|became unreachable|Connection refused|driver not ready in time|"
                     r"IOSDriverTimeout|App crashed or stopped", line):
            return "Maestro driver / automation session", line.strip()
    return "", ""


def linktrail_tail(app_log, n=LOG_TAIL):
    lines = [l.rstrip() for l in app_log.splitlines() if "[LinkTrail]" in l]
    return [redact(l) for l in (lines[-n:] if n else lines)]


def cmd_record(args):
    maestro = read_text(args.maestro_log)
    step, error = failed_step_from_maestro(maestro) if args.status == "fail" else ("", "")
    entry = {
        "flow": args.flow,
        "attempt": args.attempt,
        "status": args.status,
        "link": args.link or None,
        "failed_step": redact(args.failed_step or step) or None,
        "error": redact(args.error or error) or None,
        "duration_s": args.duration,
        "backend": args.backend or None,
        "backend_detail": redact(args.backend_detail) or None,
        "log_tail": linktrail_tail(read_text(args.app_log)) if args.status == "fail" else [],
        # How many [LinkTrail] lines the app printed (also on a pass, to show the capture works).
        "log_lines": len(linktrail_tail(read_text(args.app_log), n=None)),
        "screenshot": args.screenshot or None,
        "device": (args.device or "")[:8] or None,
        "finished_at": int(time.time()),
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.results)), exist_ok=True)
    with open(args.results, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return 0


# ---- aggregate ---------------------------------------------------------------------------------

def read_results(path):
    attempts = []
    if not os.path.isfile(path):
        return attempts
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("flow"):
                attempts.append(row)
    return attempts


def read_plan(path):
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [l.strip().replace(".yaml", "") for l in fh if l.strip()]


def read_targets(path):
    """The resolved run from scripts/e2e-env.py (environment, backend, links), or {}."""
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def default_expect():
    """The default expectations from scripts/e2e-env.json, for a report without targets.json."""
    try:
        with open(os.path.join(HERE, "e2e-env.json"), encoding="utf-8") as fh:
            return json.load(fh).get("expect") or {}
    except (OSError, ValueError):
        return {}


def default_link_type_expect():
    try:
        with open(os.path.join(HERE, "e2e-env.json"), encoding="utf-8") as fh:
            return json.load(fh).get("link_type_expect") or {}
    except (OSError, ValueError):
        return {}


def expected_text(template, expect):
    expect = expect or default_expect()
    return (template.replace("{product}", expect.get("product") or "product")
                    .replace("{voucher}", expect.get("voucher") or "voucher"))


# What a link-type run's backend check asserts about the reward (scripts/e2e-verify.sh judge;
# the e2e verify endpoint). The model per type is scripts/e2e-env.json link_type_rewards.
_EARNING = re.compile(r"earning=counted:(True|False|None),amountMinor:(-?\d+|None)(?: ([A-Z]{3}))?")


def default_link_type_rewards():
    try:
        with open(os.path.join(HERE, "e2e-env.json"), encoding="utf-8") as fh:
            return json.load(fh).get("link_type_rewards") or {}
    except (OSError, ValueError):
        return {}


def reward_expectation(ltype, consent, rewards=None):
    rewards = default_link_type_rewards() if rewards is None else rewards
    if ltype not in rewards:
        return "reward not configured"
    model = rewards[ltype]
    if model is None:
        return "no reward (reward null, earning 0)"
    if consent != "allow":
        return "%s reward, not earned (earning 0)" % model
    return {"per_install": "per_install reward earned (earning = reward.amountMinor)",
            "per_event": "per_event reward earned (earning = 2 × reward.amountMinor)",
            "rev_share": "rev_share reward earned (earning = floor(revenue × reward.rateBps / 10000))"}.get(model, "%s reward earned" % model)


def earning_from(detail):
    """{"counted", "amountMinor", "currency"} from the LAST earning in a VERIFY line, or None.

    A re-engagement flow's detail holds two checks (after the install, after the open); the last
    one is what the link ends up earning from this click."""
    found = _EARNING.findall(detail or "")
    if not found:
        return None
    counted, amount, currency = found[-1]
    return {
        "counted": {"True": True, "False": False}.get(counted),
        "amountMinor": None if amount == "None" else int(amount),
        "currency": currency or None,
    }


# The per-check verdicts scripts/e2e-verify.sh adds to a VERIFY line ("check:<name>=<pass|fail|skip>");
# each one is its own row under "Backend checks" in the report.
_CHECK = re.compile(r"\bcheck:([a-z_]+)=(pass|fail|skip)\b")
CHECK_LABELS = {
    "link_type": "linkType is the link's real type (scripts/e2e-env.json link_type_kinds)",
    "fraud": "install not excluded as fraud (earning.excludedAsFraud false, fraudReasons [])",
    "events": "events and revenue on the click (events.count, byName, revenue per currency)",
}
# The backend_checks flag that turns each check on (a skipped one names it).
CHECK_FLAGS = {"fraud": "earning", "events": "events"}


def checks_from(detail):
    """[{"check", "result"}] from a VERIFY line, in first-seen order; a later verdict for the same
    check (a reward flow's events check after its install check) replaces the earlier one."""
    out = {}
    for name, result in _CHECK.findall(detail or ""):
        out[name] = result
    return [{"check": n, "result": r} for n, r in out.items()]


def skip_reason(detail):
    """The reason(s) from the VERIFY SKIP part(s) of a verify line, or ''."""
    parts = [p.strip() for p in (detail or "").split("; ") if p.strip().startswith("VERIFY SKIP")]
    return "; ".join(p.split(" \u2014 ", 1)[-1] for p in parts)


def earning_text(earning):
    if not earning:
        return ""
    amount = earning.get("amountMinor")
    money = "%s%s" % (amount if amount is not None else "?", " " + earning["currency"] if earning.get("currency") else "")
    if not earning.get("counted"):
        return "not earned (%s)" % money
    # Counted means the install counts; a per_event / rev_share install earns 0 until its events
    # arrive, so "earned 0" would misread as a paid reward.
    return ("counted, nothing earned yet (%s)" % money) if amount == 0 else ("earned %s" % money)


def build_report(flow_table, attempts, plan, meta, targets=None):
    targets = targets or {}
    target_links = targets.get("flows") if isinstance(targets.get("flows"), dict) else {}
    meta_by_flow = {f["flow"]: f for f in flow_table}
    by_flow = {}
    for a in attempts:
        by_flow.setdefault(a["flow"], []).append(a)
    order = plan or [f["flow"] for f in flow_table if f["flow"] in by_flow]
    order += [f for f in by_flow if f not in order]   # recorded but neither planned nor in the table

    rows = []
    for name in order:
        # A link-type matrix run is reported as <flow>__<type>: the flow's own metadata + the type.
        base, _, ltype = name.partition("__")
        info = meta_by_flow.get(base, {}) if ltype else meta_by_flow.get(name, {})
        expected = info.get("expected", "(no entry in scripts/e2e-flows.json)")
        if ltype:
            expected = expected_text(expected, targets.get("link_type_expect") or default_link_type_expect())
            # Deny routes too (consent: deny wins), so every link-type run shows the row.
            expected += ", meta linkType=%s" % ltype
            expected += ", " + reward_expectation(ltype, info.get("consent"))
        else:
            expected = expected_text(expected, targets.get("expect"))
        tries = sorted(by_flow.get(name, []), key=lambda a: a.get("attempt") or 0)
        last = tries[-1] if tries else None
        result = "not_run" if last is None else {"pass": "pass", "skipped": "skipped"}.get(last.get("status"), "fail")
        failing = next((a for a in reversed(tries) if a.get("status") == "fail"), None)
        row = {
            "flow": name,
            "link": info.get("link", "?"),
            "link_type": ltype or None,
            # The exact URL the flow typed: from its last attempt, else what the run resolved for it.
            "url": (last or {}).get("link") or target_links.get(name) or None,
            "match": info.get("match", "?"),
            "consent": info.get("consent", "?"),
            "expected": expected,
            "result": result,
            "attempts": len(tries),
            "backend": (last or {}).get("backend"),
            "backend_detail": redact((last or {}).get("backend_detail")),
            # This click's earning as the backend reported it (link-type runs; None when not checked).
            "earning": earning_from((last or {}).get("backend_detail")),
            # The newer per-check verdicts (linkType, fraud, events), each its own report row.
            "checks": checks_from((last or {}).get("backend_detail")),
            # Why a skipped row's backend check did not run (no E2E_TOKEN, or not on this backend yet).
            "skip_reason": skip_reason((last or {}).get("backend_detail")) if result == "skipped" else None,
            "duration_s": sum(int(a.get("duration_s") or 0) for a in tries),
            "log_lines": (last or {}).get("log_lines"),
        }
        if result == "fail" and failing:
            row.update({
                "failed_step": redact(failing.get("failed_step")),
                "error": redact(failing.get("error")),
                "log_tail": [redact(l) for l in (failing.get("log_tail") or [])][-LOG_TAIL:],
                "screenshot": failing.get("screenshot"),
                "failed_attempt": failing.get("attempt"),
            })
        rows.append(row)

    passed = sum(1 for r in rows if r["result"] == "pass")
    skipped = sum(1 for r in rows if r["result"] == "skipped")
    failed = sum(1 for r in rows if r["result"] == "fail")
    not_run = sum(1 for r in rows if r["result"] == "not_run")
    if not attempts:
        status = "no_results"
    else:
        # A skipped row (its backend check could not run) is neither a pass nor a failure.
        status = "passed" if passed + skipped == len(rows) else "failed"
    return {
        "status": status,
        "summary": {"total": len(rows), "passed": passed, "failed": failed, "not_run": not_run, "skipped": skipped},
        "environment": targets.get("environment") or meta.get("env") or "unknown",
        "backend": targets.get("backend") or meta.get("backend") or "unknown",
        "commit": meta.get("commit") or "unknown",
        "runner": meta.get("runner") or "unknown",
        "run_url": meta.get("run_url") or "",
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "flows": rows,
    }


# ---- render ------------------------------------------------------------------------------------

RESULT_ICON = {"pass": "\u2705", "fail": "\u274c", "not_run": "\u23ed\ufe0f not run", "skipped": "\u26a0\ufe0f skipped"}
BACKEND_ICON = {"ok": "\u2705", "fail": "\u274c"}


def backend_cell(value, earning=None):
    cell = BACKEND_ICON.get(value or "", "\u2014")
    text = earning_text(earning)
    return "%s %s" % (cell, text) if text else cell


CHECK_ICON = {"pass": "\u2705", "fail": "\u274c", "skip": "\u26a0\ufe0f skipped"}


def check_result_text(check, result, environment):
    if result != "skip":
        return CHECK_ICON.get(result, result)
    flag = CHECK_FLAGS.get(check)
    why = "not on %s backend yet" % environment
    return "%s (%s%s)" % (CHECK_ICON["skip"], why, ": backend_checks.%s is false" % flag if flag else "")


def check_rows(report):
    """(flow, check label, result text, result) for every per-check verdict, in report order."""
    out = []
    for r in report["flows"]:
        for c in r.get("checks") or []:
            out.append((r["flow"], CHECK_LABELS.get(c["check"], c["check"]),
                        check_result_text(c["check"], c["result"], report["environment"]), c["result"]))
    return out


def fmt_duration(seconds):
    seconds = int(seconds or 0)
    if seconds < 60:
        return "%ds" % seconds
    return "%dm %02ds" % (seconds // 60, seconds % 60)


def md_cell(text):
    return str(text).replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ")


def headline(report):
    s = report["summary"]
    if report["status"] == "no_results":
        return "\u26a0\ufe0f iOS SDK e2e: no results (job failed before flows)"
    icon = "\u2705" if report["status"] == "passed" else "\u274c"
    line = "%s iOS SDK e2e: %d/%d passed" % (icon, s["passed"], s["total"])
    if s["not_run"]:
        line += ", %d not run" % s["not_run"]
    if s.get("skipped"):
        line += ", %d skipped" % s["skipped"]
    return line


def context_line(report):
    commit = report["commit"]
    parts = ["**Environment:** `%s`" % report["environment"],
             "**Backend:** `%s`" % report["backend"],
             "**Commit:** `%s`" % (commit[:7] if re.fullmatch(r"[0-9a-f]{40}", commit) else commit),
             "**Runner:** `%s`" % report["runner"]]
    if report["run_url"]:
        parts.append("[run summary](%s)" % report["run_url"])
    return " \u00b7 ".join(parts)


def screenshot_text(row, report):
    shot = row.get("screenshot")
    if not shot:
        return "none captured"
    where = "the `e2e-report` artifact"
    if report["run_url"]:
        where = "the [`e2e-report` artifact](%s#artifacts)" % report["run_url"]
    return "`%s` in %s" % (shot, where)


def link_text(row):
    return "%s `%s`" % (row["link"], row["url"]) if row.get("url") else row["link"]


def render_markdown(report):
    out = [MARKER, "## " + headline(report), "", context_line(report), ""]
    if report["status"] == "no_results":
        out += ["No flow recorded a result: the job stopped before the Maestro flows ran (unit tests, "
                "the key check, the simulator, or the app build). See the job log.", ""]
        return "\n".join(out)
    out += ["| Flow | Link | Link type | Match | Consent | Expected | Result | Attempts | Backend install recorded | Duration |",
            "|---|---|---|---|---|---|---|---|---|---|"]
    for r in report["flows"]:
        out.append("| %s |" % " | ".join(md_cell(c) for c in (
            "`%s`" % r["flow"], link_text(r), r.get("link_type") or "\u2014", r["match"], r["consent"], r["expected"],
            RESULT_ICON[r["result"]], r["attempts"], backend_cell(r["backend"], r.get("earning")),
            fmt_duration(r["duration_s"]) if r["attempts"] else "\u2014")))
    out.append("")
    checks = check_rows(report)
    if checks:
        out += ["### Backend checks", "", "| Flow | Check | Result |", "|---|---|---|"]
        for flow, label, text, _ in checks:
            out.append("| %s |" % " | ".join(md_cell(c) for c in ("`%s`" % flow, label, text)))
        out.append("")
    skipped = [r for r in report["flows"] if r["result"] == "skipped"]
    if skipped:
        out += ["### Skipped checks", ""]
        for r in skipped:
            out.append("- `%s`: %s" % (r["flow"], md_cell(skip_reason(r.get("backend_detail")) or "backend check skipped")))
        out.append("")
    failed = [r for r in report["flows"] if r["result"] == "fail"]
    if failed:
        out += ["### Failed flows", ""]
        for r in failed:
            out += ["#### \u274c `%s` (attempt %s of %s)" % (r["flow"], r.get("failed_attempt") or "?", r["attempts"]),
                    "",
                    "- **Failed step:** %s" % (md_cell(r.get("failed_step")) if r.get("failed_step") else "unknown"),
                    ]
            if r.get("error"):
                out.append("- **Error:** %s" % md_cell(r["error"]))
            if r.get("backend_detail") and r.get("backend") == "fail":
                out.append("- **Backend check:** %s" % md_cell(r["backend_detail"]))
            out.append("- **Screenshot:** %s" % screenshot_text(r, report))
            tail = r.get("log_tail") or []
            out += ["", "<details><summary>Last %d <code>[LinkTrail]</code> log lines</summary>" % len(tail), "",
                    "```text"]
            out += [l.replace("```", "'''") for l in tail] or ["(no [LinkTrail] lines captured)"]
            out += ["```", "", "</details>", ""]
    return "\n".join(out)


def render_html(report):
    e = html.escape
    rows = []
    for r in report["flows"]:
        cls = {"pass": "pass", "fail": "fail"}.get(r["result"], "skip")
        rows.append("<tr class=%s><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
                    "<td>%s</td><td>%d</td><td>%s</td><td>%s</td></tr>" % (
                        cls, e(r["flow"]),
                        e(r["link"]) + ("<br><code>%s</code>" % e(r["url"]) if r.get("url") else ""),
                        e(r.get("link_type") or "\u2014"), e(r["match"]), e(r["consent"]), e(r["expected"]),
                        e(RESULT_ICON[r["result"]]), r["attempts"], e(backend_cell(r["backend"], r.get("earning"))),
                        e(fmt_duration(r["duration_s"]) if r["attempts"] else "\u2014")))
    failures = []
    for r in report["flows"]:
        if r["result"] != "fail":
            continue
        failures.append("<h3>&#10060; <code>%s</code></h3><ul><li><b>Failed step:</b> %s</li>%s%s"
                        "<li><b>Screenshot:</b> <code>%s</code></li></ul><pre>%s</pre>" % (
                            e(r["flow"]), e(r.get("failed_step") or "unknown"),
                            "<li><b>Error:</b> %s</li>" % e(r["error"]) if r.get("error") else "",
                            "<li><b>Backend check:</b> %s</li>" % e(r["backend_detail"])
                            if r.get("backend") == "fail" and r.get("backend_detail") else "",
                            e(r.get("screenshot") or "none captured"),
                            e("\n".join(r.get("log_tail") or ["(no [LinkTrail] lines captured)"]))))
    commit = report["commit"]
    body = ("<h1>%s</h1><p>Environment <code>%s</code> &middot; backend <code>%s</code> &middot; commit <code>%s</code>"
            " &middot; runner <code>%s</code>%s &middot; generated %s</p>" % (
                e(headline(report)), e(report["environment"]), e(report["backend"]), e(commit), e(report["runner"]),
                ' &middot; <a href="%s">run</a>' % e(report["run_url"]) if report["run_url"] else "",
                e(report["generated_at"])))
    if report["status"] == "no_results":
        body += "<p>No flow recorded a result: the job stopped before the Maestro flows ran. See the job log.</p>"
    else:
        body += ("<table><thead><tr><th>Flow</th><th>Link</th><th>Link type</th><th>Match</th><th>Consent</th><th>Expected</th>"
                 "<th>Result</th><th>Attempts</th><th>Backend install recorded</th><th>Duration</th></tr></thead>"
                 "<tbody>%s</tbody></table>" % "".join(rows))
        checks = check_rows(report)
        if checks:
            body += ("<h2>Backend checks</h2><table><thead><tr><th>Flow</th><th>Check</th><th>Result</th></tr></thead><tbody>%s</tbody></table>"
                     % "".join("<tr class=%s><td><code>%s</code></td><td>%s</td><td>%s</td></tr>"
                               % ({"pass": "pass", "fail": "fail"}.get(res, "skip"), e(flow), e(label), e(text))
                               for flow, label, text, res in checks))
        if failures:
            body += "<h2>Failed flows</h2>" + "".join(failures)
    return ("<!doctype html><html lang=en><head><meta charset=utf-8><title>iOS SDK e2e report</title><style>"
            "body{font:14px -apple-system,Helvetica,Arial,sans-serif;margin:24px;color:#1f2328}"
            "table{border-collapse:collapse}th,td{border:1px solid #d0d7de;padding:6px 10px;text-align:left}"
            "th{background:#f6f8fa}tr.fail td{background:#ffebe9}tr.skip td{color:#656d76}"
            "pre{background:#f6f8fa;padding:12px;overflow:auto;font-size:12px}</style></head><body>%s</body></html>\n"
            % body)


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def cmd_render(args):
    os.makedirs(args.dir, exist_ok=True)
    meta = {"env": args.env, "backend": args.backend, "commit": args.commit, "runner": args.runner,
            "run_url": args.run_url}
    if args.skipped:
        line = "e2e skipped: %s" % args.skipped
        write(os.path.join(args.dir, "report.md"), "%s\n%s\n" % (MARKER, line))
        write(os.path.join(args.dir, "report.json"), json.dumps(
            {"status": "skipped", "reason": args.skipped, "commit": args.commit or "unknown"}, indent=2) + "\n")
        return 0
    report = build_report(load_flows(args.flows), read_results(os.path.join(args.dir, "results.jsonl")),
                          read_plan(os.path.join(args.dir, "plan.txt")), meta,
                          read_targets(args.targets or os.path.join(args.dir, "targets.json")))
    write(os.path.join(args.dir, "report.json"), json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    write(os.path.join(args.dir, "report.md"), render_markdown(report))
    write(os.path.join(args.dir, "report.html"), render_html(report))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="e2e-report.py")
    sub = p.add_subparsers(dest="cmd")

    lf = sub.add_parser("list-flows")
    lf.add_argument("--flows", default=DEFAULT_FLOWS)

    rec = sub.add_parser("record")
    rec.add_argument("--results", required=True)
    rec.add_argument("--flow", required=True)
    rec.add_argument("--attempt", type=int, required=True)
    rec.add_argument("--status", choices=("pass", "fail", "skipped"), required=True)
    rec.add_argument("--duration", type=int, default=0)
    rec.add_argument("--backend", choices=("ok", "fail", "skip", ""), default="")
    rec.add_argument("--backend-detail", default="")
    rec.add_argument("--maestro-log", default="")
    rec.add_argument("--app-log", default="")
    rec.add_argument("--screenshot", default="")
    rec.add_argument("--failed-step", default="")
    rec.add_argument("--error", default="")
    rec.add_argument("--device", default="")
    rec.add_argument("--link", default="")

    ren = sub.add_parser("render")
    ren.add_argument("--dir", required=True)
    ren.add_argument("--flows", default=DEFAULT_FLOWS)
    ren.add_argument("--env", default=os.environ.get("LINKTRAIL_ENV", ""))
    ren.add_argument("--backend", default="")
    ren.add_argument("--targets", default="")
    ren.add_argument("--commit", default="")
    ren.add_argument("--runner", default="")
    ren.add_argument("--run-url", default="")
    ren.add_argument("--skipped", default="")

    args = p.parse_args(argv)
    if args.cmd == "list-flows":
        return cmd_list_flows(args)
    if args.cmd == "record":
        return cmd_record(args)
    if args.cmd == "render":
        return cmd_render(args)
    p.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
