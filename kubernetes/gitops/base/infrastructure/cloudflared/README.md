# Cloudflared Tunnel

## Required Secret

Cloudflared needs a tunnel token to connect to Cloudflare's global network.
A placeholder secret was created by Ansible with a dummy token.

### To update with your real tunnel token:

1. Create a tunnel in the Cloudflare dashboard (Networking > Tunnels > Create a tunnel)
2. Copy the tunnel token (`eyJhIjoi...`)
3. Replace the placeholder secret:

```sh
kubectl delete secret cloudflared-tunnel-token --namespace infrastructure
kubectl create secret generic cloudflared-tunnel-token \
  --namespace infrastructure \
  --from-literal=token=eyJhIjoi...
```

4. Restart the cloudflared deployment:

```sh
kubectl rollout restart deployment cloudflared --namespace infrastructure
```

## Architecture

Cloudflared runs as a sidecar-like Deployment inside the cluster and creates
outbound-only connections to Cloudflare. It proxies traffic to Kubernetes
services based on routes configured in the Cloudflare dashboard (Networking >
Tunnels > select your tunnel > Routes tab).
