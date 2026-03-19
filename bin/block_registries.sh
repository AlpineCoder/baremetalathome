#!/bin/bash

# Define the registries used by OpenShift
REGISTRIES=("quay.io" "registry.redhat.io" "gcr.io" "registry.access.redhat.com" "docker.io")
BRIDGE_INT="ipv4" # Change this if your KVM bridge has a different name

function block() {
    echo "Enabling DISCONNECTED mode..."
    for reg in "${REGISTRIES[@]}"; do
        echo "Blocking $reg..."
        # We use -I to insert at the top of the chain to ensure it overrides ALLOW rules
        sudo iptables -I FORWARD -d $reg -p tcp --dport 443 -j DROP
    done
    echo "Traffic to registries is now blocked."
}

function unblock() {
    echo "Disabling DISCONNECTED mode (restoring access)..."
    for reg in "${REGISTRIES[@]}"; do
        echo "Allowing $reg..."
        # -D deletes the specific rule
        sudo iptables -D FORWARD -d $reg -p tcp --dport 443 -j DROP 2>/dev/null
    done
    echo "Access restored."
}

case "$1" in
    enable)
        block
        ;;
    disable)
        unblock
        ;;
    status)
        sudo iptables -L FORWARD -n -v | grep -E "DROP.*(443)"
        ;;
    *)
        echo "Usage: $0 {enable|disable|status}"
        exit 1
esac