# Magento di Kubernetes (Minikube) — GitOps dengan FluxCD

> Lihat [README_EN.md](README_EN.md) untuk versi bahasa Inggris.

Repo ini menjalankan Magento Open Source ke sebuah cluster Minikube single-node,
di-provision otomatis lewat Ansible dan disinkronkan lewat FluxCD (GitOps) dari
direktori `kubernetes/gitops/`. Image aplikasi (`magento/`) dan konfigurasi
cluster (`kubernetes/gitops/`, `ansible/`) berada di repo yang sama.

## 1. Prasyarat dan Spesifikasi Mesin

- **OS target**: Ubuntu 24.04 LTS (di-*assert* di awal playbook — akan gagal
  jika bukan 24.04+).
- **Sumber daya minimum** (yang sudah teruji cukup untuk `minikube_cpus: 2`,
  `minikube_memory: 2800`): ~2 vCPU, ~2.8–4 GiB RAM, ~50 GB disk kosong.
- **Akses SSH** root/berupa user dengan sudo, dengan key pair yang sudah
  didaftarkan ke host target (VM Linode demo).
- **Mesin kontrol** (tempat menjalankan Ansible): `ansible`, `ansible-playbook`,
  `git`, dan akses SSH ke host target. `kubectl`/`helm`/`flux` CLI di-install
  otomatis oleh playbook *di host target*, bukan di mesin kontrol.
- **Akun GitHub** dengan akses ke repo ini via SSH deploy key (untuk FluxCD
  menarik `kubernetes/gitops/`), dan (opsional) GHCR untuk image
  `ghcr.io/yosefadi/minikube-magento/*` kalau private.
- **Cloudflare Tunnel token** (opsional, untuk expose publik lewat
  `cloudflared`) — kalau tidak diisi, secret-nya dibuat sebagai placeholder
  dan tidak akan benar-benar connect.
- Domain publik sudah dikonfigurasi di
  `kubernetes/gitops/overlays/demo/magento-base-url-patch.yaml`.

## 2. Versi Komponen

| Komponen | Versi |
| --- | --- |
| Magento Open Source | 2.4.9 (`magento/magento2` GitHub mirror, bukan repo.magento.com) |
| PHP | 8.5 (`php:8.5-fpm-trixie`, base image Debian Trixie) |
| Database | MariaDB 12.3 |
| Search engine | OpenSearch (chart `3.x`, image tag `2`) |
| Cache/session | DragonflyDB v1.39.0 (kompatibel protokol Redis) |
| Web server | nginx (image terpisah, tanpa interpreter PHP) + PHP-FPM (image terpisah) |
| Ingress controller | Traefik (chart `41.x`), expose via **NodePort** 30080 (web) / 30443 (websecure) |
| GitOps | FluxCD (chart `flux2` v2.19.0) |
| Kubernetes | Minikube, driver `none` (kubelet langsung di host, bukan di dalam container) |

Admin path Magento sengaja **bukan default** — diset ke `/panel`
(`MAGENTO_BACKEND_FRONTNAME`), bukan `/admin`.

## 3. Menjalankan Minikube dan Mengaktifkan Ingress

Semua ini otomatis lewat satu perintah Ansible (lihat bagian 4), tapi
ringkasan apa yang sebenarnya terjadi:

1. Role `minikube` menjalankan `minikube start` dengan `--driver=none` —
   kubelet berjalan langsung di host (bukan di dalam kontainer Docker), jadi
   perlu `cri-dockerd` sebagai shim CRI ke Docker.
2. Addon `metrics-server` diaktifkan; addon bawaan `storage-provisioner` dan
   `default-storageclass` dimatikan karena storage class default-nya diganti
   ke `openebs-hostpath`.
3. Ingress **tidak** memakai addon `ingress` bawaan Minikube — Traefik
   di-install lewat FluxCD `HelmRelease` di Kustomization terpisah
   (`flux-traefik`), yang harus selesai *Ready* dulu (CRD `IngressRoute`
   ter-registrasi) sebelum Kustomization utama (yang berisi resource
   `IngressRoute` untuk Magento) dijalankan — dua Kustomization ini
   dihubungkan lewat `dependsOn` persis seperti pola `flux-storage` untuk
   OpenEBS.
4. Traefik di-expose sebagai `NodePort` (bukan `LoadBalancer`, karena Minikube
   di VM cloud/on-prem tidak punya cloud controller) — bisa diakses langsung
   di `<ip-node>:30080` (HTTP) atau `:30443` (HTTPS, sertifikat self-signed
   bawaan Traefik selama belum ada `cert-manager`/secret TLS asli).

## 4. Deployment dari Awal hingga Aplikasi Siap

```bash
git clone git@github.com:yosefadi/minikube-magento.git
cd minikube-magento/ansible/minikube

# Pastikan inventory/demo/hosts.yml menunjuk ke IP VM target dan path
# private key yang benar.

ansible-playbook site.yml -i inventory/demo
```

