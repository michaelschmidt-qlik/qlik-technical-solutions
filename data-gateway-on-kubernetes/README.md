# Qlik Data Gateway (Direct Access) on Kubernetes

Run a **Qlik Data Gateway - Direct Access** as a Kubernetes workload, translated from
Qlik's official `docker-compose` bundle. The result registers to a Qlik Cloud tenant and
serves ODBC and REST sources - functionally identical to the Docker Compose gateway, but
running as a Deployment with persistent storage.

> **Kubernetes and k3s.** "Kubernetes" (commonly written **k8s** - K, eight letters, s) is the
> platform. **k3s** is a lightweight, CNCF-conformant *distribution* of Kubernetes (single binary,
> containerd runtime) - it **is** Kubernetes, just packaged small. The manifests here are standard
> Kubernetes and run on any conformant cluster; the few details specific to **k3s/containerd**
> (the `local-path` StorageClass, the `/.dockerenv` container-detection fix) are called out where
> they matter.

> **Support caveat:** Qlik supports the Direct Access gateway as a **Windows service** or a
> **Docker Compose** deployment. Running it on Kubernetes is **not** an officially supported
> Qlik configuration. It works and is stable, but you are off Qlik's support path if
> something breaks - keep your Compose deployment as the documented, supported fallback.

**Verified against:** `direct-access-agent:1.8.0`, `dcaas-dg:6.70.0`, k3s `v1.36.x` (containerd).
Image internals (ports, config template, bootstrap commands) change between versions - always
re-verify against the compose bundle you download from your own tenant.

---

## Why this is non-trivial

Structurally the compose file maps to Kubernetes cleanly. But **five Docker-vs-Kubernetes
behaviors** will break a naive translation, and none of them are in Qlik's docs. They are the
whole point of this repo:

1. The two containers must share one Pod (they share a volume).
2. Keep Qlik's env vars byte-for-byte; resolve the service names with `hostAliases`.
3. Kubernetes does **not** seed a volume from the image like Docker - seed it with an initContainer.
4. The gateway detects "am I in a container?" via **`/.dockerenv`**, which **containerd never creates** - inject it, or the tenant shows phantom SAP/File connectors.
5. No Service, single replica, `Recreate`, run as UID 13600.

