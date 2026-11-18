#!/bin/bash

# Removes everything the
# "Managing Secrets with the External Secrets Operator on OpenShift" workshop
# installs, whether or not the learner ran the optional cleanup in Module 3:
#   - the secrets-demo project (sample app, SecretStore, ExternalSecret)
#   - the Module 4 resources (ClusterExternalSecret, ClusterSecretStore, and the
#     secrets-platform, tenant-a, and tenant-b projects)
#   - the External Secrets Operator for Red Hat OpenShift, its components and CRDs
#   - HashiCorp Vault (Helm release, namespace, cluster role binding)
#   - the lab guide application and the OpenShift Web Terminal operator
#     (installed by prepare-cluster.sh)

set -euo pipefail

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
echo "WARNING: This will delete the workshop projects (secrets-demo, secrets-platform, tenant-a, tenant-b,"
echo "vault, external-secrets, external-secrets-operator, lab-guide), uninstall the External Secrets Operator including its CRDs,"
echo "and uninstall the Web Terminal operator."
echo "Any ExternalSecret or SecretStore elsewhere on the cluster will be deleted with the CRDs."
read -rp "Are you sure? (y/N): " CONFIRM
if [[ "$CONFIRM" != [yY] ]]; then
  echo "Aborted."
  exit 0
fi

echo
echo "Cleaning up cluster..."
echo

# Workshop projects and cluster-scoped workshop resources
# ------------------------------------------------------------------------------------
# Delete while the ESO controller still runs, so ESO-owned resources are finalized cleanly
echo "=== Removing the Module 4 cluster-scoped resources ==="
if oc get crd clusterexternalsecrets.external-secrets.io &>/dev/null; then
  oc delete clusterexternalsecret api-credentials --ignore-not-found
fi
if oc get crd clustersecretstores.external-secrets.io &>/dev/null; then
  oc delete clustersecretstore vault-shared --ignore-not-found
fi
echo

echo "=== Removing the workshop projects ==="
oc delete project secrets-demo secrets-platform tenant-a tenant-b --ignore-not-found
oc wait --for=delete namespace/secrets-demo namespace/secrets-platform namespace/tenant-a namespace/tenant-b \
  --timeout=180s 2>/dev/null || true
echo

# External Secrets Operator for Red Hat OpenShift
# ------------------------------------------------------------------------------------
echo "=== Uninstalling the External Secrets Operator for Red Hat OpenShift ==="

# Remove the operand (core controller, webhook, cert controller) first
if oc get externalsecretsconfigs.operator.openshift.io cluster &>/dev/null; then
  oc delete externalsecretsconfigs.operator.openshift.io cluster --wait
  echo "ExternalSecretsConfig 'cluster' removed."
else
  echo "No ExternalSecretsConfig found, skipping."
fi

# Delete the subscription and the CSV (uninstalling the operator does not remove the operand resources)
oc delete subscription openshift-external-secrets-operator -n external-secrets-operator --ignore-not-found
CSV=$(oc get csv -n external-secrets-operator -o name 2>/dev/null | grep external-secrets-operator || true)
if [ -n "$CSV" ]; then
  oc delete $CSV -n external-secrets-operator
  echo "External Secrets Operator removed."
else
  echo "No External Secrets Operator CSV found, skipping."
fi

oc delete project external-secrets external-secrets-operator --ignore-not-found
oc wait --for=delete namespace/external-secrets namespace/external-secrets-operator --timeout=180s 2>/dev/null || true

# Remove leftover webhook configurations of the operand
WEBHOOKS=$(oc get validatingwebhookconfigurations -o name 2>/dev/null | grep -E 'secretstore-validate|externalsecret-validate' || true)
if [ -n "$WEBHOOKS" ]; then
  oc delete $WEBHOOKS
fi

# Remove leftover cluster roles and bindings of the operand
RBAC=$(oc get clusterroles,clusterrolebindings -o name 2>/dev/null | grep -E '/external-secrets' || true)
if [ -n "$RBAC" ]; then
  oc delete $RBAC
fi

# Remove the CRDs (external-secrets.io API group and the operator's own API)
CRDS=$(oc get customresourcedefinitions.apiextensions.k8s.io -o name 2>/dev/null \
  | grep -E '\.external-secrets\.io$|/externalsecrets(config|manager)s\.operator\.openshift\.io$' || true)
