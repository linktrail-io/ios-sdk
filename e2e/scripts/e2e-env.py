#!/usr/bin/env python3
"""Resolve an e2e run's environment and links from scripts/e2e-env.json (stdlib only, Python 3.9+).

    e2e-env.py resolve [--config F] [--flows F] [--format shell|github] [--write F]

Inputs come from the environment (empty or unset = the default), the same names everywhere:

    LINKTRAIL_ENV                  dev | prod ('test' is an alias of dev); empty = prod
    E2E_CUSTOM_LINK                full https URL or bare slug, for each of the four link slots
    E2E_SUBDOMAIN_LINK
    E2E_CUSTOM_PROBLISTIC_LINK
    E2E_SUBDOMAIN_PROBLISTIC_LINK
    E2E_EXPECT_PRODUCT             optional: product name the click-token allow flows must show (default: expect.product)
    E2E_EXPECT_VOUCHER             optional: voucher code they must show (default: expect.voucher)
    E2E_LINK_TYPES                 link types to run through the matrix flows: all (default), none, or
                                   a comma list (general,campaign,…); types with no link in the
                                   environment are skipped with a NOTICE line on stderr

`--format shell` prints shell-quoted assignments for scripts/e2e-maestro.sh to eval; `--format
github` prints key=value lines for $GITHUB_OUTPUT. `--write` also saves the resolved run as JSON (the
e2e report reads it for its header and its per-row links). Any bad input exits 1 with one ERROR line
on stderr and prints nothing on stdout, so a caller can never eval half a result.
"""
import argparse
import json
import os
import re
import shlex
import sys
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(HERE, "e2e-env.json")
DEFAULT_FLOWS = os.path.join(HERE, "e2e-flows.json")

SLUG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")
VOUCHER = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
FLOW_NAME = re.compile(r"^[A-Za-z0-9_]+$")
LINK_TYPE = re.compile(r"^[a-z][a-z0-9]{0,31}$")
REGEX_SPECIAL = re.compile(r"([\\.^$|?*+()\[\]{}])")


class InputError(Exception):
    pass


def slot_var(slot):
    return "E2E_" + slot.upper()


HOST_FIELDS = ("custom_host", "subdomain_host")
# The newer verify-endpoint checks, deployed per environment (backend_checks in e2e-env.json).
BACKEND_CHECKS = ("earning", "device_lookup", "reengagement_open_count", "events")
# The reward models a link-type run's backend check knows how to judge (scripts/e2e-verify.sh judge).
REWARD_MODELS = (None, "per_install", "per_event", "rev_share")
# Rewards earned by events after the install: only flows that send events (reward_*) can judge them.
EVENT_REWARD_MODELS = ("per_event", "rev_share")
# The real backend link types (the verify response's linkType); matrix types map onto them (link_type_kinds).
BACKEND_LINK_TYPES = ("general", "campaign", "influencer", "partner")


