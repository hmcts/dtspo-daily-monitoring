# Privileged RBAC Monitor — Live Test Plan

+++++
todo
need to check if assignment to a privileged group without eligible flags
++++++


DC
DTS Contributors (sub:dts-archiving-prod)
7d6763d1-7fd9-4fc1-8bf0-080d090ac47b

DTS Contributors Eligible (sub:dts-archiving-prod)
47bb06f0-772e-4bf1-a9ba-d408790ec44b




This plan validates the complete privileged-access monitoring solution
(`audit-privileged-rbac-p.sh` → `rbac-change-monitor.sh`, plus the
`extract-iac-groups.sh` IaC reconciliation feed and the detection pipeline)
against the live Azure estate.

**Key insight to build the plan around:** the monitor keys on the *group name*,
not how a user entered the group. So "portal add to an IaC-managed group" is
reconciled the same as "IaC add" — the meaningful distinctions are
**direct vs group** and **IaC-group vs non-IaC-group**. The matrix below covers
that plus the anti-poisoning, coverage, and operational guarantees.

## Test matrix

### 1. Core diff detection (transitions)

| # | Setup / Action | Expected report | Marker |
|---|---|---|---|
| 1.1 | **Direct** privileged role (e.g. Owner) granted to test user via **portal** | `NEW PERMANENT … via Direct` | 🔴 |
| 1.2 | Add test user to a **non-IaC** privileged group (portal) | `GROUP-INHERITED ADD … "<group>" *` (asterisk + footnote) | 🔴 |
| 1.3 | Add test user to an **IaC-managed** privileged group (via IaC PR *or* portal — verify they look identical) | `GROUP-INHERITED ADD … "<group>"` (no asterisk) | 🔴 |
| 1.4 | Remove any of the above grants | `REMOVED` / `GROUP-INHERITED REMOVE` | 🟡 |
| 1.5 | Two **identical** snapshots (no change) | "No privileged RBAC changes" + **no Slack post** | — |

### 2. Standing privilege / anti-poisoning (the differentiators)

| # | Setup / Action | Expected report | Marker |
|---|---|---|---|
| 2.1 | Leave 1.1's direct grant in place; run audit→monitor **again** (now in baseline too) | `STANDING PRIVILEGE … held … not IaC-managed or allowlisted` — **re-fires, does not age out** | 🔴 |
| 2.2 | Run a **3rd** time, still in place | Still `STANDING PRIVILEGE`, `held ~Nd` **age increments** (ledger) | 🔴 |
| 2.3 | Remove the grant, then re-add it next run | Ledger resets → age starts fresh (`first flagged this run`) | 🔴 |
| 2.4 | Standing grant via **non-IaC group** (2.1 but group form) | `STANDING PRIVILEGE … group not IaC-managed` (one aggregated line for all roles) | 🔴 |
| 2.5 | **Service principal / managed identity** with standing Owner | **Not** flagged by standing check (governed elsewhere) | — |

### 3. Legitimacy reconciliation

| # | Setup / Action | Expected report | Marker |
|---|---|---|---|
| 3.1 | Standing grant via an **IaC-managed** group | Suppressed → `STANDING PRIVILEGE RECONCILED n …` | ✅ |
| 3.2 | Add the test principal's **object ID/UPN** to `allowlist.txt`, then direct grant | `ALLOWLISTED ADD`; standing suppressed | ✅ |
| 3.3 | **Self-updating baseline**: flag a standing grant via a brand-new TF group, then add that group to a source repo + re-run `extract-iac-groups.sh` → next monitor run | Previously-🔴 standing alert goes **quiet** (now IaC-reconciled) | ✅→silent |
| 3.4 | Confirm allowlist matches **only** on ID/UPN, not DisplayName (rename test user, keep ID) | Still allowlisted | ✅ |

### 4. Coverage / integrity safety nets

| # | Setup / Action | Expected report | Marker |
|---|---|---|---|
| 4.1 | Point audit at a sub the SP **cannot read** (revoke Reader on the test sub) | `AUDIT COVERAGE FAILURE … UNDETECTED` | 🔴 |
| 4.2 | Baseline covered sub X; current run **omits** X (`--subscription` excludes it) | `AUDIT COVERAGE LOSS`; X's removals **suppressed** | 🔴 |
| 4.3 | Reverse of 4.2 — current run **adds** a sub absent from baseline | `AUDIT COVERAGE GAINED`; pre-existing adds **suppressed** to one note | 🟡 |
| 4.4 | Audit identity lacking `PrivilegedAccess.Read.AzureADGroup` | `PIM BLIND SPOT` | 🔴 |
| 4.5 | Legacy snapshot with **no `.meta.json`** | Diffs normally, no coverage assertions (graceful) | — |

### 5. Operational / pipeline

| # | Setup / Action | Expected result |
|---|---|---|
| 5.1 | **First run / no baseline** (the `rbac-snapshot not found` case) | Skips change detection, **no false alert** — confirm the download is tolerant |
| 5.2 | Force a mid-pipeline step failure | **Control-failure heartbeat** 🔴 posts to Slack |
| 5.3 | `extract-iac-groups` daily: add/remove a group in a source repo | `IAC GROUP ADDED` / `REMOVED` 🟡 vs previous artifact |
| 5.4 | Ledger artifact round-trips across two pipeline runs | Age tracking persists (download→seed→republish) |
| 5.5 | Slack smoke test step | `testfile.txt` echoed to console **and** posts to target channel |
| 5.6 | Group aggregation: test user in a group granting **many** roles | **One** Slack line, not N |

## Two findings worth noting before you run

1. **Scenarios 1 & 2 converge.** A portal membership change *into an existing
   IaC-managed privileged group* is only caught on the **first diff** (1.3 / 1.4)
   — the standing check then **reconciles it away** (3.1), because legitimacy is
   judged by group name, not membership provenance. So to exercise a
   genuinely-detected "portal" path, use a **direct grant (1.1/2.1)** or a
   **non-IaC group (1.2/2.4)**. This is a real coverage boundary of the control,
   not a bug — but it's the single most important thing to validate and document.
2. **Elevation (Temp→Perm)** is noted in the code as unlikely to fire given the
   SP's permissions, so treat any elevation test as best-effort.
