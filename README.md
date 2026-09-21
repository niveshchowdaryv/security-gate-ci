# Security Gate CI

Every pull request should have to prove it didn't smuggle in a leaked secret,
a known-vulnerable dependency, or an exploitable web flaw — before a human
ever looks at it. That's what this repo is: a GitHub Actions pipeline plus a
one-command local runner that runs three scanners (Gitleaks for secrets,
Trivy for HIGH/CRITICAL dependency vulnerabilities, and OWASP ZAP baseline
DAST) against OWASP Juice Shop, the intentionally-vulnerable app the security
world trains on. Any HIGH-or-worse finding fails the build, and every
scanner's report gets archived as a build artifact so you can see exactly
what broke.

## How it's wired

```
                        ┌─────────────────────────────┐
                        │   git push / pull request    │
                        └──────────────┬──────────────┘
                                       ▼
                        ┌─────────────────────────────┐
                        │  GitHub Actions              │
                        │  .github/workflows/         │
                        │  security-gate.yml          │
                        └──┬───────────┬──────────┬───┘
                           │           │          │
              ┌────────────┘           │          └────────────┐
              ▼                      ▼                       ▼
     ┌────────────────┐   ┌──────────────────┐   ┌────────────────────────┐
     │ Job: gitleaks  │   │ Job: trivy       │   │ Job: zap               │
     │ secret scan    │   │ fs scan (SARIF)  │   │ 1. docker compose up   │
     │ FAIL on any    │   │ FAIL on          │   │    juice-shop (:3000)  │
     │ leaked secret  │   │ HIGH/CRITICAL    │   │ 2. ZAP baseline scan   │
     │                │   │ + image scan of  │   │    vs juice-shop:3000  │
     │                │   │ Juice Shop       │   │    FAIL on HIGH-risk   │
     └────────────────┘   └──────────────────┘   └───────────┬────────────┘
                                                            ▼
                                               ┌────────────────────────┐
                                               │ reports/               │
                                               │ zap-baseline.html/json │
                                               │ trivy*.sarif           │
                                               │ gitleaks.json          │
                                               │ uploaded as CI         │
                                               │ artifacts (always)     │
                                               └────────────────────────┘

     Local equivalent: ./scripts/run-local.sh runs all four stages with Docker.
```

## Quickstart

You need Docker Engine with the compose plugin (Docker Desktop is fine).
No credentials, no accounts.

```bash
# 1. Clone and enter the project
git clone <your-fork-url> security-gate-ci
cd security-gate-ci

# 2. Start the intentionally-vulnerable target app
docker compose up -d
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/   # expect 200

# 3. Run the whole gate locally (Gitleaks + Trivy + ZAP, with reports)
./scripts/run-local.sh

# 4. Open the DAST report
xdg-open reports/zap-baseline.html   # Linux
# open reports/zap-baseline.html     # macOS

# 5. Stop the target when done
docker compose down
```

The first run takes a few minutes: Docker pulls the Juice Shop image and the
scanner images, and Trivy downloads its vulnerability database once (it gets
cached in a Docker volume after that).

## What CI does

`.github/workflows/security-gate.yml` runs on every push and pull request to
`main`, on a weekly schedule (Mondays 06:00 UTC), and on demand via
`workflow_dispatch`.

| Job | Tool | Gate |
|-----|------|------|
| `gitleaks` | `gitleaks/gitleaks-action@v2` (full history) | FAIL on any leaked secret |
| `trivy` | `aquasecurity/trivy-action@v0.33.1`, filesystem scan → SARIF | FAIL on HIGH/CRITICAL |
| `trivy` (image) | same action, image scan of `bkimminich/juice-shop:latest` | report-only for now (flip to a gate with `exit-code: "1"`) |
| `zap` | official `ghcr.io/zaproxy/zaproxy:stable` image, `zap-baseline.py` with `zap/rules.tsv` | FAIL on HIGH-risk findings |

The ZAP job spins up Juice Shop with `docker compose up -d`, waits for
`http://localhost:3000` to answer, then runs the ZAP baseline scan from a
container on the compose `secgate` network, targeting the Juice Shop service
by name (`http://juice-shop:3000`). A container can't reach the runner's
`localhost`, so the scan goes through the shared Docker network instead of
the `zaproxy/action-baseline` wrapper — same official ZAP image, full control
of the flags. `zap-baseline.py` exit codes drive the gate: `1` (FAIL-level
finding) or `3` (scan error) break the build, `2` (warnings only) passes.
Reports (HTML + JSON + SARIF) upload as workflow artifacts `if: always()`,
so you can inspect exactly what failed.

Rule tuning lives in `zap/rules.tsv`: HIGH-risk rules (PII disclosure, XSS/SQLi
families, ShellShock) are `FAIL`, medium/low security-relevant findings are
`WARN` (reported, don't break the build), and low-noise informational rules
(user-agent fuzzer, viewstate, cache notes) are `IGNORE`. Note the format is
three fields per line (id, action, URL regex) — newer ZAP versions reject the
old two-field layout.

## Things I learned the annoying way

- The Trivy action tag needs the `v` prefix (`@v0.33.1`, not `@0.33.1`) —
  without it the workflow fails at setup with a "not found" error that looks
  like your fault.
- Pin the Trivy *binary* version too (`version: "v0.74.0"` in the workflow).
  The action's default pointed at a release tag that doesn't exist, so the
  setup step died silently right after "found version". Took me an embarrassingly
  long stare at the logs to figure that one out.
- Gitleaks scans full history, so if you ever force-push a rewritten history
  it can complain about SHAs that no longer exist. That's not a real leak,
  it's the action chasing a ghost commit.
- ZAP baseline takes a few minutes even against a tiny app. If the CI job
  looks stuck, it's probably not — check the artifacts when it finishes.

## Where I'd take this next

- [ ] Authenticated ZAP scan: script a Juice Shop login, export a ZAP context
      file, and scan behind authentication. That's where the real bugs hide.
- [ ] Alerting: post gate results to Slack or email on failure, with links to
      the failing run's artifacts.
- [ ] Trend dashboard: parse `reports/zap-baseline.json` and `trivy.json` on
      each run, append finding counts to a JSONL log, and render a small
      findings-over-time page.

## If you're reading this on my resume

Built a CI security gate (Gitleaks + Trivy + OWASP ZAP DAST against OWASP
Juice Shop) that blocks HIGH/CRITICAL findings before merge. Runs on every PR
plus a weekly schedule, with HTML/JSON/SARIF reports archived as build
artifacts. Tuned ZAP baseline rules to a HIGH-risk fail policy so informational
noise doesn't break builds while OWASP Top 10 categories (injection, XSS,
security misconfiguration, sensitive-data exposure) stay covered.

## Repo layout

```
security-gate-ci/
├── .github/workflows/security-gate.yml  # the CI pipeline (gitleaks, trivy, zap)
├── docker-compose.yml                   # OWASP Juice Shop target on port 3000
├── zap/rules.tsv                        # ZAP baseline rule tuning (FAIL/WARN/IGNORE)
├── scripts/run-local.sh                 # one-command local run of the whole gate
├── reports/                             # generated on each run (gitignored)
└── README.md
```