def load_config(path):
    with open(path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    envs = cfg.get("environments")
    if not isinstance(envs, dict) or not envs:
        raise ValueError("%s: no 'environments'" % path)
    if cfg.get("default_environment") not in envs:
        raise ValueError("%s: default_environment must be one of %s" % (path, sorted(envs)))
    for name, env in envs.items():
        for key in ("backend_url", "key_secret") + HOST_FIELDS:
            if not isinstance(env.get(key), str) or not env[key]:
                raise ValueError("%s: environment '%s' is missing '%s'" % (path, name, key))
        if not isinstance(env.get("override_backend"), bool):
            raise ValueError("%s: environment '%s' needs a boolean 'override_backend'" % (path, name))
        checks = env.get("backend_checks")
        if not isinstance(checks, dict) or set(checks) != set(BACKEND_CHECKS) or not all(isinstance(v, bool) for v in checks.values()):
            raise ValueError("%s: environment '%s' needs backend_checks with a boolean %s"
                             % (path, name, ", ".join(BACKEND_CHECKS)))
        if checks["events"] and not checks["earning"]:
            # The events check runs in the reward-events stage, which only runs with the earning check.
            raise ValueError("%s: environment '%s' has backend_checks.events true but earning false: events needs earning"
                             % (path, name))
        if not env["backend_url"].startswith("https://"):
            raise ValueError("%s: environment '%s' backend_url must be an https URL" % (path, name))
    for alias, target in (cfg.get("aliases") or {}).items():
        if target not in envs:
            raise ValueError("%s: alias '%s' points at unknown environment '%s'" % (path, alias, target))
    links = cfg.get("links")
    if not isinstance(links, dict) or not links:
        raise ValueError("%s: no 'links'" % path)
    for slot, link in links.items():
        if link.get("host") not in HOST_FIELDS or not SLUG.match(link.get("slug") or ""):
            raise ValueError("%s: link '%s' needs host in %s and a valid slug" % (path, slot, list(HOST_FIELDS)))
    if not VOUCHER.match((cfg.get("expect") or {}).get("voucher") or ""):
        raise ValueError("%s: expect.voucher must be a voucher code" % path)
    types = cfg.get("link_types") or {}
    if not isinstance(types, dict):
        raise ValueError("%s: 'link_types' must be an object" % path)
    for t, per_env in types.items():
        if not LINK_TYPE.match(t) or not isinstance(per_env, dict):
            raise ValueError("%s: link type %r needs a lower-case name and an object per environment" % (path, t))
        for name, link in per_env.items():
            if name not in envs:
                raise ValueError("%s: link type '%s' names unknown environment '%s'" % (path, t, name))
            if link.get("host") not in HOST_FIELDS or not SLUG.match(link.get("slug") or ""):
                raise ValueError("%s: link type '%s' (%s) needs host in %s and a valid slug" % (path, t, name, list(HOST_FIELDS)))
    rewards = cfg.get("link_type_rewards")
    if types or rewards is not None:
        if not isinstance(rewards, dict):
            raise ValueError("%s: link_type_rewards must map every link type to a reward model or null" % path)
        for t in types:
            if t not in rewards:
                raise ValueError("%s: link type '%s' has no entry in link_type_rewards (a reward model or null)" % (path, t))
        for t, model in rewards.items():
            if t not in types:
                raise ValueError("%s: link_type_rewards names unknown link type '%s'" % (path, t))
            if model not in REWARD_MODELS:
                raise ValueError("%s: link_type_rewards['%s'] must be null or one of %s"
                                 % (path, t, ", ".join(m for m in REWARD_MODELS if m)))
    kinds = cfg.get("link_type_kinds")
    if types or kinds is not None:
        if not isinstance(kinds, dict):
            raise ValueError("%s: link_type_kinds must map every link type to its real backend link type" % path)
        for t in types:
            if t not in kinds:
                raise ValueError("%s: link type '%s' has no entry in link_type_kinds (one of %s)"
                                 % (path, t, ", ".join(BACKEND_LINK_TYPES)))
        for t, kind in kinds.items():
            if t not in types:
                raise ValueError("%s: link_type_kinds names unknown link type '%s'" % (path, t))
            if kind not in BACKEND_LINK_TYPES:
                raise ValueError("%s: link_type_kinds['%s'] must be one of %s" % (path, t, ", ".join(BACKEND_LINK_TYPES)))
    if any(m in EVENT_REWARD_MODELS for m in (rewards or {}).values()):
        re_ = cfg.get("reward_events") or {}
        if not (isinstance(re_.get("other_event"), str) and re_["other_event"]
                and isinstance(re_.get("revenue_event"), str) and re_["revenue_event"]
                and isinstance(re_.get("revenue_minor"), int) and re_["revenue_minor"] > 0
                and isinstance(re_.get("other_currencies"), list) and len(re_["other_currencies"]) >= 2
                and all(isinstance(c, str) and re.match(r"^[A-Z]{3}$", c) for c in re_["other_currencies"])):
            raise ValueError("%s: reward_events needs other_event, revenue_event, a positive integer revenue_minor "
                             "and at least two ISO other_currencies" % path)
    if types:
        lte = cfg.get("link_type_expect") or {}
        if not VOUCHER.match(lte.get("voucher") or "") or not lte.get("product") or not lte.get("source"):
            raise ValueError("%s: link_type_expect needs product, voucher and source" % path)
    return cfg


def pick_environment(cfg, raw):
    value = (raw or "").strip().lower()
    if not value:
        return cfg["default_environment"], ""
    aliases = cfg.get("aliases") or {}
    if value in aliases:
        return aliases[value], value
    if value in cfg["environments"]:
        return value, ""
    names = sorted(cfg["environments"]) + sorted(aliases)
    raise InputError("unknown environment '%s' (LINKTRAIL_ENV / the 'environment' input): use one of %s"
                     % (raw.strip(), ", ".join(names)))


def owner_of(cfg, host):
    return [n for n, e in sorted(cfg["environments"].items()) if host in (e["custom_host"], e["subdomain_host"])]


def resolve_link(cfg, env_name, slot, raw):
    env = cfg["environments"][env_name]
    default = cfg["links"][slot]
    host_field = default["host"]
    want = env[host_field].lower()
    value = (raw or "").strip()
    var = slot_var(slot)
    if not value:
        return "https://%s/%s" % (want, default["slug"]), "default"
    if SLUG.match(value):
        return "https://%s/%s" % (want, value), "slug"
    if "://" not in value:
        raise InputError("%s (%s) '%s' is neither a slug (letters, digits, - and _) nor a full https:// URL"
                         % (slot, var, value))
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError:
        raise InputError("%s (%s) '%s' is not a valid URL" % (slot, var, value))
    if parts.scheme.lower() != "https":
        raise InputError("%s (%s) '%s' must use https" % (slot, var, value))
    if parts.username or parts.password or port is not None or parts.query or parts.fragment:
        raise InputError("%s (%s) '%s' must be https://<host>/<slug> (no credentials, port, query or fragment)"
                         % (slot, var, value))
    host = (parts.hostname or "").lower()
    if host != want:
        others = [n for n in owner_of(cfg, host) if n != env_name]
        hint = " (it belongs to '%s')" % others[0] if others else ""
        raise InputError("%s (%s) host '%s' is not the %s %s for this slot: use %s%s"
                         % (slot, var, host or "<none>", env_name, host_field, want, hint))
    slug = parts.path[1:] if parts.path.startswith("/") else parts.path
    if not SLUG.match(slug):
        raise InputError("%s (%s) '%s' needs exactly one path segment, the slug (https://%s/<slug>)"
                         % (slot, var, value, want))
    return "https://%s/%s" % (host, slug), "url"


def resolve_expect(cfg, product_raw, voucher_raw):
    product = (product_raw or "").strip()
    voucher = (voucher_raw or "").strip()
    exp = cfg.get("expect") or {}
    product = product or (exp.get("product") or "").strip()
    voucher = voucher or exp["voucher"]
    if product and (len(product) > 100 or any(ord(c) < 32 for c in product)):
        raise InputError("expect_product (E2E_EXPECT_PRODUCT) must be one line of at most 100 characters")
    if not VOUCHER.match(voucher):
        raise InputError("expect_voucher (E2E_EXPECT_VOUCHER) '%s' must be letters, digits, - and _ only" % voucher)
    # The flows match it as a Maestro (Java) regex: the code is regex-safe (validated above), the
    # percentage is whatever the voucher grants.
    text = "Voucher %s applied · [0-9]+%% off" % voucher
    return {
        "product": product,
        # Maestro matches text as a regex: escape the name so "(Retro)" or "1.0" match literally.
        "product_text": regex_literal(product),
        "voucher": voucher,
        "voucher_text": text,
    }


def regex_literal(text):
    return REGEX_SPECIAL.sub(r"\\\1", text)


def resolve_link_types(cfg, env_name, raw):
    """(selected types in config order, {type: url}, [skipped types]) for E2E_LINK_TYPES."""
    known = list((cfg.get("link_types") or {}).keys())
    value = (raw or "").strip().lower()
    if value in ("", "all"):
        wanted = known
    elif value == "none":
        wanted = []
    else:
        wanted = [t.strip() for t in value.split(",") if t.strip()]
        unknown = [t for t in wanted if t not in known]
        if unknown or not wanted:
            raise InputError("E2E_LINK_TYPES / link_types: unknown link type '%s'; use all, none, or a comma list of %s"
                             % (",".join(unknown) or raw.strip(), ", ".join(known)))
        wanted = [t for t in known if t in wanted]   # config order, no duplicates
    env = cfg["environments"][env_name]
    urls, skipped = {}, []
    for t in wanted:
        link = cfg["link_types"][t].get(env_name)
        if link:
            urls[t] = "https://%s/%s" % (env[link["host"]].lower(), link["slug"])
        else:
            skipped.append(t)
    return [t for t in wanted if t in urls], urls, skipped


def load_flow_slots(path):
    with open(path, encoding="utf-8") as fh:
        rows = json.load(fh)["flows"]
    out = []
    for r in rows:
        if not FLOW_NAME.match(r.get("flow", "")):
            raise ValueError("%s: flow name %r must be letters, digits and _" % (path, r.get("flow")))
        if r.get("link_type_only") and not r.get("link_type_matrix"):
            raise ValueError("%s: flow '%s' is link_type_only but not link_type_matrix" % (path, r["flow"]))
        m = r.get("link_type_matrix")
        if not (m is None or isinstance(m, bool) or (isinstance(m, list) and m and all(isinstance(t, str) for t in m))):
            raise ValueError("%s: flow '%s' link_type_matrix must be true or a list of link types" % (path, r["flow"]))
        out.append((r["flow"], r.get("slot", ""), m if isinstance(m, list) else bool(m), bool(r.get("link_type_only"))))
    return out


def resolve(cfg, flow_slots, environ):
    env_name, alias = pick_environment(cfg, environ.get("LINKTRAIL_ENV"))
    env = cfg["environments"][env_name]
    links, sources = {}, {}
    for slot in cfg["links"]:
        links[slot], sources[slot] = resolve_link(cfg, env_name, slot, environ.get(slot_var(slot)))
    flows = {}
    for flow, slot, _, only in flow_slots:
        if slot not in links:
            raise ValueError("scripts/e2e-flows.json: flow '%s' has unknown slot '%s' (one of %s)"
                             % (flow, slot, ", ".join(links)))
        if not only:   # a link_type_only flow never runs on its slot's own link
            flows[flow] = links[slot]
    types, type_urls, skipped = resolve_link_types(cfg, env_name, environ.get("E2E_LINK_TYPES"))
    lte = cfg.get("link_type_expect") or {}
    matrix_flows = [f for f, _, m, _ in flow_slots if m]
    only_flows = [f for f, _, _, o in flow_slots if o]
    rewards = cfg.get("link_type_rewards") or {}
    known = list((cfg.get("link_types") or {}).keys())
    def flow_types(m):
        # true: every type whose reward needs no events; a list: exactly those types.
        if m is True:
            return [t for t in known if rewards.get(t) not in EVENT_REWARD_MODELS]
        unknown = [t for t in m if t not in known]
        if unknown:
            raise ValueError("scripts/e2e-flows.json: link_type_matrix names unknown link type '%s'" % unknown[0])
        return [t for t in known if t in m]
    per_flow = {f: flow_types(m) for f, _, m, _ in flow_slots if m}
    jobs = []
    for t in types:   # type-major: the run order of the matrix jobs
        for f in matrix_flows:
            if t in per_flow[f]:
                flows["%s__%s" % (f, t)] = type_urls[t]
                jobs.append("%s@%s" % (f, t))
    return {
        "link_types": types,
        "link_types_skipped": skipped,
        "link_type_urls": type_urls,
        "link_type_flows": matrix_flows,
        "link_type_only_flows": only_flows,
        "link_type_jobs": jobs,
        "link_type_rewards": {t: rewards.get(t) for t in known},
        "link_type_kinds": {t: (cfg.get("link_type_kinds") or {}).get(t) for t in known},
        "reward_events": cfg.get("reward_events") or {},
        "link_type_expect": {
            "product": lte.get("product", ""),
            "product_text": regex_literal(lte.get("product", "")),
            "voucher": lte.get("voucher", ""),
            "voucher_text": "Voucher %s applied · [0-9]+%% off" % lte.get("voucher", "") if lte.get("voucher") else "",
            "source": lte.get("source", ""),
            "source_text": regex_literal(lte.get("source", "")),
        },
        "environment": env_name,
        "requested_environment": alias or env_name,
        "backend": env["backend_url"],
        "set_sdk_base": env["override_backend"],
        "backend_checks": dict(env["backend_checks"]),
        "key_secret": env["key_secret"],
        "subdomain_host": env["subdomain_host"],
        "custom_host": env["custom_host"],
        "links": links,
        "link_sources": sources,
        "flows": flows,
        "expect": resolve_expect(cfg, environ.get("E2E_EXPECT_PRODUCT"), environ.get("E2E_EXPECT_VOUCHER")),
    }


def assignments(run):
    pairs = [
        ("E2E_ENV_NAME", run["environment"]),
        ("BACKEND_URL", run["backend"]),
        ("SET_SDK_BASE", "1" if run["set_sdk_base"] else "0"),
        ("E2E_CHECK_EARNING", "1" if run["backend_checks"]["earning"] else "0"),
        ("E2E_CHECK_DEVICE_LOOKUP", "1" if run["backend_checks"]["device_lookup"] else "0"),
        ("E2E_CHECK_OPEN_COUNT", "1" if run["backend_checks"]["reengagement_open_count"] else "0"),
        ("E2E_CHECK_EVENTS", "1" if run["backend_checks"]["events"] else "0"),
        ("KEY_SECRET", run["key_secret"]),
        ("SUBDOMAIN_HOST", run["subdomain_host"]),
        ("CUSTOM_HOST", run["custom_host"]),
        ("EXPECT_PRODUCT", run["expect"]["product"]),
        ("EXPECT_PRODUCT_TEXT", run["expect"]["product_text"]),
        ("EXPECT_VOUCHER", run["expect"]["voucher"]),
        ("EXPECT_VOUCHER_TEXT", run["expect"]["voucher_text"]),
    ]
    pairs += [(slot_var(s), u) for s, u in run["links"].items()]
    pairs += [("E2E_URL_" + f, u) for f, u in run["flows"].items()]
    lte = run["link_type_expect"]
    pairs += [
        ("LINK_TYPES", " ".join(run["link_types"])),
        ("LINK_TYPES_SKIPPED", " ".join(run["link_types_skipped"])),
        ("LINK_TYPE_FLOWS", " ".join(run["link_type_flows"])),
        ("LINK_TYPE_ONLY_FLOWS", " ".join(run["link_type_only_flows"])),
        ("LINK_TYPE_JOBS", " ".join(run["link_type_jobs"])),
        ("LT_EXPECT_PRODUCT_TEXT", lte["product_text"]),
        ("LT_EXPECT_VOUCHER_TEXT", lte["voucher_text"]),
        ("LT_EXPECT_SOURCE_TEXT", lte["source_text"]),
    ]
    return pairs


def main(argv):
    p = argparse.ArgumentParser(prog="e2e-env.py")
    sub = p.add_subparsers(dest="cmd")
    r = sub.add_parser("resolve")
    r.add_argument("--config", default=DEFAULT_CONFIG)
    r.add_argument("--flows", default=DEFAULT_FLOWS)
    r.add_argument("--format", choices=("shell", "github", "json"), default="shell")
    r.add_argument("--write", default="")
    args = p.parse_args(argv)
    if args.cmd != "resolve":
        p.print_usage(sys.stderr)
        return 2
    try:
        run = resolve(load_config(args.config), load_flow_slots(args.flows), os.environ)
    except InputError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError) as e:
        print("ERROR: bad e2e config: %s" % e, file=sys.stderr)
        return 1
    if run["link_types_skipped"]:
        print("NOTICE: link types skipped on %s (no link configured in scripts/e2e-env.json): %s"
              % (run["environment"], ", ".join(run["link_types_skipped"])), file=sys.stderr)
    if args.write:
        os.makedirs(os.path.dirname(os.path.abspath(args.write)), exist_ok=True)
        with open(args.write, "w", encoding="utf-8") as fh:
            json.dump(run, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    if args.format == "json":
        print(json.dumps(run, indent=2, ensure_ascii=False))
    elif args.format == "github":
        for k, v in assignments(run):
            print("%s=%s" % (k.lower(), v))
    else:
        for k, v in assignments(run):
            print("%s=%s" % (k, shlex.quote(v)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