if [ -n "$CRDS" ]; then
  oc delete $CRDS
  echo "External Secrets Operator CRDs removed."
else
  echo "No External Secrets Operator CRDs found, skipping."
fi
echo

# HashiCorp Vault
# ------------------------------------------------------------------------------------
echo "=== Uninstalling HashiCorp Vault ==="
if command -v helm &>/dev/null && helm status vault -n vault &>/dev/null; then
  helm uninstall vault -n vault
else
  echo "Helm release 'vault' not found (or helm not installed), deleting resources directly."
fi
# The cluster role binding is cluster-scoped and survives a namespace deletion
oc delete clusterrolebinding vault-server-binding --ignore-not-found
oc delete project vault --ignore-not-found
echo

# Delete the lab guide application
# ------------------------------------------------------------------------------------
echo "=== Removing the lab-guide project ==="
oc delete project lab-guide --ignore-not-found
echo

# Uninstall the Web Terminal operator
# ------------------------------------------------------------------------------------
echo "=== Uninstalling OpenShift Web Terminal Operator ==="

# Delete the subscription
oc delete subscription web-terminal -n openshift-operators --ignore-not-found

# Delete the CSV for Web Terminal (the installed operator)
CSV=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep web-terminal || true)
if [ -n "$CSV" ]; then
  oc delete $CSV -n openshift-operators
  echo "Web Terminal operator removed."
else
  echo "No Web Terminal operator CSV found, skipping."
fi

# Remove the DevWorkspace custom resources used by the Operator, along with any related Kubernetes objects
if oc get crd devworkspaces.workspace.devfile.io &>/dev/null; then
  oc delete devworkspaces.workspace.devfile.io --all-namespaces --all --wait
fi
if oc get crd devworkspaceroutings.controller.devfile.io &>/dev/null; then
  oc delete devworkspaceroutings.controller.devfile.io --all-namespaces --all --wait
fi

# Delete the subscription for the DevWorkspace operator
SUBSCRIPTION=$(oc get subscription -n openshift-operators -o name 2>/dev/null | grep devworkspace || true)
if [ -n "$SUBSCRIPTION" ]; then
  oc delete $SUBSCRIPTION -n openshift-operators
  echo "DevWorkspace operator subscription removed."
else
  echo "No DevWorkspace operator subscription found, skipping."
fi

# Delete the CSV for DevWorkspace (the installed operator)
CSV=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep devworkspace || true)
if [ -n "$CSV" ]; then
  oc delete $CSV -n openshift-operators
  echo "DevWorkspace operator removed."
else
  echo "No DevWorkspace operator CSV found, skipping."
fi

# Remove the CRDs used by the Operator
oc delete customresourcedefinitions.apiextensions.k8s.io --ignore-not-found \
  devworkspaceroutings.controller.devfile.io \
  devworkspaces.workspace.devfile.io \
  devworkspacetemplates.workspace.devfile.io \
  devworkspaceoperatorconfigs.controller.devfile.io

# Remove the devworkspace-webhook-server deployment, mutating, and validating webhooks
oc delete deployment/devworkspace-webhook-server -n openshift-operators --ignore-not-found
oc delete mutatingwebhookconfigurations controller.devfile.io --ignore-not-found
oc delete validatingwebhookconfigurations controller.devfile.io --ignore-not-found

# Remove any remaining services, secrets, and config maps
oc delete all --selector app.kubernetes.io/part-of=devworkspace-operator,app.kubernetes.io/name=devworkspace-webhook-server -n openshift-operators
oc delete serviceaccounts devworkspace-webhook-server -n openshift-operators --ignore-not-found
oc delete clusterrole devworkspace-webhook-server --ignore-not-found
oc delete clusterrolebinding devworkspace-webhook-server --ignore-not-found

echo
echo "============================================"
echo "Cluster cleanup complete!"
echo "Removed the workshop projects, the Module 4 cluster-scoped resources, the lab guide,"
echo "HashiCorp Vault, and the External Secrets Operator."
echo "Web Terminal operator has been uninstalled."
echo "============================================"
