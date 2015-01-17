#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# A library of helper functions for deploying on Openstack

# Use the config file specified in $KUBE_CONFIG_FILE, or default to
# config-default.sh.
KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
source $(dirname ${BASH_SOURCE})/${KUBE_CONFIG_FILE-"config-default.sh"}

verify-prereqs() {
  # Make sure that prerequisites are installed.
  for x in nova swift neutron; do
    if [ "$(which $x)" == "" ]; then
      echo "cluster/openstack/util.sh:  Can't find $x in PATH, please fix and retry."
      exit 1
    fi
  done

  if [[ -z "${OS_AUTH_URL-}" ]]; then
    echo "cluster/openstack/util.sh: OS_AUTH_URL not set."
    echo -e "\texport OS_AUTH_URL=https://identity.api.openstackcloud.com/v2.0/"
    return 1
  fi

  if [[ -z "${OS_USERNAME-}" ]]; then
    echo "cluster/openstack/util.sh: OS_USERNAME not set."
    echo -e "\texport OS_USERNAME=myusername"
    return 1
  fi

  if [[ -z "${OS_PASSWORD-}" ]]; then
    echo "cluster/openstack/util.sh: OS_PASSWORD not set."
    echo -e "\texport OS_PASSWORD=myapikey"
    return 1
  fi

  if [[ -z "${OS_TENANT_ID-}" ]]; then
    echo "cluster/openstack/util.sh: OS_TENANT_ID not set."
    echo -e "\texport OS_TENANT_ID=50520682209898"
    return 1
  fi

  if [[ -z "${OS_TENANT_NAME-}" ]]; then
    echo "cluster/openstack/util.sh: OS_TENANT_NAME not set."
    echo -e "\texport OS_TENANT_NAME=Sample-project"
    return 1
  fi

  if [[ -z "${OS_REGION_NAME-}" ]]; then
    echo "cluster/openstack/util.sh: OS_REGION_NAME not set."
    echo -e "\texport OS_REGION_NAME=region-b.geo-1"
    return 1
  fi
}

# Ensure that we have a password created for validating to the master.  Will
# read from $HOME/.kubernetres_auth if available.
#
# Vars set:
#   KUBE_USER
#   KUBE_PASSWORD
get-password() {
  local file="$HOME/.kubernetes_auth"
  if [[ -r "$file" ]]; then
    KUBE_USER=$(cat "$file" | python -c 'import json,sys;print json.load(sys.stdin)["User"]')
    KUBE_PASSWORD=$(cat "$file" | python -c 'import json,sys;print json.load(sys.stdin)["Password"]')
    return
  fi
  KUBE_USER=admin
  KUBE_PASSWORD=$(python -c 'import string,random; print "".join(random.SystemRandom().choice(string.ascii_letters + string.digits) for _ in range(16))')

  # Store password for reuse.
  cat << EOF > "$file"
{
  "User": "$KUBE_USER",
  "Password": "$KUBE_PASSWORD"
}
EOF
  chmod 0600 "$file"
}

openstack-ssh-key() {
  if [ ! -f $HOME/.ssh/${SSH_KEY_NAME} ]; then
    echo "cluster/openstack/util.sh: Generating SSH KEY ${HOME}/.ssh/${SSH_KEY_NAME}"
    ssh-keygen -f ${HOME}/.ssh/${SSH_KEY_NAME} -N '' > /dev/null
  fi

  if ! $(nova keypair-list | grep $SSH_KEY_NAME > /dev/null 2>&1); then
    echo "cluster/openstack/util.sh: Uploading key to openstack:"
    echo -e "\tnova keypair-add ${SSH_KEY_NAME} --pub-key ${HOME}/.ssh/${SSH_KEY_NAME}.pub"
    nova keypair-add ${SSH_KEY_NAME} --pub-key ${HOME}/.ssh/${SSH_KEY_NAME}.pub > /dev/null 2>&1
  else
    echo "cluster/openstack/util.sh: SSH key ${SSH_KEY_NAME}.pub already uploaded"
  fi
}

find-release-tars() {
  SERVER_BINARY_TAR="${KUBE_ROOT}/server/kubernetes-server-linux-amd64.tar.gz"
  RELEASE_DIR="${KUBE_ROOT}/server/"
  if [[ ! -f "$SERVER_BINARY_TAR" ]]; then
    SERVER_BINARY_TAR="${KUBE_ROOT}/_output/release-tars/kubernetes-server-linux-amd64.tar.gz"
    RELEASE_DIR="${KUBE_ROOT}/_output/release-tars/"
  fi
  if [[ ! -f "$SERVER_BINARY_TAR" ]]; then
    echo "!!! Cannot find kubernetes-server-linux-amd64.tar.gz"
    exit 1
  fi
}

