# Minikube on Ubuntu 24.04 — Ansible boilerplate

Provisions a single-node Kubernetes cluster with Minikube (docker driver) on an
Ubuntu 24.04 host, plus `kubectl`, `helm`, and `k9s`. The cluster runs as a
dedicated unprivileged `minikube` user under a systemd unit, so it survives
reboots.

## Layout

```
ansible.cfg                              # default inventory, ssh tuning
requirements.yml                         # galaxy collections
site.yml                                 # main playbook
reset.yml                                # stop + purge the cluster
inventory/demo/hosts.yml                 # the Linode host (group: minikube)
inventory/demo/group_vars/minikube.yml   # sizing/feature overrides — kept identical to testing's
inventory/testing/hosts.yml              # the throwaway Hyper-V host (group: minikube)
inventory/testing/group_vars/minikube.yml # sizing/feature overrides — kept identical to demo's
roles/common                             # base packages, apt keyring dir, swap, stale repo cleanup
roles/docker                             # Docker CE from download.docker.com
roles/kubectl                            # kubectl from pkgs.k8s.io
roles/helm                               # helm tarball from get.helm.sh (checksum verified)
roles/k9s                                # k9s .deb from github.com/derailed/k9s (checksum verified)
roles/minikube                           # user, binary, systemd unit, addons, kubeconfig
```

Each environment is a fully separate inventory directory: `hosts.yml` plus its
own `group_vars/`, both named `minikube` internally so `site.yml`/`reset.yml`
(`hosts: minikube`) work against either without changes.

## Prerequisites

```bash
ansible-galaxy collection install -r requirements.yml
```

The target host needs SSH access as root, or as a sudo-capable user. For the
non-root case the play needs a become password — either add `NOPASSWD` for the
login user or run with `--ask-become-pass`.

## Usage

Run from this directory. `ansible.cfg` defaults `inventory` to
`inventory/testing` — the throwaway box — so a bare invocation never touches
the demo host by accident; target it explicitly with `-i inventory/demo`.

```bash
ansible-playbook site.yml                                # testing (default)
ansible-playbook site.yml -i inventory/demo               # demo / Linode
ansible-playbook site.yml --check --diff                  # dry run
ansible-playbook site.yml --tags docker,minikube          # partial run
ansible-playbook reset.yml                                 # tear down testing
ansible-playbook reset.yml -i inventory/demo               # tear down demo
```

## Key variables

Shared tunables live as role defaults in `roles/*/defaults/main.yml`.
Per-environment overrides live in each inventory's own `group_vars/minikube.yml`.

| Variable | Default | Notes |
| --- | --- | --- |
| `minikube_version` | `latest` | or a tag such as `v1.36.0` |
| `minikube_kubernetes_version` | `v1.36.3` | keep in sync with `kubectl_apt_channel` |
| `kubectl_apt_channel` | `v1.36` | apt track at `pkgs.k8s.io`; bumping this alone is enough — the role releases kubectl's version hold, upgrades, and re-holds automatically |
| `minikube_driver` | `docker` | `none` runs kubelet directly on the host (needs the `cri-dockerd` role) instead of a docker/podman node container |
| `minikube_cpus` / `minikube_memory` | `2` / `4096` | MiB |
| `minikube_disk_size` | `30g` | |
| `minikube_nodes` | `1` | |
| `minikube_addons` | `default-storageclass`, `storage-provisioner`, `ingress`, `metrics-server` | |
| `minikube_extra_args` | `[]` | appended verbatim to `minikube start` |
| `minikube_start_cluster` | `true` | `false` installs everything but leaves the cluster down |
| `docker_version` | `latest` | pin e.g. `5:27.3.1-1~ubuntu.24.04~noble` |
| `common_disable_swap` | `true` | |
| `helm_install` | `true` | |
| `helm_version` | `latest` | resolves via `get.helm.sh/helm-latest-version`; currently Helm **4.x** — pin `v3.16.3` if you need Helm 3 |
| `common_retired_apt_files` | helm `.sources`/`.list`/keyring | cleared before the first `apt update` |
| `k9s_install` | `true` | |
| `k9s_version` | `latest` | resolves via the GitHub API, or pin a tag such as `v0.50.6` |
| `minikube_expose_apiserver` | `false` | `true` publishes the apiserver on `minikube_listen_address` and writes `output/kubectl-<env>.yaml` — see below |
| `minikube_listen_address` | `0.0.0.0` | bind address for the docker-published apiserver port (docker/podman driver only) |
| `minikube_remote_access_host` | `{{ ansible_host }}` | IP baked into the cert SAN and the exported kubeconfig's `server:` |
| `minikube_apiserver_port` | `8443` | in-cluster apiserver port; on the docker driver the *published* host port is auto-detected via `docker port` and may differ, on `--driver=none` it's the real host port directly |
| `minikube_env_name` | `{{ inventory_dir \| basename }}` | e.g. `demo` / `testing`; names the exported kubeconfig file |
| `minikube_enable_limited_swap` | `false` | manages swap via Kubernetes' `NodeSwap`/`LimitedSwap` instead of leaving it unmanaged — see below; only meaningful when `common_disable_swap` is `false` |

