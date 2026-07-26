# Magento on Kubernetes (Minikube) — GitOps with FluxCD

> See [README.md](README.md) for the Indonesian version.

This repo deploys Magento Open Source to a single-node Minikube cluster,
provisioned automatically via Ansible and synced via FluxCD (GitOps) from the
`kubernetes/gitops/` directory. The application image (`magento/`) and the
cluster configuration (`kubernetes/gitops/`, `ansible/`) live in the same repo.

## 1. Prerequisites and Machine Specs

- **Target OS**: Ubuntu 24.04 LTS (asserted at the start of the playbook —
  fails hard on anything else).
- **Minimum resources** (proven sufficient for `minikube_cpus: 2`,
  `minikube_memory: 2800`): ~2 vCPU, ~2.8–4 GiB RAM, ~50 GB free disk.
- **SSH access** as root or a sudo-capable user, with a key pair already
  registered on the target host (the demo Linode VM).
- **Control machine** (where you run Ansible): needs `ansible`,
  `ansible-playbook`, `git`, and SSH access to the target. `kubectl`/`helm`/
  `flux` CLIs are installed automatically *on the target host* by the
  playbook, not on the control machine.
- **GitHub account** with access to this repo via an SSH deploy key (so
  FluxCD can pull `kubernetes/gitops/`), and (optionally) GHCR access for
  `ghcr.io/yosefadi/minikube-magento/*` if the images are private.
- **Cloudflare Tunnel token** (optional, for public exposure via
  `cloudflared`) — if left unset, its secret is created as a placeholder and
  won't actually connect.
- The public domain is configured in
  `kubernetes/gitops/overlays/demo/magento-base-url-patch.yaml`.

## 2. Component Versions

| Component | Version |
| --- | --- |
| Magento Open Source | 2.4.9 (`magento/magento2` GitHub mirror, not repo.magento.com) |
| PHP | 8.5 (`php:8.5-fpm-trixie`, Debian Trixie base image) |
| Database | MariaDB 12.3 |
| Search engine | OpenSearch (chart `3.x`, image tag `2`) |
| Cache/session | DragonflyDB v1.39.0 (Redis wire-protocol compatible) |
| Web server | nginx (separate image, no PHP interpreter) + PHP-FPM (separate image) |
| Ingress controller | Traefik (chart `41.x`), exposed via **NodePort** 30080 (web) / 30443 (websecure) |
| GitOps | FluxCD (`flux2` chart v2.19.0) |
| Kubernetes | Minikube, `none` driver (kubelet runs directly on the host, not inside a container) |

Magento's admin path is deliberately **non-default** — set to `/panel`
(`MAGENTO_BACKEND_FRONTNAME`), not `/admin`.

## 3. Running Minikube and Enabling Ingress

All of this happens automatically via one Ansible command (see section 4),
but here's what actually happens under the hood:

1. The `minikube` role runs `minikube start` with `--driver=none` — kubelet
   runs directly on the host (not inside a Docker container), so
   `cri-dockerd` is needed as the CRI shim to Docker.
2. The `metrics-server` addon is enabled; the built-in `storage-provisioner`
   and `default-storageclass` addons are disabled since the default
   StorageClass is replaced with `openebs-hostpath`.
3. Ingress does **not** use Minikube's built-in `ingress` addon — Traefik is
   installed via a FluxCD `HelmRelease` in its own Kustomization
   (`flux-traefik`), which must become *Ready* first (so the `IngressRoute`
   CRD is actually registered) before the main Kustomization — the one
   containing the `IngressRoute` resource for Magento — runs. The two
   Kustomizations are linked via `dependsOn`, the same pattern used for
   `flux-storage`/OpenEBS.
4. Traefik is exposed as a `NodePort` (not `LoadBalancer`, since Minikube on
   a cloud/on-prem VM has no cloud controller to satisfy that) — reachable
   directly at `<node-ip>:30080` (HTTP) or `:30443` (HTTPS, Traefik's own
   self-signed default certificate until a real `cert-manager`/TLS secret is
   configured).

## 4. Deployment From Scratch to a Ready Application

```bash
git clone git@github.com:yosefadi/minikube-magento.git
cd minikube-magento/ansible/minikube

# Make sure inventory/demo/hosts.yml points at the target VM's IP and the
# correct private key path.

ansible-playbook site.yml -i inventory/demo
```

What the playbook (`site.yml`) actually runs, in order:

1. `common` — base packages, swap handling, CNI directories for the `none`
   driver.
2. `kubectl`, `helm`, `k9s`, `flux-cli` — install CLI tools.
3. `docker`, `cri-dockerd` — container runtime + CRI shim.
4. `minikube` — start the cluster, configure addons and the default
   StorageClass.