Urutan yang dijalankan playbook (`site.yml`):

1. `common` — paket dasar, swap, direktori CNI untuk driver `none`.
2. `kubectl`, `helm`, `k9s`, `flux-cli` — install tool CLI.
3. `docker`, `cri-dockerd` — runtime kontainer + shim CRI.
4. `minikube` — start cluster, atur addon dan StorageClass default.
5. `infrastructure-secrets` — generate credential MariaDB & Dragonfly (namespace
   `infrastructure`), *idempotent*: rerun tidak akan meng-generate ulang kalau
   secret sudah ada.
6. `apps-secrets` — salin credential DB/Dragonfly ke namespace `apps`, generate
   password admin Magento (juga idempotent).
7. `fluxcd` — install FluxCD via Helm, setup `GitRepository` + 3
   `Kustomization` (`flux-storage` → `flux-traefik` → `flux` utama, berurutan
   lewat `dependsOn`).

Setelah playbook selesai, Flux akan menyinkronkan
`kubernetes/gitops/overlays/demo/`, yang men-deploy: namespace, MariaDB,
OpenSearch, Dragonfly, cloudflared, Traefik, NetworkPolicy, dan Deployment
Magento (kontainer `php-fpm` + `nginx` terpisah). Pada boot pertama, kontainer
`php-fpm` menunggu MariaDB/OpenSearch/Dragonfly siap lalu menjalankan
`setup:install`, `setup:static-content:deploy`, dan mengarahkan
cache/session ke Dragonfly.

Cek status akhir:

```bash
export KUBECONFIG=./output/kubectl-demo.yaml   # dibuat otomatis oleh role minikube
kubectl get kustomization -n flux-system
kubectl get pods -n apps -n infrastructure
```

Magento siap ketika pod `magento-xxx` menunjukkan `2/2 Running`.

## 5. Mendapatkan URL Publik dan Mengakses Admin

Ada dua jalur akses:

- **Lewat Cloudflare Tunnel** (jalur publik "resmi") — domain diatur di
  `MAGENTO_BASE_URL` pada overlay demo (`demo-magento.yosefadi.my.id`),
  TLS di-terminate di edge Cloudflare. Perlu token tunnel asli di secret
  `cloudflared-tunnel-token`.
- **Lewat Traefik NodePort** langsung ke IP VM, port `30080`/`30443` — perlu
  `Host` header yang cocok karena `IngressRoute` mencocokkan berdasarkan
  domain:
  ```bash
  curl -H "Host: demo-magento.yosefadi.my.id" http://<ip-node>:30080/
  ```

**Login admin**: buka `<base-url>/panel`. Username/password diambil dari
secret `magento-credentials` di namespace `apps`:

```bash
kubectl get secret magento-credentials -n apps -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl get secret magento-credentials -n apps -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## 6. Verifikasi Fungsi Utama

```bash
# Semua pod hidup
kubectl get pods -n apps -n infrastructure

# Storefront merender (bukan sekadar 200 kosong)
curl -s http://<akses-di-atas>/ | grep -o '<title>.*</title>'

# DB & search engine benar-benar terhubung (bukan cuma status container)
kubectl exec -n apps deploy/magento -c php-fpm -- bin/magento indexer:status

# Cache & session benar-benar dipakai (bukan fallback ke filesystem)
kubectl exec -n apps deploy/magento -c php-fpm -- bin/magento cache:status
```

Login ke `/panel` dengan credential di atas untuk verifikasi admin. Kalau
storefront merender dengan CSS/JS (bukan halaman polos), berarti
`static-content:deploy` juga sudah berhasil.

## 7. Backup dan Restore

Repo ini **tidak** menyediakan tool backup/restore otomatis — berikut prosedur
manual yang mencakup semua state yang perlu diselamatkan (database, konfigurasi
`app/etc`, media upload, dan secrets).

**Backup:**

```bash
# Database
kubectl exec -n infrastructure mariadb-0 -- \
  mariadb-dump -u root -p"$(kubectl get secret mariadb-credentials -n infrastructure -o jsonpath='{.data.root-password}' | base64 -d)" \
  --all-databases > backup-db-$(date +%F).sql

# app/etc (encryption key, konfigurasi env.php) dan media upload
kubectl cp apps/<nama-pod-magento>:/var/www/html/app/etc ./backup-app-etc -c php-fpm
kubectl cp apps/<nama-pod-magento>:/var/www/html/pub/media ./backup-media -c php-fpm

# Secrets (berisi semua password — jangan commit ke git!)
kubectl get secret mariadb-credentials -n infrastructure -o yaml > backup-secret-mariadb.yaml
kubectl get secret dragonfly-credentials -n infrastructure -o yaml > backup-secret-dragonfly.yaml
kubectl get secret magento-credentials -n apps -o yaml > backup-secret-magento.yaml
```

**Restore** (urutan terbalik — pastikan cluster/namespace sudah ada dulu):

```bash
kubectl apply -f backup-secret-mariadb.yaml -f backup-secret-dragonfly.yaml -f backup-secret-magento.yaml