openstack-set-vars() {

  CLOUDFILES_CONTAINER="kubernetes-releases-${OS_USERNAME}"
  CONTAINER_PREFIX=${CONTAINER_PREFIX-devel/}
  find-release-tars
}

# Retrieves a tempurl from cloudfiles to make the release object publicly accessible temporarily.
find-object-url() {

  openstack-set-vars

  KUBE_TAR=${CLOUDFILES_CONTAINER}/${CONTAINER_PREFIX}/kubernetes-server-linux-amd64.tar.gz
  #MY_KEY="secret"
  #swift --os-auth-url ${OS_AUTH_URL} --os-username ${OS_USERNAME} --os-password ${OS_PASSWORD} post -m "X-Account-Meta-Temp-URL-Key: ${MY_KEY}"

  RELEASE_TMP_URL=$(swift --os-auth-url ${OS_AUTH_URL} --os-username ${OS_USERNAME} --os-password ${OS_PASSWORD} tempurl GET 3600 ${KUBE_TAR} ${MY_KEY})
  RELEASE_TMP_URL="https://region-b.geo-1.objects.hpcloudsvc.com/v1/10820682209898${RELEASE_TMP_URL}"
  echo "cluster/openstack/util.sh: Object temp URL:"
  echo -e "\t${RELEASE_TMP_URL}"


}

ensure_dev_container() {

  SWIFT_CMD="swift --os-auth-url ${OS_AUTH_URL} --os-username ${OS_USERNAME} --os-password ${OS_PASSWORD}"

  if ! ${SWIFT_CMD} list ${CLOUDFILES_CONTAINER} > /dev/null 2>&1 ; then
    echo "cluster/openstack/util.sh: Container doesn't exist. Creating container ${KUBE_OPENSTACK_RELEASE_BUCKET}"
    echo ${SWIFT_CMD} post ${CLOUDFILES_CONTAINER}
    ${SWIFT_CMD} post ${CLOUDFILES_CONTAINER} > /dev/null 2>&1
  fi
}

# Copy kubernetes-server-linux-amd64.tar.gz to cloud files object store
copy_dev_tarballs() {

  echo "cluster/openstack/util.sh: Uploading to Cloud Files"
  echo ${SWIFT_CMD} upload --skip-identical --object-name kubernetes-server-linux-amd64.tar.gz ${CLOUDFILES_CONTAINER}/${CONTAINER_PREFIX} \
  ${RELEASE_DIR}/kubernetes-server-linux-amd64.tar.gz

  ${SWIFT_CMD} upload --skip-identical --object-name kubernetes-server-linux-amd64.tar.gz ${CLOUDFILES_CONTAINER}/${CONTAINER_PREFIX} \
  ${RELEASE_DIR}/kubernetes-server-linux-amd64.tar.gz > /dev/null 2>&1

  echo "Release pushed."
}