5. `infrastructure-secrets` — generates MariaDB & Dragonfly credentials
   (`infrastructure` namespace), idempotent: reruns won't regenerate a secret
   that already exists.
6. `apps-secrets` — copies the DB/Dragonfly credentials into the `apps`
   namespace, generates the Magento admin password (also idempotent).
7. `fluxcd` — installs FluxCD via Helm, sets up a `GitRepository` + 3
   `Kustomization`s (`flux-storage` → `flux-traefik` → the main `flux` one,
   sequenced via `dependsOn`).

Once the playbook finishes, Flux syncs
`kubernetes/gitops/overlays/demo/`, which deploys: namespaces, MariaDB,
OpenSearch, Dragonfly, cloudflared, Traefik, NetworkPolicies, and the Magento
Deployment (separate `php-fpm` and `nginx` containers). On first boot, the
`php-fpm` container waits for MariaDB/OpenSearch/Dragonfly to be reachable,
then runs `setup:install`, `setup:static-content:deploy`, and points
cache/sessions at Dragonfly.

Check final status:

```bash
export KUBECONFIG=./output/kubectl-demo.yaml   # generated automatically by the minikube role
kubectl get kustomization -n flux-system
kubectl get pods -n apps -n infrastructure
```

Magento is ready once the `magento-xxx` pod shows `2/2 Running`.

## 5. Getting a Public URL and Accessing Admin

There are two access paths:

- **Via Cloudflare Tunnel** (the "official" public path) — the domain is
  set by `MAGENTO_BASE_URL` in the demo overlay (`demo-magento.yosefadi.my.id`),
  TLS terminated at Cloudflare's edge. Requires a real tunnel token in the
  `cloudflared-tunnel-token` secret.
- **Via Traefik NodePort** directly to the VM's IP, port `30080`/`30443` —
  requires a matching `Host` header, since the `IngressRoute` matches on
  domain:
  ```bash
  curl -H "Host: demo-magento.yosefadi.my.id" http://<node-ip>:30080/
  ```

**Admin login**: open `<base-url>/panel`. Username/password come from the
`magento-credentials` secret in the `apps` namespace:

```bash
kubectl get secret magento-credentials -n apps -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl get secret magento-credentials -n apps -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## 6. Verifying Core Functionality

```bash
# All pods alive
kubectl get pods -n apps -n infrastructure

# Storefront actually renders (not just an empty 200)
curl -s http://<access-method-above>/ | grep -o '<title>.*</title>'

# DB & search engine are genuinely connected (not just container status)
kubectl exec -n apps deploy/magento -c php-fpm -- bin/magento indexer:status

# Cache & sessions are actually in use (not silently falling back to filesystem)
kubectl exec -n apps deploy/magento -c php-fpm -- bin/magento cache:status
```

Log into `/panel` with the credentials above to verify the admin panel.
If the storefront renders with CSS/JS applied (not a bare unstyled page),
`static-content:deploy` succeeded too.

## 7. Backup and Restore

This repo does **not** ship an automated backup/restore tool — below is the
manual procedure covering everything that needs saving (database, `app/etc`
configuration, uploaded media, and secrets).

**Backup:**

```bash
# Database
kubectl exec -n infrastructure mariadb-0 -- \
  mariadb-dump -u root -p"$(kubectl get secret mariadb-credentials -n infrastructure -o jsonpath='{.data.root-password}' | base64 -d)" \
  --all-databases > backup-db-$(date +%F).sql

# app/etc (encryption key, env.php config) and uploaded media
kubectl cp apps/<magento-pod-name>:/var/www/html/app/etc ./backup-app-etc -c php-fpm
kubectl cp apps/<magento-pod-name>:/var/www/html/pub/media ./backup-media -c php-fpm

# Secrets (contain every password — never commit these to git!)
kubectl get secret mariadb-credentials -n infrastructure -o yaml > backup-secret-mariadb.yaml
kubectl get secret dragonfly-credentials -n infrastructure -o yaml > backup-secret-dragonfly.yaml
kubectl get secret magento-credentials -n apps -o yaml > backup-secret-magento.yaml
```

**Restore** (reverse order — make sure the cluster/namespaces already exist):

```bash
kubectl apply -f backup-secret-mariadb.yaml -f backup-secret-dragonfly.yaml -f backup-secret-magento.yaml

kubectl exec -i -n infrastructure mariadb-0 -- \
  mariadb -u root -p"<root-password>" < backup-db-YYYY-MM-DD.sql