kubectl exec -i -n infrastructure mariadb-0 -- \
  mariadb -u root -p"<root-password>" < backup-db-YYYY-MM-DD.sql

kubectl cp ./backup-app-etc apps/<nama-pod-magento>:/var/www/html/app/etc -c php-fpm
kubectl cp ./backup-media apps/<nama-pod-magento>:/var/www/html/pub/media -c php-fpm

kubectl rollout restart deployment/magento -n apps
```

> **Penting**: PVC (`magento-etc`, `magento-static`, `magento-media`, data
> MariaDB) memakai StorageClass `openebs-hostpath` dengan reclaim policy
> default (`Delete`). Menghapus PVC atau namespace-nya **menghapus data**,
> — jadi backup di atas perlu dilakukan **sebelum** menjalankan `reset.yml` 
> jika datanya masih dibutuhkan.

## 8. Cara Cleanup Environment

```bash
cd ansible/minikube
ansible-playbook reset.yml -i inventory/demo
```

`reset.yml` menghentikan cluster Minikube, menghapus seluruh state Minikube +
Kubernetes di host (`/var/lib/minikube`, `/etc/kubernetes`, dll.), uninstall
FluxCD, dan menghapus namespace `infrastructure` + `apps` (**termasuk semua
PVC dan datanya**, lihat catatan di atas).

`reset.yml` **tidak** meng-uninstall paket yang di-install `site.yml`
(Docker, kubectl, Helm, dll.) — itu tetap ada di host supaya `site.yml` bisa
dijalankan ulang dengan cepat. Untuk membersihkan VM sepenuhnya kembali ke OS
default (misalnya sebelum melepas VM sewaan), perlu langkah manual tambahan
(purge paket, hapus repo apt, dsb.) — tidak ada script otomatis untuk ini di
repo.

## 9. Known Issues, Limitation, dan Asumsi

- **Single replica** — Magento, MariaDB, Dragonfly semua `replicas: 1`, tidak
  ada HA/failover.
- **Dragonfly tanpa persistence** — cache/session hilang saat restart pod
  (dirancang untuk cache murni).
- **Cron belum di-wire** — `bin/magento cron:run` tidak dijadwalkan (tidak ada
  indexing terjadwal, email queue, dll).
- **Backend cache string harus literal `"redis"`** — fork Magento ini
  mengganti resolusi backend cache Zend_Cache lama dengan
  `SymfonyAdapterProvider` custom yang cuma mengenali string spesifik
  (`redis`, `valkey`, dst). String klasik `Cm_Cache_Backend_Redis` dari
  dokumentasi resmi Magento **tidak berfungsi** di sini — gagal diam-diam
  (fallback ke filesystem, tanpa error).
- **LimitedSwap (KEP-2400) hanya untuk driver `none`** — dengan driver
  `docker`, kubelet jalan di dalam kontainer node sehingga
  `/var/lib/kubelet/config.yaml` di host tidak ada; belum diimplementasi
  jalur setara untuk driver `docker`.
- **Traefik `websecure` pakai sertifikat self-signed default** — belum ada
  `cert-manager`/secret TLS asli; jalur publik yang benar-benar terenkripsi
  saat ini hanya lewat Cloudflare Tunnel.
- **GHCR pull secret & Cloudflare Tunnel token** dibuat sebagai placeholder
  oleh Ansible kalau belum ada — perlu diganti manual dengan token asli.
- **Akses SSH satu key bersama** — pola umum di VM demo: login SSH
  menggunakan satu private key yang sama, tidak ada akun per-orang/audit trail.
- **Asumsi OS**: Ubuntu 24.04 LTS spesifik (di-*assert* di awal playbook).
- **Asumsi sumber daya**: ~2 vCPU / ~2.8–4 GiB RAM cukup untuk workload demo
  ini; di luar itu belum diuji.

## 10. Estimasi Waktu Pengerjaan

Berdasarkan pengujian langsung di sesi ini (VM 2 vCPU / ~2.8 GiB RAM):

| Tahap | Estimasi waktu |
| --- | --- |
| Provisioning Ansible (Docker, kubectl, Helm, Minikube start) | ~5–10 menit |
| Sinkronisasi Flux (infra: MariaDB, OpenSearch, Dragonfly, Traefik) | ~2–5 menit |
| Boot pertama Magento (`setup:install` + `static-content:deploy`) | ~5–15 menit (budget maksimum di-set 30 menit lewat `startupProbe`, untuk mengakomodasi host yang lambat) |
| **Total, deploy pertama dari nol** | **~15–30 menit** |
| Rerun berikutnya (volume sudah ada, `setup:upgrade` saja) | ~2–5 menit |

Waktu bisa lebih lama tergantung kecepatan koneksi (pull image, download
paket apt) dan kecepatan disk/CPU host.
