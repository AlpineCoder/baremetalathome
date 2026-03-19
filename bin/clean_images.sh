#!/usr/bin/env bash
set -euo pipefail

nodes=$(oc get nodes -o wide --no-headers | awk '{print $6}')

for node_ip in $nodes; do
    echo "Pruning images on ${node_ip}..."
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes core@"${node_ip}" \
        "sudo crictl rmi --prune"
    echo "Done with ${node_ip}"
done
