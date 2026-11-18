#!/bin/bash

# Prepares an OpenShift cluster for the
# "Managing Secrets with the External Secrets Operator on OpenShift" workshop.
#
# The workshop is admin-only and uses fixed, cluster-wide names (vault,
# external-secrets-operator, external-secrets, secrets-demo, secrets-platform,
# tenant-a, tenant-b), so one cluster serves one learner. Learners install Vault and the External Secrets Operator
# themselves; this script installs the Web Terminal operator, deploys the lab
# guide, and checks that nothing on the cluster would get in the way.
#
# Optional: export LAB_GUIDE_URL=https://mostmark.github.io/external-secrets-operator-workshop to use an
# externally hosted lab guide (for example GitHub Pages) instead of deploying the
# lab guide container to the cluster.

set -euo pipefail

EXPECTED_OCP_MINOR="4.22"
WARNINGS=0

warn() {
  echo "WARNING: $*"
  WARNINGS=$((WARNINGS + 1))
}

# Check that oc CLI is available
if ! command -v oc &>/dev/null; then
  echo "Error: 'oc' CLI not found. Please install it first."
  exit 1
fi

# Check that user is logged in
if ! oc whoami &>/dev/null; then
  echo "Error: Not logged in to OpenShift. Please run 'oc login' first."
  exit 1
fi

echo "Logged in as: $(oc whoami)"
echo "Server: $(oc whoami --show-server)"
echo

# Check that the user is a cluster administrator
if [ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" != "yes" ]; then
  echo "Error: You need cluster-admin privileges to prepare the cluster."
  exit 1
fi

# Pre-flight checks
# ------------------------------------------------------------------------------------
echo "=== Running pre-flight checks ==="

# OpenShift version
OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
case "$OCP_VERSION" in
  "$EXPECTED_OCP_MINOR".*) echo "OpenShift version: $OCP_VERSION" ;;
  *) warn "OpenShift version is $OCP_VERSION. The workshop is written for $EXPECTED_OCP_MINOR." ;;
esac

# The Red Hat External Secrets Operator must be available in the catalog
if oc get packagemanifest openshift-external-secrets-operator -n openshift-marketplace &>/dev/null; then
  echo "External Secrets Operator for Red Hat OpenShift is available in the catalog."
else
  warn "Package 'openshift-external-secrets-operator' not found in openshift-marketplace. Learners cannot install the operator."
fi

# Only one External Secrets Operator may run per cluster
OTHER_ESO_SUBS=$(oc get subscriptions.operators.coreos.com -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{.spec.name}{"\n"}{end}' 2>/dev/null \
  | awk '$2 ~ /external-secrets/ && $2 != "openshift-external-secrets-operator" {print $1}' || true)
if [ -n "$OTHER_ESO_SUBS" ]; then
  warn "Another External Secrets Operator subscription exists: $OTHER_ESO_SUBS. Uninstall it before the workshop."
fi

# Leftovers from a previous run
for NS in vault external-secrets-operator external-secrets secrets-demo secrets-platform tenant-a tenant-b; do
  if oc get namespace "$NS" &>/dev/null; then
    warn "Namespace '$NS' already exists. A previous workshop run may still be installed."
  fi
done
if oc get externalsecretsconfigs.operator.openshift.io cluster &>/dev/null; then
  warn "ExternalSecretsConfig 'cluster' already exists. A previous workshop run may still be installed."
fi

# External content the workshop downloads (not verified automatically)
echo "The workshop needs outbound access to:"
echo "  - helm.releases.hashicorp.com  (Vault Helm chart, fetched from the Web Terminal)"
echo "  - docker.io/hashicorp/vault    (Vault server image)"
echo "  - registry.access.redhat.com   (ubi9/python-312 sample application image)"
echo "In a disconnected cluster, mirror these before the workshop."
echo
# ------------------------------------------------------------------------------------

# Install the Web Terminal operator
# ------------------------------------------------------------------------------------
echo "=== Installing OpenShift Web Terminal Operator ==="
if oc get subscription web-terminal -n openshift-operators &>/dev/null; then
  echo "Web Terminal operator subscription already exists, skipping."
else
  oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: web-terminal
  namespace: openshift-operators
spec:
  channel: fast
  installPlanApproval: Automatic
  name: web-terminal
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  echo "Web Terminal operator subscription created."
  echo "Waiting for operator to install (up to 10 minutes)..."
  for attempt in $(seq 1 60); do
    PHASE=$(oc get csv -n openshift-operators -l operators.coreos.com/web-terminal.openshift-operators= \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [ "$PHASE" = "Succeeded" ]; then
      echo "Web Terminal operator installed successfully."
      break
    fi
    if [ "$attempt" -eq 60 ]; then
      warn "Timed out waiting for the Web Terminal operator. It may still be installing."
    fi
    sleep 10
  done
fi
echo
# ------------------------------------------------------------------------------------

# Deployment of the lab guide
# ------------------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -n "${LAB_GUIDE_URL:-}" ]; then
  echo "=== Lab guide ==="
  echo "LAB_GUIDE_URL is set, skipping the lab guide deployment."
else
  echo "=== Deploying the lab guide application ==="
  oc create namespace lab-guide --dry-run=client -o yaml | oc apply -f -
  oc apply -f "$SCRIPT_DIR/lab-guide-app/"
  if ! oc rollout status deployment/lab-guide -n lab-guide --timeout=300s; then
    warn "The lab guide deployment is not ready. Check 'oc get pods -n lab-guide'."
  fi
  LAB_GUIDE_URL="https://$(oc get route doc -n lab-guide -o jsonpath='{.spec.host}')"
fi
echo
# ------------------------------------------------------------------------------------

# Lab guide URL
# ------------------------------------------------------------------------------------
CONSOLE_HOST=$(oc whoami --show-console 2>/dev/null | sed -e 's#^https://##' -e 's#/$##')
API_HOST=$(oc whoami --show-server | sed -e 's#^https://##' -e 's#/$##')

echo "============================================"
if [ "$WARNINGS" -eq 0 ]; then
  echo "Cluster preparation complete!"
else
  echo "Cluster preparation finished with $WARNINGS warning(s). Review them above."
fi
echo "Learners need a user with cluster-admin privileges."
echo "The lab guide can be accessed at the following url:"
echo "${LAB_GUIDE_URL}?OPENSHIFT_USERNAME={username}&OPENSHIFT_PASSWORD={openshift_password}&OPENSHIFT_CONSOLE_URL=${CONSOLE_HOST}&OPENSHIFT_API_URL=${API_HOST}"
echo "============================================"