openstack-boot-master() {

  DISCOVERY_URL=$(curl https://discovery.etcd.io/new)
  DISCOVERY_ID=$(echo "${DISCOVERY_URL}" | cut -f 4 -d /)
  echo "cluster/openstack/util.sh: etcd discovery URL: ${DISCOVERY_URL}"

# Copy cloud-config to KUBE_TEMP and work some sed magic
  sed -e "s|DISCOVERY_ID|${DISCOVERY_ID}|" \
      -e "s|CLOUD_FILES_URL|${RELEASE_TMP_URL//&/\\&}|" \
      -e "s|KUBE_USER|${KUBE_USER}|" \
      -e "s|KUBE_PASSWORD|${KUBE_PASSWORD}|" \
      -e "s|PORTAL_NET|${PORTAL_NET}|" \
      $(dirname $0)/openstack/cloud-config/master-cloud-config.yaml > $KUBE_TEMP/master-cloud-config.yaml


  MASTER_BOOT_CMD="nova boot \
--key-name ${SSH_KEY_NAME} \
--flavor ${KUBE_MASTER_FLAVOR} \
--image ${KUBE_IMAGE} \
--meta '${MASTER_TAG}' \
--meta 'ETCD=${DISCOVERY_ID}' \
--user-data ${KUBE_TEMP}/master-cloud-config.yaml \
--nic net-id=${NETWORK_UUID} \
${MASTER_NAME}"

  echo "cluster/openstack/util.sh: Booting ${MASTER_NAME} with following command:"
  echo -e "\t$MASTER_BOOT_CMD"
  $MASTER_BOOT_CMD

  MASTER_VM_STATUS=$(nova show ${MASTER_NAME} | grep status | awk '{ print $4}')
  echo "Waiting for $MASTER_NAME to become active to assign Floating-IP"
  while [ ! "${MASTER_VM_STATUS}" == "ACTIVE" ]; do
    MASTER_VM_STATUS=$(nova show ${MASTER_NAME} | grep status | awk '{ print $4}')
    printf "."
    sleep 2
  done

  # find first free floating IP address
  MASTER_IP=$(nova floating-ip-list | awk '{ print $2, $6}' | grep -m1 \- | awk '{ print $1}')
  echo "nova floating-ip-associate ${MASTER_NAME} $MASTER_IP"
  nova floating-ip-associate ${MASTER_NAME} $MASTER_IP

}

openstack-boot-minions() {

  cp $(dirname $0)/openstack/cloud-config/minion-cloud-config.yaml \
  ${KUBE_TEMP}/minion-cloud-config.yaml

  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do

    sed -e "s|DISCOVERY_ID|${DISCOVERY_ID}|" \
        -e "s|INDEX|$((i + 1))|g" \
        -e "s|CLOUD_FILES_URL|${RELEASE_TMP_URL//&/\\&}|" \
        -e "s|ENABLE_NODE_MONITORING|${ENABLE_NODE_MONITORING:-false}|" \
        -e "s|ENABLE_NODE_LOGGING|${ENABLE_NODE_LOGGING:-false}|" \
        -e "s|LOGGING_DESTINATION|${LOGGING_DESTINATION:-}|" \
        -e "s|ENABLE_CLUSTER_DNS|${ENABLE_CLUSTER_DNS:-false}|" \
        -e "s|DNS_SERVER_IP|${DNS_SERVER_IP:-}|" \
        -e "s|DNS_DOMAIN|${DNS_DOMAIN:-}|" \
    $(dirname $0)/openstack/cloud-config/minion-cloud-config.yaml > $KUBE_TEMP/minion-cloud-config-$(($i + 1)).yaml


    MINION_BOOT_CMD="nova boot \
--key-name ${SSH_KEY_NAME} \
--flavor ${KUBE_MINION_FLAVOR} \
--image ${KUBE_IMAGE} \
--meta ${MINION_TAG} \
--user-data ${KUBE_TEMP}/minion-cloud-config-$(( i +1 )).yaml \
--nic net-id=${NETWORK_UUID} \
${MINION_NAMES[$i]}"

    echo "cluster/openstack/util.sh: Booting ${MINION_NAMES[$i]} with following command:"
    echo -e "\t$MINION_BOOT_CMD"
    $MINION_BOOT_CMD

    MINION_VM_STATUS=$(nova show ${MINION_NAMES[$i]} | grep status | awk '{ print $4}')
    echo "Waiting for ${MINION_NAMES[$i]} to become active to assign Floating-IP"
    while [ ! "${MINION_VM_STATUS}" == "ACTIVE" ]; do
      MINION_VM_STATUS=$(nova show ${MINION_NAMES[$i]} | grep status | awk '{ print $4}')
      printf "."
      sleep 2
    done

    MINION_IP=$(nova floating-ip-list | awk '{ print $2, $6}' | grep -m1 \- | awk '{ print $1}')
    echo "nova floating-ip-associate ${MINION_NAMES[$i]} $MINION_IP"
    nova floating-ip-associate ${MINION_NAMES[$i]} $MINION_IP
  done
}

openstack-nova-network() {
  if ! $(nova network-list | grep $NOVA_NETWORK_LABEL > /dev/null 2>&1); then
    SAFE_CIDR=$(echo $NOVA_NETWORK_CIDR | tr -d '\\')
    NETWORK_CREATE_CMD="nova network-create --fixed-cidr $SAFE_CIDR $NOVA_NETWORK_LABEL"

    echo "cluster/openstack/util.sh: Creating cloud network with following command:"
    echo -e "\t${NETWORK_CREATE_CMD}"

    $NETWORK_CREATE_CMD
  else
    echo "cluster/openstack/util.sh: Using existing cloud network $NOVA_NETWORK_LABEL"
  fi
}

openstack-neutron-network() {
  if ! $(neutron net-list | grep $NOVA_NETWORK_LABEL > /dev/null 2>&1); then
    SAFE_CIDR=$(echo $NOVA_NETWORK_CIDR | tr -d '\\')
    NETWORK_CREATE_CMD="neutron net-create --fixed-cidr $SAFE_CIDR $NOVA_NETWORK_LABEL"

    echo "cluster/openstack/util.sh: Creating cloud network with following command:"
    echo -e "\t${NETWORK_CREATE_CMD}"

    $NETWORK_CREATE_CMD
  else
    echo "cluster/openstack/util.sh: Using existing cloud network $NOVA_NETWORK_LABEL"
  fi
}

detect-minions() {
  KUBE_MINION_IP_ADDRESSES=()
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    local minion_ip=$(nova show --minimal ${MINION_NAMES[$i]} \
      | grep "${NOVA_NETWORK_LABEL} network" | awk '{print $6}')
    echo "cluster/openstack/util.sh: Found ${MINION_NAMES[$i]} at ${minion_ip}"
    KUBE_MINION_IP_ADDRESSES+=("${minion_ip}")
  done
  if [ -z "$KUBE_MINION_IP_ADDRESSES" ]; then
    echo "cluster/openstack/util.sh: Could not detect Kubernetes minion nodes.  Make sure you've launched a cluster with 'kube-up.sh'"
    exit 1
  fi

}

detect-master() {
  KUBE_MASTER=${MASTER_NAME}

  echo "Waiting for ${MASTER_NAME} IP Address."
  echo
  echo "  This will continually check to see if the master node has an IP address."
  echo

  KUBE_MASTER_IP=$(nova show $KUBE_MASTER --minimal | grep "${NOVA_NETWORK_LABEL} network" | awk '{print $6}')

  while [ "${KUBE_MASTER_IP-|}" == "|" ]; do
    KUBE_MASTER_IP=$(nova show $KUBE_MASTER --minimal | grep "${NOVA_NETWORK_LABEL} network" | awk '{print $6}')
    printf "."
    sleep 2
  done

  echo "${KUBE_MASTER} IP Address is ${KUBE_MASTER_IP}"
}

# $1 should be the network you would like to get an IP address for
detect-master-nova-net() {
  KUBE_MASTER=${MASTER_NAME}

  MASTER_IP=$(nova show $KUBE_MASTER --minimal | grep $1 | awk '{print $5}')
}

kube-up() {

  SCRIPT_DIR=$(CDPATH="" cd $(dirname $0); pwd)

  openstack-set-vars
  ensure_dev_container
  copy_dev_tarballs

  # Find the release to use.  Generally it will be passed when doing a 'prod'
  # install and will default to the release/config.sh version when doing a
  # developer up.
  find-object-url

  # Create a temp directory to hold scripts that will be uploaded to master/minions
  KUBE_TEMP=$(mktemp -d -t kubernetes.XXXXXX)
  trap "rm -rf ${KUBE_TEMP}" EXIT

  get-password
  python $(dirname $0)/../third_party/htpasswd/htpasswd.py -b -c ${KUBE_TEMP}/htpasswd $KUBE_USER $KUBE_PASSWORD
  HTPASSWD=$(cat ${KUBE_TEMP}/htpasswd)

  #openstack-nova-network
  #NETWORK_UUID=$(nova network-list | grep -i ${NOVA_NETWORK_LABEL} | awk '{print $2}')

  openstack-neutron-network
  NETWORK_UUID=$(neutron net-list | grep -i ${NOVA_NETWORK_LABEL} | awk '{print $2}')

  # create and upload ssh key if necessary
  openstack-ssh-key

  echo "cluster/openstack/util.sh: Starting Cloud Servers"
  openstack-boot-master

  openstack-boot-minions

  FAIL=0
  for job in `jobs -p`
  do
      wait $job || let "FAIL+=1"
  done
  if (( $FAIL != 0 )); then
    echo "${FAIL} commands failed.  Exiting."
    exit 2
  fi

  detect-master

  echo "Waiting for cluster initialization."
  echo
  echo "  This will continually check to see if the API for kubernetes is reachable."
  echo "  This might loop forever if there was some uncaught error during start"
  echo "  up."
  echo

  #This will fail until apiserver salt is updated
  until $(curl --insecure --user ${KUBE_USER}:${KUBE_PASSWORD} --max-time 5 \
          --fail --output /dev/null --silent https://${KUBE_MASTER_IP}/api/v1beta1/pods); do
      printf "."
      sleep 2
  done

  echo "Kubernetes cluster created."

  # Don't bail on errors, we want to be able to print some info.
  set +e

  detect-minions

  echo "All minions may not be online yet, this is okay."
  echo
  echo "Kubernetes cluster is running.  The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ~/.kubernetes_auth."
  echo
  echo "Security note: The server above uses a self signed certificate.  This is"
  echo "    subject to \"Man in the middle\" type attacks."
  echo
}

function setup-monitoring {
    echo "TODO"
}

function teardown-monitoring {
  echo "TODO"
}

function setup-logging {
  echo "TODO: setup logging"
}

function teardown-logging {
  echo "TODO: teardown logging"
}

# Perform preparations required to run e2e tests
function prepare-e2e() {
  echo "Openstack doesn't need special preparations for e2e tests"
}
