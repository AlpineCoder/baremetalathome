#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 -v <ocp-version> -b <bastion-host>"
    echo "  -v  OpenShift version (e.g. 4.18.26)"
    echo "  -b  Bastion host (SSH target, e.g. user@192.168.125.1)"
    exit 1
}

while getopts "v:b:" opt; do
    case $opt in
        v) VERSION="$OPTARG" ;;
        b) BASTION="$OPTARG" ;;
        *) usage ;;
    esac
done

[[ -z "${VERSION:-}" || -z "${BASTION:-}" ]] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OVERLAY_DIR="$REPO_DIR/hostedcluster/overlays/$VERSION"
RESOURCES_DIR="$REPO_DIR/hostedcluster/resources"

if [[ ! -d "$OVERLAY_DIR" ]]; then
    echo "Error: no overlay found for version $VERSION at $OVERLAY_DIR"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"

echo "=== [1/15] Creating prereqs ==="
oc apply -f "$RESOURCES_DIR/namespaces.yaml"
oc apply -f "$RESOURCES_DIR/prereqs.yaml"
oc apply -f "$RESOURCES_DIR/rbac.yaml"
oc apply -f "$RESOURCES_DIR/assisted-service-config.yaml"

echo "=== [2/15] Creating HostedCluster and NodePool (version $VERSION) ==="
oc apply -f "$OVERLAY_DIR/hostedcluster.yaml"
oc apply -f "$OVERLAY_DIR/nodepool.yaml"

echo "=== [3/15] Waiting for HostedCluster control plane to become available ==="
oc wait hostedcluster/hosted-ipv4 -n clusters \
    --for=condition=Available \
    --timeout=30m

echo "=== [4/15] Creating worker VM on bastion ==="
# shellcheck disable=SC2029
ssh $SSH_OPTS "$BASTION" \
    "kcli create vm \
        -P start=False \
        -P uefi_legacy=true \
        -P plan=hosted-ipv4 \
        -P memory=16384 \
        -P numcpus=8 \
        -P disks=[200,200] \
        -P nets=['{\"name\": \"ipv4\", \"mac\": \"aa:aa:aa:aa:02:11\"}'] \
        -P uuid=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0211 \
        -P name=hosted-ipv4-worker0"

echo "=== [5/15] Sleeping 12 seconds ==="
sleep 12

echo "=== [6/15] Restarting ksushy on bastion ==="
ssh $SSH_OPTS "$BASTION" "sudo systemctl restart ksushy"

echo "=== [7/15] Creating InfraEnv ==="
oc apply -f "$RESOURCES_DIR/infra-env.yaml"

echo "=== [8/15] Creating BareMetalHost ==="
oc apply -f "$RESOURCES_DIR/baremetal.yaml"

echo "=== [9/15] Waiting for BareMetalHost to be provisioned ==="
echo "This may take several minutes..."
until [[ "$(oc get baremetalhost hosted-ipv4-worker0 -n clusters-hosted-ipv4 \
    -o jsonpath='{.status.provisioning.state}' 2>/dev/null)" == "provisioned" ]]; do
    state="$(oc get baremetalhost hosted-ipv4-worker0 -n clusters-hosted-ipv4 \
        -o jsonpath='{.status.provisioning.state}' 2>/dev/null || echo 'unknown')"
    echo "  BMH state: $state — waiting 30s..."
    sleep 30
done
echo "BareMetalHost is provisioned."

echo "=== [10/15] Scaling NodePool to 1 ==="
oc patch nodepool hosted-ipv4 -n clusters \
    --type merge \
    -p '{"spec":{"replicas":1}}'

echo "=== [11/15] Waiting for guest cluster login to become available ==="
KUBECONFIG_SECRET="$(oc get hostedcluster hosted-ipv4 -n clusters -o jsonpath='{.status.kubeconfig.name}')"
GUEST_KUBECONFIG="$(mktemp)"
trap 'rm -f "$GUEST_KUBECONFIG"' EXIT

until oc extract "secret/$KUBECONFIG_SECRET" -n clusters --to=- --keys=kubeconfig \
    > "$GUEST_KUBECONFIG" 2>/dev/null \
    && oc --kubeconfig="$GUEST_KUBECONFIG" get clusterversion &>/dev/null; do
    echo "  Guest cluster not reachable yet — waiting 15s..."
    sleep 15
done
echo "Login to guest cluster is possible."

echo "=== [12/15] Waiting for the cluster and its operators to become available ==="
oc --kubeconfig="$GUEST_KUBECONFIG" wait clusterversion/version \
    --for=condition=Available=True \
    --timeout=30m

echo "=== [13/15] Disabling default CatalogSources ==="
oc --kubeconfig="$GUEST_KUBECONFIG" patch operatorhub cluster \
    --type merge \
    -p '{"spec":{"disableAllDefaultSources":true}}'

echo "=== [14/15] Force-deleting terminating pods in openshift-marketplace ==="
sleep 10
terminating_pods="$(oc --kubeconfig="$GUEST_KUBECONFIG" get pods -n openshift-marketplace \
    --no-headers 2>/dev/null | awk '$3=="Terminating" {print $1}')"
if [[ -n "$terminating_pods" ]]; then
    for pod in $terminating_pods; do
        echo "  Force-deleting pod $pod"
        oc --kubeconfig="$GUEST_KUBECONFIG" delete pod "$pod" -n openshift-marketplace \
            --grace-period=0 --force
    done
else
    echo "  No terminating pods found."
fi

echo "=== [15/15] Restarting crio on the NodePool node ==="
NODE_IP="$(oc --kubeconfig="$GUEST_KUBECONFIG" get nodes -o wide --no-headers | awk 'NR==1 {print $6}')"
# shellcheck disable=SC2029
ssh $SSH_OPTS core@"$NODE_IP" "sudo systemctl restart crio"

echo ""
echo "Cluster $VERSION deployment complete."
