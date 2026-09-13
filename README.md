# Security Gate CI

**What / why.** Every pull request should prove it didn't smuggle in a leaked secret, a known-vulnerable dependency, or an exploitable web flaw — before a human ever reviews it. This project is a working security gate: a GitHub Actions pipeline plus a one-command local runner that scans for leaked secrets (Gitleaks), HIGH/CRITICAL dependency vulnerabilities (Trivy), and live web vulnerabilities (OWASP ZAP baseline DAST) against OWASP Juice Shop, the intentionally-vulnerable app the security industry trains on. Any HIGH-or-worse finding fails the build, and every scanner's report is archived as a build artifact.

## Architecture

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

Prerequisites: Docker Engine with the compose plugin (Docker Desktop counts). No credentials needed.

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

The first run takes a few minutes: Docker pulls the Juice Shop image and the scanner images, and Trivy downloads its vulnerability database once (cached in a Docker volume afterwards).

## CI overview

`.github/workflows/security-gate.yml` runs on every push and pull request to `main`, on a weekly schedule (Mondays 06:00 UTC), and on demand via `workflow_dispatch`.

| Job | Tool | Gate |
|-----|------|------|
| `gitleaks` | `gitleaks/gitleaks-action@v2` (full history) | FAIL on any leaked secret |
| `trivy` | `aquasecurity/trivy-action@0.33.1`, filesystem scan → SARIF | FAIL on HIGH/CRITICAL |
| `trivy` (bonus) | same action, image scan of `bkimminich/juice-shop:latest` | report-only (promote to gate by setting `exit-code: "1"`) |
| `zap` | official `ghcr.io/zaproxy/zaproxy:stable` image, `zap-baseline.py` with `zap/rules.tsv` | FAIL on HIGH-risk findings |

How the ZAP job works: it starts Juice Shop with `docker compose up -d`, waits for `http://localhost:3000` to answer, then runs the ZAP baseline scan from a container attached to the compose `secgate` network, targeting the Juice Shop service by name (`http://juice-shop:3000`). A container cannot reach the runner's `localhost`, so the scan goes through the shared Docker network instead of the `zaproxy/action-baseline` wrapper — same official ZAP image, full control of the flags. `zap-baseline.py` exit codes drive the gate: `1` (FAIL-level finding) or `3` (scan error) break the build; `2` (warnings only) passes. Reports (HTML + JSON + SARIF) are uploaded as workflow artifacts `if: always()`, so you can inspect exactly what broke the build.

ZAP rule tuning lives in `zap/rules.tsv`: HIGH-risk rules (PII disclosure, XSS/SQLi families, ShellShock) are `FAIL`; medium/low security-relevant findings are `WARN` (reported, don't break the build); low-noise informational rules (user-agent fuzzer, viewstate, cache notes) are `IGNORE`.

## 2-weekend build roadmap

**Weekend 1 — pipeline green.**
- [ ] Clone, run `./scripts/run-local.sh`, confirm all four stages execute end to end.
- [ ] Push to GitHub and watch the Security Gate workflow run green on the first PR.
- [ ] Tune `zap/rules.tsv` against the real Juice Shop findings until WARN/IGNORE is right and only true HIGH-risk items can break the build.
- [ ] Add a `SECURITY.md` and a workflow status badge to this README.

**Weekend 2 — make it production-grade.**
- [ ] Authenticated ZAP scan: script a Juice Shop login, export a ZAP context file, and scan behind authentication — this is where the real vulnerabilities hide.
- [ ] Alerting: post gate results to Slack (incoming webhook) or email on failure, with links to the failing run's artifacts.
- [ ] Trend dashboard: parse `reports/zap-baseline.json` and `trivy.json` on each run, append finding counts to a JSONL log, and render a small findings-over-time page (or push the metrics to Grafana).

## Resume bullets

- Built a CI security gate (Gitleaks + Trivy + OWASP ZAP DAST vs. OWASP Juice Shop) that **blocked N high-severity findings pre-merge**; runs on every PR plus a weekly schedule, with HTML/JSON/SARIF reports archived as build artifacts.
- Tuned ZAP baseline rules to a HIGH-risk fail policy, cutting low-noise informational alerts by **~N%** while retaining coverage of OWASP Top 10 categories (injection, XSS, security misconfiguration, sensitive-data exposure).

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
