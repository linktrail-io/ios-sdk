# E2E: the published SDK

End-to-end tests for the **published** LinkTrail iOS SDK. The KickFlip demo in `e2e/example/` adds
this repo's Swift package by its release tag, the same way a customer app does, and Maestro drives
Safari and the app on a simulator against the production backend.

- **SDK version under test:** `exactVersion` in [`example/project.yml`](example/project.yml). This
  is the only place it is set. Bump it after each release.
- **Links and hosts:** [`scripts/e2e-env.json`](scripts/e2e-env.json). This is the only place for
  hosts, slugs and the backend URL. If a link type has no link for the environment, it is skipped
  with a notice.
- **Flows:** [`scripts/e2e-flows.json`](scripts/e2e-flows.json) sets the run order. Each flow is a
  `scripts/*.yaml` file.
- **Runner:** [`scripts/e2e-maestro.sh`](scripts/e2e-maestro.sh). It builds the example once for
  each consent mode, then installs the app fresh for every flow and runs it.
- **CI:** [`.github/workflows/e2e.yml`](../.github/workflows/e2e.yml) runs on GitHub-hosted macOS
  runners for pull requests, nightly and on manual dispatch. It never publishes anything.

## Flows

| Flow | What it covers |
|---|---|
| `deferred_{custom,subdomain}_{allow,deny}_automatic` | Consent screen, then the iOS "Allow Paste" alert. The deferred link lands on the product with its voucher. On allow the install is counted; on deny it is routed but not tracked. |
| `deferred_{custom,subdomain}_{allow,deny}_pastebutton` | Consent gate with the native Paste control. Same outcomes as above. |
| `deferred_{custom,subdomain}_{allow,deny}_problistic` | No clipboard read (`clickTokenSource: none`): probabilistic attribution. Checks the storefront, that no paste prompt appears, and, on deny, the app's `consent: false` install line. |
| `reengage_custom_{allow,deny}_universallink` | After a deferred install, the same link is opened again. It must route as re-engagement, with openCount +1 and no second reward. |
| `reward_custom_{allow,deny}_events` | After the install, events go through `trackEvent`. Covers the rev_share earning (revshare) and events on a link with no reward (general). |

Custom-domain links are on `link.kynxlabs.com` and subdomain links on `kick.linktrail.io`. The
custom-domain click-token flows also run once for each link type (general, campaign, influencer,
partner), and are reported as `<flow>__<type>`. The backend check verifies the link's reward and
this click's earning: none for general and campaign, `per_install` for influencer and partner.
On prod, `event` (per_event) has no link, so it is skipped.

The published binary has no debug device id. Because of that, the backend device lookup for the
probabilistic flows is off (`backend_checks.device_lookup: false`). Those rows show as *skipped*
for their backend check, while their UI asserts still run.

## Run locally

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
[Maestro](https://maestro.mobile.dev), plus a booted iPhone simulator.

```bash
LINKTRAIL_KEY=lt_live_… E2E_TOKEN=… bash e2e/scripts/e2e-maestro.sh            # every flow
LINKTRAIL_KEY=lt_live_… bash e2e/scripts/e2e-maestro.sh custom_allow_pastebutton  # one flow
LINKTRAIL_KEY=lt_live_… E2E_LINK_TYPES=none bash e2e/scripts/e2e-maestro.sh       # no link-type matrix
LINKTRAIL_KEY=lt_live_… E2E_BUILD_ONLY=1 bash e2e/scripts/e2e-maestro.sh         # build only
```

`LINKTRAIL_KEY` is the SDK key of the e2e workspace. It reaches the build through the environment
only and is never written to a file. Without `E2E_TOKEN`, the backend checks are recorded as
skipped. Results go to `e2e/example/.build-e2e/report/`.

## CI secrets

| Secret | Used for | When it is missing |
|---|---|---|
| `LINKTRAIL_KEY` | The SDK key baked into the example build | The flows are skipped with a notice. The example is still built against the published package. This always happens on fork pull requests. |
| `E2E_TOKEN` | `X-E2E-Token` for the backend checks | The flows run, and the backend checks are recorded as skipped (with a warning). |
