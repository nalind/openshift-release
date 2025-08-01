#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset
# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function oinst() {
  /tmp/openshift-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
function wait_for_nodes_readiness()
{
  local expected_nodes=${1}
  local max_retries=${2:-10}
  local period=${3:-5}
  for i in $(seq 1 "${max_retries}") max; do
    if [ "${i}" == "max" ]; then
      echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${ready_nodes}... Failing."
      return 1
    fi
    sleep "${period}m"
    ready_nodes=$(get_ready_nodes_count)
    if [ x"${ready_nodes}" == x"${expected_nodes}" ]; then
        echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
        return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i) * (period) ))min)..."
  done
}

function destroy_bootstrap() {
  echo "Destroying bootstrap..."
  # shellcheck disable=SC1090
  . <(yq -P e -I0 -o=p '.[] | select(.name|test("bootstrap"))' "$SHARED_DIR/hosts.yaml" | sed 's/^\(.*\) = \(.*\)$/\1="\2"/')
  # shellcheck disable=SC2154
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
    "${CLUSTER_NAME}" "${mac}" "${ip}" "${DISCONNECTED}"<< 'EOF'
  BUILD_ID="$1"
  mac="$2"
  ip="$3"
  DISCONNECTED="$4"
  echo "Destroying bootstrap: removing the DHCP/PXE config..."
  sed -i "/^$mac/d" /opt/dnsmasq/hosts/hostsdir/"${BUILD_ID}"
  kill -s HUP "$(podman inspect -f '{{ .State.Pid }}' "dhcp")"
  echo "Destroying bootstrap: removing the grub config..."
  rm -f "/opt/dnsmasq/tftpboot/grub.cfg-01-${mac//:/-}" || echo "no grub.cfg for $mac."
  echo "Destroying bootstrap: removing dns entries..."
  sed -i "/bootstrap.*${BUILD_ID:-glob-protected-from-empty-var}/d" /opt/bind9_zones/{zone,internal_zone.rev}
  if [ "${DISCONNECTED}" == "true" ]; then
    echo "Destroying bootstrap: removing drop rule for disconnected network..."
    rule=$(iptables -S FORWARD | grep "${ip}" | grep DROP | sed 's/^-A /-D /')
    read -r -a RULE <<< "${rule}"
    [[ "${rule}" =~ D.*$ip.*DROP ]] && iptables "${RULE[@]}"
  fi
  echo "Destroying bootstrap: removing the bootstrap node ip in the backup pool of haproxy"
  # haproxy.cfg is mounted as a volume, and we need to remove the bootstrap node from being a backup:
  # using sed -i leads to creating a new file with a different inode number.
  # A different inode means that the file mapping mounted from the host to the container gets lost.
  # Re-writing with cat (+ redirection) the desired haproxy.cfg doesn't lead to a
  # new file and inode allocation.
  # See https://github.com/moby/moby/issues/15793
  F="/var/builds/${BUILD_ID}/haproxy/haproxy.cfg"
  sed '/server bootstrap-/d' "${F}" > "${F}.tmp"
  cat "${F}.tmp" > "${F}"
  rm -rf "${F}.tmp"
  podman kill -s HUP "haproxy-${BUILD_ID}"
  podman exec bind9 rndc reload
  podman exec bind9 rndc flush
EOF
  # do not fail if unable to wipe the bootstrap disk and do not release it, to retry later in post steps
  # shellcheck disable=SC2154
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "pxe"
  if ! wait_for_power_down "${bmc_address}" "${bmc_forwarded_port}" "${bmc_user}" "${bmc_pass}" "${vendor}" "${ipxe_via_vmedia}"; then
    echo "The bootstrap node didn't power off and it will not be released to retry in the deprovisioning steps..."
    return 0
  fi

  if [ -z "${pdu_uri}" ]; then
    echo "pdu_uri is empty... skipping pdu reset"
  else
    pdu_host=${pdu_uri%%/*}
    pdu_socket=${pdu_uri##*/}
    pdu_creds=${pdu_host%%@*}
    pdu_host=${pdu_host##*@}
    pdu_user=${pdu_creds%%:*}
    pdu_pass=${pdu_creds##*:}
    # pub-priv key auth is not supported by the PDUs
    echo "${pdu_pass}" > /tmp/ssh-pass

    timeout -s 9 10m sshpass -f /tmp/ssh-pass ssh "${SSHOPTS[@]}" "${pdu_user}@${pdu_host}" <<EOF || true
olReboot $pdu_socket
quit
EOF
    if ! wait_for_power_down "${bmc_address}" "${bmc_forwarded_port}" "${bmc_user}" "${bmc_pass}" "${ipxe_via_vmedia}" "${vendor}"; then
      echo "The bootstrap node PDU reset was not successful... it will not be released to retry in the deprovisioning steps..."
      return 0
    fi
  fi

  echo "Releasing the bootstrap node..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
        "${CLUSTER_NAME}" << 'EOF'
  BUILD_USER=ci-op
  BUILD_ID="$1"

  LOCK="/tmp/reserved_file.lock"
  LOCK_FD=200
  touch $LOCK
  exec 200>$LOCK

  set -e
  trap catch_exit ERR INT

  function catch_exit {
    echo "Error. Releasing lock $LOCK_FD ($LOCK)"
    flock -u $LOCK_FD
    exit 1
  }

  echo "Acquiring lock $LOCK_FD ($LOCK) (waiting up to 10 minutes)"
  flock -w 600 $LOCK_FD
  echo "Lock acquired $LOCK_FD ($LOCK)"

  sed -i "/,${BUILD_ID},${BUILD_USER},bootstrap/d" /etc/hosts_pool_reserved
  sed -i "/,${BUILD_ID},${BUILD_USER},bootstrap/d" /etc/vips_reserved

  echo "Releasing lock $LOCK_FD ($LOCK)"
  flock -u $LOCK_FD
EOF
  echo "Destroying bootstrap: removing the bootstrap node from hosts.yaml..."
  yq --inplace 'del(.[]|select(.name|test("bootstrap")))' "$SHARED_DIR/hosts.yaml"
  scp "${SSHOPTS[@]}" "$SHARED_DIR/hosts.yaml" "root@${AUX_HOST}:/var/builds/${CLUSTER_NAME}/"
}

function wait_for_power_down() {
  local bmc_address="${1}"
  local bmc_forwarded_port="${2}"
  local bmc_user="${3}"
  local bmc_pass="${4}"
  local vendor="${5}"
  local ipxe_via_vmedia="${6}"
  local host="${bmc_forwarded_port##1[0-9]}"
  host="${host##0}"
  sleep 90
  local retry_max=40 # 15*40=600 (10 min)
  while [ $retry_max -gt 0 ] && ! ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_forwarded_port}" \
    -U "$bmc_user" -P "$bmc_pass" power status | grep -q "Power is off"; do
    echo "${host} is not powered off yet... waiting"
    sleep 30
    retry_max=$(( retry_max - 1 ))
  done
  if [ $retry_max -le 0 ]; then
    echo -n "${host} didn't power off successfully..."
    if [ -f "/tmp/${host}" ]; then
      echo "${host} kept powered on and needs further manual investigation..."
      return 1
    else
      # We perform the reboot at most twice to overcome some known BMC hardware failures
      # that sometimes keep the hosts frozen before POST.
      echo "retrying $ again to reboot..."
      touch "/tmp/$host"
      timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "pxe"
      wait_for_power_down "$bmc_address" "$bmc_forwarded_port" "$bmc_user" "$bmc_pass" "$vendor" "$ipxe_via_vmedia"
      return $?
    fi
  fi
  echo "#$host is now powered off"
  return 0
}

function approve_csrs() {
  while [[ ! -f '/tmp/install-complete' ]]; do
    sleep 30
    echo "approve_csrs() running..."
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
      | xargs --no-run-if-empty oc adm certificate approve || true
  done
}

function update_image_registry() {
  # from OCP 4.14, the image-registry is optional, check if ImageRegistry capability is added
  knownCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}"`
  if [[ ${knownCaps} =~ "ImageRegistry" ]]; then
      echo "knownCapabilities contains ImageRegistry"
      # check if ImageRegistry capability enabled
      enabledCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}"`
        if [[ ! ${enabledCaps} =~ "ImageRegistry" ]]; then
            echo "ImageRegistry capability is not enabled, skip image registry configuration..."
            return 0
        fi
  fi
  while ! oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
                 --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'; do
    echo "Sleeping before retrying to patch the image registry config..."
    sleep 60
  done
  echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry operator to go available..."
  oc wait co image-registry --for=condition=Available=True  --timeout=30m
  oc wait co image-registry  --for=condition=Progressing=False --timeout=10m
  sleep 60
  echo "$(date -u --rfc-3339=seconds) - Waits for kube-apiserver and openshift-apiserver to finish rolling out..."
  oc wait co kube-apiserver  openshift-apiserver --for=condition=Progressing=False  --timeout=30m
  oc wait co kube-apiserver  openshift-apiserver  --for=condition=Degraded=False  --timeout=1m
}

