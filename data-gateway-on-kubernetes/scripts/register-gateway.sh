#!/usr/bin/env bash
#
# register-gateway.sh
# One-time registration of the Qlik Data Gateway running in Kubernetes.
#
# The agent cannot start until it is registered (it needs tenant_url), so we park it
# on a keep-alive, run the qcs CLI to generate a registration key, you paste that key
# into the Qlik Cloud tenant, then we flip the agent back to normal startup.
#
# Prereqs: kubectl context pointed at the cluster; the manifest already applied.
#
# Usage:
#   TENANT_URL=https://yourtenant.us.qlikcloud.com ./register-gateway.sh
#
set -euo pipefail

NS="${NS:-qlik-dag}"
DEPLOY="${DEPLOY:-qlik-dag}"
AGENT="${AGENT:-direct-access-agent}"           # the agent container name
AGENT_INDEX="${AGENT_INDEX:-1}"                 # its index in spec.containers (dcaas-dg=0, agent=1)
TENANT_URL="${TENANT_URL:?Set TENANT_URL, e.g. https://yourtenant.us.qlikcloud.com}"

KC="kubectl -n ${NS}"

echo "==> Parking the agent on keep-alive (it can't run un-registered)..."
${KC} patch deployment "${DEPLOY}" --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/${AGENT_INDEX}/command\",\"value\":[\"sh\",\"-lc\",\"sleep infinity\"]}]"
${KC} rollout status "deploy/${DEPLOY}" --timeout=180s

POD="$(${KC} get pods -l app="${DEPLOY}" -o name | head -1)"
echo "==> Pod: ${POD}"

echo "==> Setting tenant_url and generating the gateway keypair..."
${KC} exec "${POD}" -c "${AGENT}" -- sh -c \
  "cd /usr/app && dotnet ConnectorAgent.dll qcs set_config --tenant_url ${TENANT_URL} --connection_mode DATA_GATEWAY"
${KC} exec "${POD}" -c "${AGENT}" -- sh -c \
  "cd /usr/app && dotnet ConnectorAgent.dll qcs generate_keys"

echo
echo "================  REGISTRATION KEY  ================"
echo "Copy the JSON below and paste it into the tenant."
echo "---------------------------------------------------"
${KC} exec "${POD}" -c "${AGENT}" -- sh -c \
  "cd /usr/app && dotnet ConnectorAgent.dll qcs get_registration" | grep '^{'
echo "==================================================="
echo
echo "In Qlik Cloud:  Management Console -> Data Gateways -> Direct Access -> Add,"
echo "paste the key above, give the gateway a name, and assign it to a space."
echo
read -r -p "Press ENTER once the tenant shows the gateway registered... " _

echo "==> Removing keep-alive so the agent starts normally..."
${KC} patch deployment "${DEPLOY}" --type=json \
  -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/${AGENT_INDEX}/command\"}]"
${KC} rollout status "deploy/${DEPLOY}" --timeout=180s

echo "==> Status:"
${KC} get pods -o wide

cat <<'EOF'

Done. The gateway should now boot registered and connect outbound to the tenant.
Verify:
  - pod is 2/2 Running, 0 restarts
  - the tenant shows the gateway "Connected"
  - (optional) one ESTABLISHED outbound :443 from the pod:
      kubectl -n qlik-dag exec <pod> -c dcaas-dg -- \
        sh -c 'cat /proc/net/tcp /proc/net/tcp6' | awk '$4=="01"' | grep -i ':01BB' | wc -l
EOF
