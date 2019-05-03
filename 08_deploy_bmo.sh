#!/usr/bin/bash

set -ex

source logging.sh
#source common.sh
eval "$(go env)"

# Get the latest bits for baremetal-operator
export BMOPATH="$GOPATH/src/github.com/metalkube/baremetal-operator"

# Make a local copy of the baremetal-operator code to make changes
cp -r $BMOPATH/deploy ocp/.
sed -i 's/namespace: .*/namespace: openshift-machine-api/g' ocp/deploy/role_binding.yaml
# FIXME(dhellmann): Use the pre-rename operator until this repo
# works with the renamed version.
# - https://github.com/openshift-metal3/dev-scripts/issues/548
sed -i 's|image: quay.io/metalkube/baremetal-operator$|image: quay.io/metalkube/baremetal-operator:metalkube|' ocp/deploy/operator.yaml

# Kill the dnsmasq container on the host since it is performing DHCP and doesn't
# allow our pod in openshift to take over.
for name in dnsmasq ironic-inspector ; do
    sudo podman ps | grep -w "$name$" && sudo podman stop $name
done

# Start deploying on the new cluster
oc --config ocp/auth/kubeconfig apply -f ocp/deploy/service_account.yaml --namespace=openshift-machine-api
oc --config ocp/auth/kubeconfig apply -f ocp/deploy/role.yaml --namespace=openshift-machine-api
oc --config ocp/auth/kubeconfig apply -f ocp/deploy/role_binding.yaml
oc --config ocp/auth/kubeconfig apply -f ocp/deploy/crds/metal3_v1alpha1_baremetalhost_crd.yaml

oc --config ocp/auth/kubeconfig apply -f ocp/deploy/ironic_bmo_configmap.yaml --namespace=openshift-machine-api
# I'm leaving this as is for debugging but we could easily generate a random password here.
oc --config ocp/auth/kubeconfig delete secret mariadb-password --namespace=openshift-machine-api || true
oc --config ocp/auth/kubeconfig create secret generic mariadb-password --from-literal password=password --namespace=openshift-machine-api

oc --config ocp/auth/kubeconfig adm --as system:admin policy add-scc-to-user privileged system:serviceaccount:openshift-machine-api:baremetal-operator
oc --config ocp/auth/kubeconfig apply -f ocp/deploy/operator_ironic.yaml -n openshift-machine-api

# Workaround for https://github.com/metalkube/cluster-api-provider-baremetal/issues/57
oc --config ocp/auth/kubeconfig scale deployment -n openshift-machine-api machine-api-controllers --replicas=0
while [ ! $(oc --config ocp/auth/kubeconfig get deployment -n openshift-machine-api machine-api-controllers -o json | jq .spec.replicas) ]
do
  echo "Scaling down machine-api-controllers ..."
done
echo "Scaling up machine-api-controllers ..."
oc --config ocp/auth/kubeconfig scale deployment -n openshift-machine-api machine-api-controllers --replicas=1

# Sadly I don't see a way to get this from the json..
POD_NAME=$(oc --config ocp/auth/kubeconfig get pods -n openshift-machine-api | grep metal3-baremetal-operator | cut -f 1 -d ' ')

# Make sure our pod is running.
echo "Waiting for baremetal-operator pod to become ready" | lolcat
while [ $(oc --config ocp/auth/kubeconfig get pod $POD_NAME -n openshift-machine-api -o json | jq .status.phase) != '"Running"' ]
do
  sleep 5
done

echo "Uploading deployment images to ironic-httpd container." | lolcat
oc --config ocp/auth/kubeconfig rsync /opt/dev-scripts/ironic/html/images $POD_NAME:/shared/html/ -c ironic-httpd -n openshift-machine-api