## Verifying

Everything runs as root now (`minikube_home` is `/root`), so no `sudo -iu`
is needed:

```bash
ssh <host> 'kubectl get nodes -o wide'
ssh <host> 'minikube status'
ssh <host> 'k9s version --short'
```

`k9s`/`kubectl` read `/root/.kube/config`, which points at the cluster's
internal IP (e.g. `192.168.49.2`), so it's only usable from the VM itself —
for remote access without opening anything, use `kubectl --kubeconfig` over
an SSH tunnel or `minikube tunnel` instead of the option below.

## Remote access (`output/kubectl-<env>.yaml`)

Enabled for both environments (`minikube_expose_apiserver: true` in both
group_vars files — applied and verified on testing. 
When on, the `minikube` role will:

1. Start minikube with `--listen-address={{ minikube_listen_address }}` so
   Docker publishes the apiserver port on every interface instead of just
   `127.0.0.1`, and `--apiserver-ips={{ minikube_remote_access_host }}` so the
   server cert is valid for that address.
2. Auto-detect the actual published host port with `docker port` — minikube
   picks a random one, it is *not* the same as `minikube_apiserver_port`.
3. Take the cluster's cert-embedded kubeconfig, rewrite its `server:` line to
   `https://<minikube_remote_access_host>:<published port>`, and write it to
   `output/kubectl-{{ minikube_env_name }}.yaml` **on the machine running
   Ansible** (not the target host) via `delegate_to: localhost`. `env_name`
   defaults to the loaded inventory directory's name (`demo` / `testing`), so
   both environments can be exposed at once without clobbering each other's
   file. Already gitignored (`output/kubectl*.yaml`).

```bash
kubectl --kubeconfig=output/kubectl-testing.yaml get nodes
```

Changing `minikube_listen_address` / `minikube_remote_access_host` /
`minikube_apiserver_port` on an existing cluster has no effect until it's
recreated — run `reset.yml` first, then `site.yml` again.

This publishes the Kubernetes API on a public interface, protected only by the
mutual-TLS client cert in that kubeconfig.

## Managed swap (`minikube_enable_limited_swap`)

Enabled for both environments — `common_disable_swap: false` /
`minikube_enable_limited_swap: true` in both group_vars files: swap stays on
(not disabled), and Kubernetes actually manages it rather than either
ignoring it or turning it off outright.

The `common` role's swap handling is two-directional: flipping
`common_disable_swap` back to `false` on a host that had previously been
disabled doesn't just skip the disable step, it actively uncomments the
`/etc/fstab` entry and runs `swapon -a` to restore it — otherwise a host that
was ever disabled would stay disabled forever regardless of what the variable
said, since nothing would ever turn it back on.

If `common_disable_swap: false`, the node has swap and Kubernetes doesn't know
about it: minikube unconditionally sets `failSwapOn: false` in the generated
`KubeletConfiguration`, which is only "don't refuse to start" — not the actual
`NodeSwap`/`LimitedSwap` support Kubernetes has had since KEP-2400. There's no
way to reach `memorySwap.swapBehavior` through minikube's own `--feature-gates`
or `--extra-config` flags (the latter only whitelists 4 unrelated kubelet
keys), so this role patches the generated
`/var/lib/kubelet/config.yaml` **inside the node container** directly —
setting `memorySwap.swapBehavior: LimitedSwap` and `featureGates.NodeSwap:
true` — then restarts kubelet. Requires cgroup v2 on the node (check with
`docker exec minikube stat -fc %T /sys/fs/cgroup`; want `cgroup2fs`).

Since minikube regenerates that file from scratch on every `kubeadm init`,
this re-applies itself automatically after `reset.yml` + `site.yml`, gated by
an idempotency check (`grep` for both settings) so normal re-runs are a no-op.

Once applied, containers **with** a memory limit set correctly get denied
swap (`memory.swap.max: 0` in their cgroup — LimitedSwap's actual policy),
while limit-less containers keep unrestricted access (`max`). Verify:

```bash
ssh <host> 'sudo docker exec minikube grep -A1 memorySwap /var/lib/kubelet/config.yaml'
```

## Sizing notes

Minikube compares `minikube_memory` against what Docker currently sees and
hard-fails (`MK_USAGE`) when the request is larger — `--force` only downgrades
the separate "less than the required 1800MiB" check to a warning, it does not
bypass this one. The testing VM has since been resized to match the demo/Linode 
box's real allocation (~3.9-4.0 GiB, 2 vCPUs) — `inventory/testing/group_vars/minikube.yml`
sets `minikube_memory: 2800` (comfortably under that, leaving host/docker
overhead) and relies on the role default `minikube_cpus: 2` to match. `--force`
stays in `minikube_extra_args` as a safety net for the (now less likely, but
not impossible) case where the balloon hasn't caught up yet at boot.

For a real cluster, size `minikube_memory` to a couple GB under the host's
actual RAM and `minikube_cpus` to the host's real core count, with no `--force`
needed once you're confident MemTotal is stable.
