# todo TO BE REVIEWED BY A HUMAN
# todo
#!/usr/bin/env bash
#
# extract-iac-groups.sh
#
# Emit (one display name per line, on stdout) the set of Entra security-group
# display names that are provisioned or governed by Infrastructure-as-Code,
# unioned across the HMCTS governance repositories:
#
#   * azure-access           - per-user group memberships + declared groups
#   * azure-access-packages  - access-package catalogs & packages (the groups
#                              granted when an access package is activated)
#   * azure-enterprise       - terraform-provisioned management-group,
#                              subscription and environment groups, including
#                              the PIM "Eligible" groups
#
# The output is intended to be passed to rbac-change-monitor.sh via one or more
# --iacGroupsFile arguments. A privileged group that is NOT present in this set,
# yet holds a standing RBAC assignment, is a remediation target and is flagged
# red by the monitor's standing-privilege check.
#
# Repo locations default to sibling checkouts under $HOME/Git but can each be
# overridden via environment variables for CI checkout paths.
set -euo pipefail

ACCESS_DIR="${AZURE_ACCESS_DIR:-$HOME/Git/azure-access}"
PACKAGES_DIR="${AZURE_ACCESS_PACKAGES_DIR:-$HOME/Git/azure-access-packages}"
ENTERPRISE_DIR="${AZURE_ENTERPRISE_DIR:-$HOME/Git/azure-enterprise}"

emit() { printf '%s\n' "$@"; }

extract() {
  # --- azure-access -------------------------------------------------------
  # Group memberships declared per user ("  - <Group Name>") and the groups
  # declared in groups.yml ("  - name: <Group Name>").
  if [ -d "$ACCESS_DIR" ]; then
    grep -hE '^  - ' "$ACCESS_DIR/users/prod_users.yml" 2>/dev/null \
      | sed -E 's/^  - //' || true
    grep -hE '^  - name:' "$ACCESS_DIR/users/groups.yml" 2>/dev/null \
      | sed -E 's/^  - name:[[:space:]]*//' || true
  fi

  # --- azure-access-packages ----------------------------------------------
  # Quoted "DTS ..." group names referenced as catalog resources and package
  # resource_roles (these are the groups granted on access-package activation).
  if [ -d "$PACKAGES_DIR" ]; then
    grep -rhoE '"DTS [^"]+"' \
      "$PACKAGES_DIR/entitlement-catalogs.yml" \
      "$PACKAGES_DIR/entitlement-packages.yml" 2>/dev/null \
      | sed -E 's/^"//; s/"$//' || true
  fi

  # --- azure-enterprise ---------------------------------------------------
  # Terraform provisions group display names by interpolating a fixed set of
  # group "types" over the management-group ids, subscription names and
  # environment names declared in the prod component/tfvars. Expand them here.
  if [ -d "$ENTERPRISE_DIR" ]; then
    local ent="$ENTERPRISE_DIR"
    local enterprise_tf="$ent/components/enterprise/enterprise.tf"
    local env_locals="$ent/components/enterprise/locals.tf"
    local prod_tfvars="$ent/environments/prod/prod.tfvars"

    # Per-management-group groups (modules/management-group-bootstrap/*.tf,
    # each "for_each = var.groups" -> "<type> (mg:<id>)").
    local mg_types=(
      "DTS Owners"
      "DTS Contributors"
      "DTS Readers"
      "DTS Reservation Purchaser"
      "DTS Security Admins"
      "DTS Security Readers"
      "DTS Storage Blob Data Contributor"
      "DTS User Access Administrators"
    )
    # Per-subscription groups (modules/subscription/locals.tf, name lower-cased).
    local sub_types=(
      "DTS AKS Administrators"
      "DTS AKS Users"
      "DTS Contributors"
      "DTS Key Vault Administrators"
      "DTS Readers"
      "DTS Security Readers"
      "DTS Blob Readers"
      "DTS Owners"
      "DTS Contributors Eligible"
      "DTS Owners Eligible"
    )

    # management-group ids = keys of the management_groups map (4-space indent).
    local mg_ids=""
    if [ -f "$enterprise_tf" ]; then
      mg_ids=$(grep -E '^    [A-Za-z][A-Za-z0-9-]* = \{' "$enterprise_tf" 2>/dev/null \
               | sed -E 's/^    ([A-Za-z0-9-]+) = \{.*/\1/' || true)
    fi
    local id t
    for id in $mg_ids; do
      for t in "${mg_types[@]}"; do emit "$t (mg:$id)"; done
    done

    # subscription names = keys under the *_subscriptions blocks (2-space
    # indent, optionally quoted). Group name uses the lower-cased name.
    local sub_names=""
    if [ -f "$prod_tfvars" ]; then
      sub_names=$(grep -E '^  ([A-Za-z0-9][A-Za-z0-9._-]*|"[^"]+") = \{' "$prod_tfvars" 2>/dev/null \
                  | sed -E 's/^  //; s/ = \{.*//; s/^"//; s/"$//; s/[[:space:]]+$//' || true)
    fi
    local sname lname
    while IFS= read -r sname; do
      [ -n "$sname" ] || continue
      lname=$(printf '%s' "$sname" | tr '[:upper:]' '[:lower:]')
      for t in "${sub_types[@]}"; do emit "$t (sub:$lname)"; done
    done <<< "$sub_names"

    # environment groups (modules/environments/locals.tf -> "(env:<env>)").
    local env_ids=""
    if [ -f "$env_locals" ]; then
      env_ids=$(grep -E '^    [a-z][a-z0-9]* *= \{' "$env_locals" 2>/dev/null \
                | sed -E 's/^    ([a-z0-9]+) *= \{.*/\1/' || true)
    fi
    local e
    for e in $env_ids mgmt; do
      emit "DTS Operations (env:$e)"
      emit "DTS Public DNS Contributor (env:$e)"
    done

    # Static groups created or referenced by IaC.
    emit "DTS Global Admins"
    emit "DTS Global Admins Eligible"
    emit "DTS ACR Access Administrators"
  fi
}

extract | sed -E 's/[[:space:]]+$//' | grep -vE '^[[:space:]]*$' | sort -u