Details in [The five gotchas](#the-five-gotchas).

---

## Architecture

```
         Qlik Cloud tenant  (*.qlikcloud.com:443, WSS)
                          ^
                          |  outbound only; nothing dials in
    +---------------------+------------------------------+
    |                  Pod: qlik-dag                     |
    |                                                    |
    |   +-------------+               +--------------+   |
    |   |  dcaas-dg   |<--127.0.0.1-->| direct-      |   |
    |   |   :9027     |  (hostAlias)  | access-agent |   |
    |   +------+------+               +------+-------+   |
    |          |                             |          |
    |          +---- shared /usr/data (PVC) -+          |
    |                                                   |
    |          /usr/share/Qlik/Gateway (PVC)            |
    +---------------------------------------------------+
                   k3s node (containerd)
```

- **`dcaas-dg`** opens the outbound WebSocket to the tenant and reports capabilities.
- **`direct-access-agent`** is the connector runtime (ODBC/REST) and holds the registration identity.
- They talk over many ports; in one Pod they reach each other on `127.0.0.1` via `hostAliases`.
- **Outbound only** - no Service, Ingress, or LoadBalancer.
- **Persisted:** the registration identity (`/usr/data/cfgrepo.sqlite`) and connector config
  (`/usr/share/Qlik/Gateway`) live on PVCs, so restarts don't re-register.

---

## Prerequisites

- A Kubernetes cluster with `kubectl` and a **default StorageClass** for ReadWriteOnce volumes
  (this repo uses k3s's built-in `local-path`).
- A **Qlik Cloud tenant** and a user who can register a Data Gateway (tenant admin or equivalent).
- Your tenant's **Direct Access compose bundle** (Management Console -> Data Gateways ->
  Direct Access -> add new) - used only as the source of truth for image tags / env / ports.
- **Egress** from pods to `ghcr.io` (public images, no pull secret) and to your tenant on 443.
- No inbound exposure of any kind.

---

## Quick start

```bash
# 1. Deploy
kubectl apply -f k8s/qlik-dag.yaml
kubectl -n qlik-dag rollout status deploy/qlik-dag   # dcaas-dg goes Ready; the agent
                                                     # crash-loops until registered (expected)

# 2. Register (interactive): generates the key, you paste it into the tenant, then it connects
TENANT_URL=https://yourtenant.us.qlikcloud.com ./scripts/register-gateway.sh

# 3. Verify
kubectl -n qlik-dag get pods -o wide                 # expect 2/2 Running, 0 restarts
```

---

## The five gotchas

### 1. Both containers belong in one Pod

The gateway is two containers that reference each other across ~6 ports **and share the
`/usr/data` volume**. Two separate Deployments can't share one ReadWriteOnce PVC, so the two
containers go in a **single Pod**, sharing the volume and the network namespace.

### 2. Keep the env vars identical; resolve names with `hostAliases`

In compose the services reach each other by container name (`dcaas-dg-1`,
`direct-access-agent-1`). Qlik explicitly warns **not** to set `HOST_IP` to `localhost`. So keep
every Qlik env var exactly as shipped and add:

```yaml
hostAliases:
  - ip: "127.0.0.1"
    hostnames: ["direct-access-agent-1", "dcaas-dg-1"]
```

Now the compose names resolve to loopback inside the Pod and you change nothing Qlik ships.

### 3. Kubernetes does not seed volumes from the image

Docker copies an image directory's contents into a named volume on first mount. **Kubernetes
does not.** An empty PVC mounted at `/usr/share/Qlik/Gateway` *masks* the CA bundles and config
baked into the image, and the agent fails to start. Fix with an initContainer that seeds it:

```sh
if [ ! -e /seed-gw/configuration.properties ]; then
  cp -a /usr/share/Qlik/Gateway/. /seed-gw/
fi
```

### 4. The `/.dockerenv` container-detection flag

The subtle one. The gateway decides which connectors to advertise partly by detecting that it's
running in a container - and it checks for **`/.dockerenv`**, the marker file **Docker** drops in
every container. **containerd (k3s) never creates it.** Without it, the gateway behaves like a
full install and advertises the entire connector template from `configuration.properties` -
including **SAP and File connectors that the Linux container image doesn't even ship**. The
tenant then shows phantom SAP/File tabs that can't work.

> `LINUX_CONTAINER=true` is **not** this flag - it's set on both Docker and k3s and does not gate
> the connector list. The real signal is `/.dockerenv`.

Fix: create `/.dockerenv` in the Pod (initContainer writes it to a scratch volume; the agent
mounts that file read-only at `/.dockerenv`):

```yaml
# init:  touch /seed-dflag/.dockerenv
# agent volumeMount:
- name: dockerflag
  mountPath: /.dockerenv
  subPath: .dockerenv
  readOnly: true
```

After this the gateway self-identifies as a container and advertises only ODBC/REST - matching
the Docker gateway.

### 5. No Service, single replica, `Recreate`, run as 13600

Outbound-only => **no Service/Ingress/LoadBalancer**. A Data Gateway is a single registered node,
so `replicas: 1` with `strategy: Recreate` (old Pod releases the RWO PVC before the new one
starts). Run as **UID/GID 13600** with `fsGroup: 13600` so both containers can use the shared
volumes (the `dcaas-dg` image runs as 13600 and the agent writes its config as 13600).

---

## Registration - how it actually works

A fresh gateway **cannot start** until it knows its tenant (`"Direct Access Gateway service
could not start since 'tenant_url' is not set."`). The registration is a gateway-side key
generation that you paste into the tenant. `scripts/register-gateway.sh` automates it:

1. **Park the agent** on a keep-alive (override its command with `sleep infinity`) so the CLI can
   run while the service is down.
2. Inside the agent container (`dotnet ConnectorAgent.dll qcs ...`):
   - `set_config --tenant_url https://<tenant> --connection_mode DATA_GATEWAY`
   - `generate_keys`
   - `get_registration`  -> prints the **registration key** (JSON with an EC P-384 cert)
3. **Paste the key** into the tenant: Management Console -> Data Gateways -> Direct Access -> add,
   then name the gateway and assign a space.
4. **Remove the keep-alive** -> the agent boots registered and connects.

The identity is written to `cfgrepo.sqlite` on the `agent-data` PVC, so it survives restarts and
reschedules - you register **once**.

---

## Verifying

```bash
kubectl -n qlik-dag get pods -o wide           # 2/2 Running, 0 restarts

# dcaas health
kubectl -n qlik-dag exec de/qlik-dag -c dcaas-dg -- \
  sh -c 'wget -qO- http://127.0.0.1:9027/health'      # -> OK

# one ESTABLISHED outbound :443 (the WSS tunnel to the tenant)
kubectl -n qlik-dag exec de/qlik-dag -c dcaas-dg -- \
  sh -c 'cat /proc/net/tcp /proc/net/tcp6' | awk '$4=="01"' | grep -i ':01BB' | wc -l
```

In the tenant, the gateway shows **Connected**, and its **Connectors** list is **ODBC / REST /
Metrics collector**.

---

## Connector availability (important)

| Platform | Connectors actually available |
|---|---|
| **Windows** gateway | ODBC, REST, **File, SAP BW, SAP SQL, SAP ODP** |
| **Docker / Kubernetes** container | **ODBC, REST only** |

**SAP and File connectors ship only in the Windows gateway build.** The Linux container image
(`direct-access-agent`) contains no SAP/File connector binaries at all. If the tenant shows SAP
or File tabs for a container gateway, that's the `/.dockerenv` detection failing (gotcha #4) -
they're phantom and will fail if used. If you genuinely need SAP/File, use a Windows gateway.

---

## Operations

- **Persistence / restarts.** The registration lives on the `agent-data` PVC. Pod restarts and
  reschedules keep it. With `local-path`, the PV is node-local, so the Pod reschedules back to the
  node that holds the volume - fine for a single-replica gateway.
- **Upgrades.** Bump the image tags to match a newer compose bundle, re-`apply`. The PVCs (and
  registration) persist. Re-check the env block against the new bundle.
- **Logging.** The Compose deployment ships logs to journald; here the containers log to stdout
  (`kubectl logs`). To centralize, run a log shipper (Alloy/Promtail -> Loki) in the cluster.
- **Secrets.** Registration is interactive and gateway-side, so there is **no pre-shared key** in
  the manifest. Don't commit the `get_registration` output or any kubeconfig (see `.gitignore`).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Agent `CrashLoopBackOff`, log says `tenant_url is not set` | Not registered yet | Normal for a new gateway - run `register-gateway.sh` |
| Agent won't start, config/SSL missing under `/usr/share/Qlik/Gateway` | Empty PVC masked the image's baked files | The seed initContainer (gotcha #3) - confirm it ran |
| Tenant shows **SAP / File** tabs on a container gateway | `/.dockerenv` absent -> mis-detected as non-container | Inject `/.dockerenv` (gotcha #4); restart the agent |
| Containers can't reach each other | Service-name env vars don't resolve | `hostAliases` mapping the names to `127.0.0.1` (gotcha #2) |
| Pod stuck `Pending` after reschedule | `local-path` PV is node-local | It schedules back to its node; ensure that node is Ready |

---

## Files

```
data-gateway-on-kubernetes/
  README.md
  k8s/
    qlik-dag.yaml
  scripts/
    register-gateway.sh
```
