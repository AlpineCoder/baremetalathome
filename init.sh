#!/bin/bash

oc apply -f ./cluster-certs/registry-config.yaml

oc patch image.config.openshift.io/cluster \
  --type=merge \
  -p '{
    "spec": {
      "additionalTrustedCA": {
        "name": "registry-config"
      }
    }
  }'

sleep 360

oc delete pods -n hypershift --all
