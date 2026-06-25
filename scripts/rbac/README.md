# Privileged RBAC change monitoring

This folder implements continuous detection of privileged Azure RBAC drift by
comparing timestamped snapshots and reconciling standing privilege against
Infrastructure-as-Code (IaC) declarations. The guiding principle is an inverted
baseline: **anything that is not declared in IaC (or explicitly allowlisted) is
red-flagged**, so a manually granted elevation cannot "age out" of alerting and
poison the baseline.


# items of concern
roles need to be monitored - definition of priv admin roles goes by perms not by rolename, if a new priv role is released which we haven't got on the audit list - this is a blindspot
role scope not covered (if you grant reader role owner across the estate )
api permissions not covered
service principals /managed identities not covered

# intended functionality
all assignments to permissive groups should be done in iac via azure access
should alert for users who activate access package repeatedly for monitoring purposes
script only monitors human users and short term permission scope creep

script should update it's source of truth from azure-access
allow list only for covering break glass accounts
investigate list for the DCD /ancient groups that need looking at

holistic monitoring via access reviews, azgovviz and service principals + other posture monitoring is still required

## Components

### `extract-iac-groups.sh`
Emits (one display name per line on stdout) the set of Entra security-group
display names that are provisioned or governed by IaC, unioned across three
HMCTS governance repositories — the **three sources of truth**:

| Source repo | What is extracted |
| --- | --- |
| `azure-access` | Per-user group memberships (`users/prod_users.yml`) and declared groups (`users/groups.yml`). |
| `azure-access-packages` | Quoted `"DTS ..."` groups referenced as catalog resources / package `resource_roles` — the groups granted on access-package activation (`entitlement-catalogs.yml`, `entitlement-packages.yml`). |
| `azure-enterprise` | Terraform-provisioned groups, expanded by interpolating a fixed set of group *types* (Owners, Contributors, Readers, AKS Admins, Key Vault Admins, PIM "Eligible", etc.) over the management-group ids, subscription names and environment names declared in the prod component/tfvars. Plus static IaC-created groups (e.g. `DTS Global Admins`). |

Repo locations default to sibling checkouts under `$HOME/Git` and can be
overridden per-repo via `AZURE_ACCESS_DIR`, `AZURE_ACCESS_PACKAGES_DIR` and
`AZURE_ENTERPRISE_DIR` for CI checkout paths. Output is `sort -u`'d and intended
to be passed to the monitor via one or more `--iacGroupsFile` arguments.

### `rbac-change-monitor.sh`
Compares two privileged-RBAC snapshot CSVs (produced by
`audit-privileged-rbac*.sh`) over a window (default **2 days**) and writes a
Slack-ready report using the shared marker convention:

| Marker | Meaning |
| --- | --- |
| `:red_circle:` | New Permanent privileged assignment, any added Owner / User Access Administrator, or a Temporary → Permanent elevation. |
| `:yellow_circle:` | Other added / removed / changed assignments. |
| `:white_check_mark:` | Allowlisted principal self-adding / self-elevating (informational only; never triggers a notification on its own). |

Snapshot resolution relies on the filenames being sortable UTC timestamps, with
a `.meta.json` coverage manifest sitting beside each CSV so a genuinely
shrunken snapshot can be told apart from an incomplete audit (coverage
loss/gain is surfaced as its own alert rather than a flood of bogus
adds/removals).

## The standing-privilege check (`--standingPrivilegeCheck`)

A plain snapshot diff only sees **transitions**. A privileged grant left in
place long enough ages into the baseline and becomes invisible — a malicious
self-elevation would normalise and stop alerting, poisoning the baseline.

With `--standingPrivilegeCheck` enabled, the monitor re-derives from the
**current** snapshot every red-role assignment that has **persisted across the
window** (present in the baseline too) and is **neither allowlisted nor
legitimised by IaC**, and re-alerts on it every run until it is removed or
explicitly approved.

Legitimacy is decided by Terraform IaC: an assignment inherited from an
IaC-declared group is treated as managed/approved; a direct assignment is not
recognisable as IaC-managed from the group-name source and so must be
allowlisted if legitimate. Service principals and managed identities are
excluded (governed by platform Terraform elsewhere).

Coverage is continuous and non-overlapping:

- the diff covers a grant's **first** window (NEW / ADDED), and
- the standing check covers it from the **second** window onward,

so the two checks never double-report.

## Typical invocation

```bash
# 1. Build the IaC-managed group allowlist from the three sources of truth.
./extract-iac-groups.sh > /tmp/iac-groups.txt

# 2. Compare the two newest snapshots in the current dir, with the inverted
#    "not-in-IaC is red" standing-privilege baseline enabled.
./rbac-change-monitor.sh \
  --currentDir . \
  --iacGroupsFile /tmp/iac-groups.txt \
  --standingPrivilegeCheck \
  -o rbac-change-status.txt
```
