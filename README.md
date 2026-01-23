# Instructions

You can follow https://hypershift.pages.dev/labs/ if you are OK with simulated bare metal nodes. Be aware that it is compute intensive.
To get it to work I've set up a compact cluster with 48 GiB memory, 8 vCPUs and 300 GiB disk in total.

# Attention!!

## HyperShift Operator
After step https://hypershift.pages.dev/labs/IPv4/tls-certificates/ you must restart the hypershift operator pods!!! Otherwise your HostedCluster
will not find the CA certificate for your registry!

```bash
oc delete pods --all -nhypershift
```

## Ksushy

Create a proper service for ksushy in /etc/systemd/system/ksushy.service

```text
[Unit]
Description=Ksushy emulator service
After=syslog.target
[Service]
Type=simple
ExecStart=/usr/bin/ksushy
StandardOutput=journal
StandardError=journal
Environment=HOME=/home/zimmerro
Environment=PYTHONUNBUFFERED=true
Environment=KSUSHY_LISTEN_PORT=9000
Environment=KSUSHY_DEBUG=true

[Install]
```

# Simulate Nodes

Depending on how much compute you have, you can actually create 3 Nodes.

```
kcli create vm -P start=False -P uefi_legacy=true -P plan=hosted-ipv4 -P memory=16384 -P numcpus=8 -P disks=[200,200] -P nets=["{\"name\": \"ipv4\", \"mac\": \"aa:aa:aa:aa:02:11\"}"] -P uuid=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0211 -P name=hosted-ipv4-worker0
kcli create vm -P start=False -P uefi_legacy=true -P plan=hosted-ipv4 -P memory=16384 -P numcpus=8 -P disks=[200,200] -P nets=["{\"name\": \"ipv4\", \"mac\": \"aa:aa:aa:aa:02:12\"}"] -P uuid=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0212 -P name=hosted-ipv4-worker1
kcli create vm -P start=False -P uefi_legacy=true -P plan=hosted-ipv4 -P memory=16384 -P numcpus=8 -P disks=[200,200] -P nets=["{\"name\": \"ipv4\", \"mac\": \"aa:aa:aa:aa:02:13\"}"] -P uuid=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0213 -P name=hosted-ipv4-worker2

sleep 2

sudo systemctl restart ksushy
```
