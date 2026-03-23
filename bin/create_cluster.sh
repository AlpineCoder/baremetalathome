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

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes"

echo "=== [1/9] Creating prereqs ==="
oc apply -f "$RESOURCES_DIR/namespaces.yaml"
oc apply -f "$RESOURCES_DIR/prereqs.yaml"
oc apply -f "$RESOURCES_DIR/rbac.yaml"
oc apply -f "$RESOURCES_DIR/assisted-service-config.yaml"

echo "=== [2/9] Creating HostedCluster and NodePool (version $VERSION) ==="
oc apply -f "$OVERLAY_DIR/hostedcluster.yaml"
oc apply -f "$OVERLAY_DIR/nodepool.yaml"

echo "=== [3/9] Waiting for HostedCluster control plane to become available ==="
oc wait hostedcluster/hosted-ipv4 -n clusters \
    --for=condition=Available \
    --timeout=30m

echo "=== [4/9] Creating worker VM on bastion ==="
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

echo "=== [5/9] Sleeping 12 seconds ==="
sleep 12

echo "=== [6/9] Restarting ksushy on bastion ==="
ssh $SSH_OPTS "$BASTION" "sudo systemctl restart ksushy"

echo "=== [7/9] Creating InfraEnv ==="
oc apply -f "$RESOURCES_DIR/infra-env.yaml"

echo "=== [8/9] Creating BareMetalHost ==="
oc apply -f "$RESOURCES_DIR/baremetal.yaml"

echo "=== [8/9] Waiting for BareMetalHost to be provisioned ==="
echo "This may take several minutes..."
until [[ "$(oc get baremetalhost hosted-ipv4-worker0 -n clusters-hosted-ipv4 \
    -o jsonpath='{.status.provisioning.state}' 2>/dev/null)" == "provisioned" ]]; do
    state="$(oc get baremetalhost hosted-ipv4-worker0 -n clusters-hosted-ipv4 \
        -o jsonpath='{.status.provisioning.state}' 2>/dev/null || echo 'unknown')"
    echo "  BMH state: $state — waiting 30s..."
    sleep 30
done
echo "BareMetalHost is provisioned."

echo "=== [9/9] Scaling NodePool to 1 ==="
oc patch nodepool hosted-ipv4 -n clusters \
    --type merge \
    -p '{"spec":{"replicas":1}}'

echo ""
echo "Cluster $VERSION deployment complete."