function update_sno_bip_live_iso {
  CONSOLE="ttyS1,115200n8"
  root_device=$(echo "$architecture" | sed 's/arm64/\/dev\/nvme0n1/;s/amd64/\/dev\/sda/')
  escaped_root_device=$(echo "$root_device" | sed 's/\//\\\//g')
  shim_arch=$(echo "$architecture" | sed 's/arm64/aa64/;s/amd64/x64/')

  b64_pre=$(jq -r '.storage.files[] | select( .path == "/usr/local/bin/install-to-disk.sh" ).contents.source' ${INSTALL_DIR}/bootstrap-in-place-for-live-iso.ign | cut -d"," -f2)
  b64_new=$(echo "${b64_pre}" | base64 -d | \
    sed -e 's/^\(.*coreos-installer install.*\)$/\1 --delete-karg console=ttyS0,115200n8 --append-karg console='"${CONSOLE}"' --insecure-ignition --copy-network\n  echo "Adding UEFI boot entry for Red Hat CoreOS"\n  efibootmgr -c -d '"${escaped_root_device}"' -p 2 -c -L "Red Hat CoreOS" -l '\''\\EFI\\redhat\\shim'"${shim_arch}"'.efi'\'' || echo "WARNING: Failed to set UEFI boot entry. Possibly BIOS mode."/' | \
    base64 -w0)
  sed -i -e 's/'"${b64_pre}"'/'"${b64_new}"'/g' ${INSTALL_DIR}/bootstrap-in-place-for-live-iso.ign

  mv ${INSTALL_DIR}/bootstrap-in-place-for-live-iso.ign ${INSTALL_DIR}/bootstrap.ign
  chmod 644 ${INSTALL_DIR}/bootstrap.ign

}

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="/tmp/installer"
mkdir -p "${INSTALL_DIR}"

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release extract -a "$PULL_SECRET_PATH" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=openshift-install --to=/tmp

# We change the payload image to the one in the mirror registry only when the mirroring happens.
# For example, in the case of clusters using cluster-wide proxy, the mirroring is not required.
# To avoid additional params in the workflows definition, we check the existence of the mirror patch file.
if [ "${DISCONNECTED}" == "true" ] && [ -f "${SHARED_DIR}/install-config-mirror.yaml.patch" ]; then
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(<"${CLUSTER_PROFILE_DIR}/mirror_registry_url")/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
fi

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  none: {}
controlPlane:
   architecture: ${architecture}
   hyperthreading: Enabled
   name: master
   replicas: ${masters}
compute:
- architecture: ${architecture}
  hyperthreading: Enabled
  name: worker
  replicas: ${workers}"

shopt -s nullglob
for f in "${SHARED_DIR}"/*_patch_install_config.yaml;
do
  echo "[INFO] Applying patch file: $f"
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" "$f"
done

cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
# From now on, we assume no more patches to the install-config.yaml are needed.
# We can create the installation dir with the manifests and, finally, the ignition configs

grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml"

### Create manifests
echo "Creating manifests..."
oinst create manifests

### Inject customized manifests
echo -e "\nThe following manifests will be included at installation time:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)
while IFS= read -r -d '' item
do
  manifest="$(basename "${item}")"
  cp "${item}" "${INSTALL_DIR}/manifests/${manifest##manifest_}"
done < <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

### Create Ignition configs
echo -e "\nCreating Ignition configs..."
if [ "${BOOTSTRAP_IN_PLACE:-false}" == "true" ]; then
  oinst create single-node-ignition-config
  update_sno_bip_live_iso
else
  oinst create ignition-configs
fi

export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

echo -e "\nPreparing firstboot ignitions for sync..."
cp "${SHARED_DIR}"/*.ign "${INSTALL_DIR}" || true

echo -e "\nCopying ignition files into bastion host..."
chmod 644 "${INSTALL_DIR}"/*.ign
scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/*.ign "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/"
scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/auth/* "root@${AUX_HOST}:/var/builds/${CLUSTER_NAME}/"

echo -e "\nPreparing files for next steps in SHARED_DIR..."
cp "${INSTALL_DIR}/metadata.json" "${SHARED_DIR}/"
cp "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/"
cp "${INSTALL_DIR}/auth/kubeadmin-password" "${SHARED_DIR}/"

echo -e "\nPower on the hosts..."
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [ ${#bmc_forwarded_port} -eq 0 ] || [ ${#bmc_user} -eq 0 ] || [ ${#bmc_pass} -eq 0 ]; then
    echo "Error while unmarshalling hosts entries"
    exit 1
  fi
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    # Do not power on the additional workers if we need to run them as day2 (e.g., to test single-arch clusters based
    # on a single-arch payload migrated to a multi-arch cluster)
    continue
  fi
  echo "Power on #${host} (${name})..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "pxe"
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
echo -e "\nForcing 15min delay to allow instances to properly boot up (long PXE boot times & console-hook) - NOTE: unnecessary overtime will be reduced from total bootstrap time."
sleep 900
echo "Launching 'wait-for bootstrap-complete' installation step....."
oinst wait-for bootstrap-complete --log-level=debug 2>&1 &
if ! wait $!; then
  gather_bootstrap # TODO
  echo "ERROR: Bootstrap failed. Aborting execution."
  exit 1
fi

if [ "${BOOTSTRAP_IN_PLACE:-false}" != "true" ]; then
  destroy_bootstrap &
fi

approve_csrs &

echo -e "\nLaunching 'wait-for install-complete' installation step....."
oinst wait-for install-complete &
if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  # TODO
  exit 1
fi

EXPECTED_NODES=$(( masters + workers ))
if [ "${ADDITIONAL_WORKERS_DAY2}" == "false" ]; then
  # If we are running additional workers as day2, we need to add them to the expected nodes count
  EXPECTED_NODES=$(( EXPECTED_NODES + ADDITIONAL_WORKERS ))
fi
# Additional check to wait all the nodes to be ready. Especially important for multi-arch compute nodes clusters with
# mixed arch nodes.
echo -e "\nWaiting for all the nodes to be ready..."
wait_for_nodes_readiness ${EXPECTED_NODES}
update_image_registry

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"
touch  "${SHARED_DIR}/success"
touch /tmp/install-complete
# Save console URL in `console.url` file so that ci-chat-bot could report success
echo "https://$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
# Password for the cluster gets leaked in the installer logs and hence removing them before saving in the artifacts.
sed 's/password: .*/password: REDACTED"/g' \
  ${INSTALL_DIR}/.openshift_install.log > "${ARTIFACT_DIR}"/.openshift_install.log