kubectl cp ./backup-app-etc apps/<magento-pod-name>:/var/www/html/app/etc -c php-fpm
kubectl cp ./backup-media apps/<magento-pod-name>:/var/www/html/pub/media -c php-fpm

kubectl rollout restart deployment/magento -n apps
```

> **Important**: the PVCs (`magento-etc`, `magento-static`, `magento-media`,
> MariaDB's data) use the `openebs-hostpath` StorageClass with the default
> reclaim policy (`Delete`). Deleting a PVC or its namespace **destroys the
> data**, it doesn't just unbind it — so back up first if you'll need this
> data before running `reset.yml`.

## 8. Cleaning Up the Environment

```bash
cd ansible/minikube
ansible-playbook reset.yml -i inventory/demo
```

`reset.yml` stops the Minikube cluster, removes all Minikube + Kubernetes
state on the host (`/var/lib/minikube`, `/etc/kubernetes`, etc.), uninstalls
FluxCD, and deletes the `infrastructure` + `apps` namespaces (**including all
their PVCs and data**, see the note above).

`reset.yml` does **not** uninstall the packages `site.yml` installed
(Docker, kubectl, Helm, etc.) — those stay on the host so `site.yml` can be
rerun quickly. To fully wipe a VM back to a default OS install (e.g. before
handing back a rented VM), additional manual steps are needed (purging
packages, removing apt repos, etc.) — there's no automated script for this
in the repo.

## 9. Known Issues, Limitations, and Assumptions

- **Single replica** — Magento, MariaDB, and Dragonfly are all
  `replicas: 1`, no HA/failover.
- **Dragonfly has no persistence** — cache/session data is lost on pod
  restart (intentional, it's a pure cache).
- **Cron isn't wired up** — `bin/magento cron:run` isn't scheduled (no
  scheduled indexing, email queue processing, etc.).
- **The cache backend string must be the literal `"redis"`** — this
  Magento fork replaced the legacy Zend_Cache backend resolution with a
  custom `SymfonyAdapterProvider` that only recognizes specific literal
  strings (`redis`, `valkey`, etc.). The classic `Cm_Cache_Backend_Redis`
  string from Magento's own official docs **does not work** here — it fails
  silently (falls back to the filesystem, no error).
- **LimitedSwap (KEP-2400) only works with the `none` driver** — with the
  `docker` driver, kubelet runs inside the node container, so
  `/var/lib/kubelet/config.yaml` doesn't exist on the host; an equivalent
  path for the `docker` driver isn't implemented yet.
- **Traefik's `websecure` uses its default self-signed certificate** — no
  `cert-manager`/real TLS secret is configured yet; the only genuinely
  encrypted public path right now is via Cloudflare Tunnel.
- **The GHCR pull secret and Cloudflare Tunnel token** are created as
  placeholders by Ansible if not already set — need to be manually replaced
  with real tokens.
- **Single shared SSH key access** — the common pattern on the demo VM:
  root login via one shared private key, no per-person accounts or audit
  trail.
- **OS assumption**: specifically Ubuntu 24.04 LTS (asserted at the start of
  the playbook).
- **Resource assumption**: ~2 vCPU / ~2.8–4 GiB RAM is enough for this demo
  workload; anything below that is untested.

## 10. Time Estimate

Based on live testing during this session (2 vCPU / ~2.8 GiB RAM VM):

| Stage | Estimated time |
| --- | --- |
| Ansible provisioning (Docker, kubectl, Helm, Minikube start) | ~5–10 min |
| Flux sync (infra: MariaDB, OpenSearch, Dragonfly, Traefik) | ~2–5 min |
| Magento's first boot (`setup:install` + `static-content:deploy`) | ~5–15 min (30-minute max budget set via `startupProbe`, to accommodate slower hosts) |
| **Total, first deployment from scratch** | **~15–30 min** |
| Subsequent reruns (volumes already exist, `setup:upgrade` only) | ~2–5 min |

Actual time can run longer depending on network speed (image pulls, apt
package downloads) and the host's disk/CPU speed.

## 11. Guide: Provisioning a New Environment (e.g. Staging/Production)

This repo is designed so that adding a new environment means adding **one
Kustomize overlay folder + one Ansible inventory folder** — without touching
anything in the existing `demo`/`testing` setups. Each environment runs on
its own VM, with its own Minikube cluster, and credentials (MariaDB,
Dragonfly, Magento admin, Cloudflare Tunnel token) generated independently by
Ansible for that cluster — nothing is shared across environments.

**1. Create a new Kustomize overlay** at `kubernetes/gitops/overlays/<env>/`,
mirroring `overlays/demo/` exactly (3 files):

```bash
mkdir kubernetes/gitops/overlays/staging
```

- `kustomization.yaml` — `resources: [../../base]`, plus the 2 `patches`
  below.
- `magento-base-url-patch.yaml` — a `ConfigMap` patch overriding
  `MAGENTO_BASE_URL` to the new environment's domain.
- `magento-ingressroute-patch.yaml` — an `IngressRoute` patch overriding the
  `Host()` match to the same domain (must stay consistent with
  `MAGENTO_BASE_URL` above).

**2. Create a new Ansible inventory** at `ansible/minikube/inventory/<env>/`:

- `hosts.yml` — the new VM's IP, SSH user, and private key path (see
  `inventory/demo/hosts.yml` as an example).
- `group_vars/minikube.yml` — copy from
  `inventory/demo/group_vars/minikube.yml`, then change **at minimum** this
  one line (the important one — this is what actually isolates the new
  environment instead of overwriting demo/testing):

  ```yaml
  fluxcd_git_path: ./kubernetes/gitops/overlays/staging
  ```

  Also adjust `minikube_cpus`/`minikube_memory`/`minikube_disk_size` if the
  new VM's specs differ from demo's. Everything else (the `none` driver,
  addons, `minikube_enable_limited_swap`, etc.) should stay the same so the
  new environment's behavior is consistent and already proven — the same
  parity principle already used between `demo` and `testing`.

**3. Run provisioning** — exactly the same as demo, just a different
inventory name:

```bash
cd ansible/minikube
ansible-playbook site.yml -i inventory/staging
```

**4. Before actually using this for staging/production**, revisit
[9. Known Issues, Limitations, and Assumptions](#9-known-issues-limitations-and-assumptions)
— several choices that are reasonable for a demo **don't automatically carry
over** to a more serious tier:

- **Single replica** (Magento/MariaDB/Dragonfly) — consider HA if the new
  environment needs to survive a single pod restart without disruption.
- **Dragonfly has no persistence** — fine for a pure cache, but if the new
  environment needs sessions to survive a restart, add persistence or
  replication.
- **Traefik's `websecure` still uses a self-signed certificate** — if the new
  environment needs direct HTTPS access (not just via Cloudflare Tunnel), set
  up `cert-manager`/a real TLS secret first.
- **Replace every placeholder** (`cloudflared-tunnel-token`,
  `ghcr-credentials`) with real credentials before the environment goes
  genuinely public.
- **Consider a separate SSH key** per environment (rather than sharing one
  key, the current pattern), especially for production.

## 12. Reviewer Access

The demo VM currently lives at **`152.228.200.13`**. Reviewers can log in via
SSH using the shared `linode_vm` private key (path relative to the repo
root: `ssh/linode_vm`):

```bash
ssh -i ssh/linode_vm ubuntu@152.228.200.13
```

Reviewers do **not** have a kubeconfig file — that file
(`output/kubectl-demo.yaml`) is only generated on the control machine that
runs `ansible-playbook site.yml` (the operator's machine), it isn't copied
anywhere automatically. There are two ways to still run `kubectl` for
verification:

**Option A — run `kubectl` directly on the VM (recommended, fastest)**

Since Minikube on this VM uses `--driver=none`, kubelet runs directly on the
host and root's kubeconfig is already available on the VM itself — nothing
needs to be copied anywhere:

```bash
ssh -i ssh/linode_vm ubuntu@152.228.200.13
sudo kubectl --kubeconfig=/root/.kube/config get pods -n apps -n infrastructure
sudo kubectl --kubeconfig=/root/.kube/config exec -n apps deploy/magento -c php-fpm -- bin/magento cache:status
```

(`sudo` is required because `/root/.kube/config` is only readable by root —
this is `minikube start --driver=none`'s own default, not extra hardening
added by this repo.)

**Option B — copy the kubeconfig to your own machine**

If a reviewer wants to run `kubectl` from their own laptop instead (rather
than inside the VM over SSH):

```bash
ssh -i ssh/linode_vm ubuntu@152.228.200.13 "sudo cat /root/.kube/config" > ./kubeconfig-demo.yaml
export KUBECONFIG=./kubeconfig-demo.yaml
kubectl get pods -n apps -n infrastructure
```

> Note: the `server:` field inside that kubeconfig points at this same VM IP
> (`152.228.200.13`). If the VM's IP ever changes later (VM reset or
> replaced) while an old kubeconfig file is still around, `kubectl` will fail
> to connect ("connection refused"/timeout) — check and manually update the
> `server:` field to the currently active IP, or just re-fetch the kubeconfig
> with the command above.
