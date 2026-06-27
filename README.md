# LadybugDB on GKE Autopilot

Deploy [LadybugDB](https://ladybugdb.com) — an embedded columnar graph database — on Google Kubernetes Engine (GKE) Autopilot, with the database file persisted in Google Cloud Storage (GCS) via the Cloud Storage FUSE CSI driver.

## Architecture

```
                         ┌──────────────────────────────────────────────────┐
                         │              GKE Autopilot Cluster               │
                         │                                                  │
  Browser / UI ────────► │  ┌────────────────────────────────────────────┐ │
                         │  │   Pod: ladybugdb-explorer (READ_WRITE)     │ │
                         │  │   ghcr.io/ladybugdb/explorer:latest        │ │
                         │  │   port 8000  →  svc/ladybugdb-explorer:80  │ │
                         │  │   /database/database.lbdb  (read-write)    │ │
                         │  └──────────────────┬─────────────────────────┘ │
                         │                     │                            │
  AI Agent / MCP ──────► │  ┌──────────────────┼─────────────────────────┐ │
  Client                 │  │   Pod: ladybugdb-mcp-server (read-only)    │ │
                         │  │   ghcr.io/ladybugdb/mcp-server-ladybug     │ │
                         │  │   port 8080  →  svc/ladybugdb-mcp-server:80│ │
                         │  │   /database/database.lbdb  (read-only)     │ │
                         │  └──────────────────┬─────────────────────────┘ │
                         │                     │                            │
                         │          gcsfuse sidecars (injected by GKE)     │
                         └─────────────────────┼────────────────────────────┘
                                               │ FUSE mount
                                               ▼
                                      ┌─────────────────┐
                                      │  GCS Bucket     │
                                      │  database.lbdb  │
                                      └─────────────────┘
```

**Key design decisions:**

- **Single writer**: LadybugDB is an embedded database. Running multiple write-capable replicas against the same file will corrupt data. The Explorer deployment is locked to `replicas: 1` with a `Recreate` strategy.
- **MCP server is read-only**: The MCP server mounts the same GCS-backed PVC with `readOnly: true`, so AI agents can query the graph without risking write conflicts with the Explorer.
- **GCS FUSE CSI driver**: Enabled by default on GKE Autopilot clusters. The sidecar container is injected automatically via the pod annotation `gke-gcsfuse/volumes: "true"`.
- **Workload Identity**: The Kubernetes Service Account is bound to a GCP Service Account that has `storage.objectAdmin` on the GCS bucket — no long-lived credentials in the cluster.

## Repository structure

```
.
├── .env.example          # Copy to .env and fill in your values
├── Makefile              # Convenience targets
├── k8s/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── serviceaccount.yaml   # K8s SA with Workload Identity annotation
│   ├── pv.yaml               # PersistentVolume → GCS bucket
│   ├── pvc.yaml              # PersistentVolumeClaim
│   ├── deployment.yaml           # LadybugDB Explorer deployment (READ_WRITE)
│   ├── service.yaml              # ClusterIP service for Explorer
│   ├── mcp-server-deployment.yaml  # LadybugDB MCP server (read-only)
│   └── mcp-server-service.yaml     # ClusterIP service for MCP server
└── scripts/
    ├── setup-gcp.sh          # Provision GCP resources
    └── teardown.sh           # Remove all resources
```

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| `gcloud` CLI | 460+ |
| `kubectl` | 1.28+ |
| `make` | any |

Your `gcloud` account needs the following roles on the GCP project:
- `roles/container.admin`
- `roles/storage.admin`
- `roles/iam.serviceAccountAdmin`
- `roles/iam.workloadIdentityPoolAdmin`

## Quick start

### 1. Configure environment

```bash
cp .env.example .env
# Edit .env with your GCP project ID, bucket name, region, etc.
set -a && source .env && set +a
```

### 2. Provision GCP resources

```bash
make setup-gcp
```

This script:
1. Enables the required GCP APIs (`container`, `storage`, `iam`)
2. Creates a GKE Autopilot cluster with Workload Identity enabled
3. Creates a GCS bucket with versioning and a 30-day non-current version lifecycle
4. Creates a GCP Service Account and grants it `storage.objectAdmin` on the bucket
5. Binds the GCP Service Account to the Kubernetes Service Account via Workload Identity

> **Note:** Cluster creation takes ~5 minutes.

### 3. Deploy LadybugDB

```bash
make deploy
make rollout   # waits until pods are Ready
make status    # shows pods, services, and PVC
```

### 4. Access LadybugDB Explorer

**Option A — Port-forward (recommended for dev):**

```bash
make port-forward
# Open http://localhost:8000
```

**Option B — LoadBalancer (for production external access):**

Edit `k8s/service.yaml`, uncomment the `LoadBalancer` service block, then:

```bash
kubectl apply -f k8s/service.yaml -n ladybugdb
kubectl get svc ladybugdb-explorer-lb -n ladybugdb
# Wait for EXTERNAL-IP, then open http://<EXTERNAL-IP>
```

### 5. Access the MCP server

The MCP server exposes an SSE endpoint for AI agents and MCP clients.

**From inside the cluster** (e.g. another pod or agent):

```
http://ladybugdb-mcp-server.ladybugdb.svc.cluster.local/sse
```

**Port-forward for local testing:**

```bash
kubectl port-forward -n ladybugdb svc/ladybugdb-mcp-server 8080:80
# Connect your MCP client to: http://localhost:8080/sse
```

**Claude Desktop / MCP client config example:**

```json
{
  "mcpServers": {
    "ladybugdb": {
      "transport": "sse",
      "url": "http://localhost:8080/sse"
    }
  }
}
```

## Configuration reference

### Environment variables (`.env`)

| Variable | Description | Example |
|----------|-------------|---------|
| `PROJECT_ID` | GCP project ID | `my-project-123` |
| `REGION` | GCP region for cluster and bucket | `us-central1` |
| `CLUSTER_NAME` | GKE cluster name | `ladybugdb-cluster` |
| `BUCKET_NAME` | GCS bucket name (globally unique) | `ladybugdb-db-my-project` |
| `NAMESPACE` | Kubernetes namespace | `ladybugdb` |
| `GSA_NAME` | GCP Service Account name | `ladybugdb-gsa` |
| `KSA_NAME` | Kubernetes Service Account name | `ladybugdb-sa` |

### LadybugDB environment variables (`k8s/deployment.yaml`)

| Variable | Description | Default |
|----------|-------------|---------|
| `LBUG_FILE` | Database filename in `/database` | `database.lbdb` |
| `MODE` | `READ_WRITE` or `READ_ONLY` | `READ_WRITE` |
| `LBUG_BUFFER_POOL_SIZE` | Buffer pool in bytes | `1073741824` (1 GB) |

## Operational notes

### Scaling

LadybugDB Explorer supports a read-only mode (`MODE=READ_ONLY`). You can run additional read-only pods that mount the GCS bucket in read-only mode:

```bash
kubectl scale deployment/ladybugdb-explorer --replicas=1 -n ladybugdb  # writer
```

To add read-only replicas, duplicate `k8s/deployment.yaml`, set `MODE: READ_ONLY` and add `readOnly: true` to the `volumeMount`.

### Backup

Because the database lives in GCS with versioning enabled, you can restore any previous state:

```bash
# List object versions
gsutil ls -a gs://${BUCKET_NAME}/database.lbdb

# Restore a specific version
gsutil cp "gs://${BUCKET_NAME}/database.lbdb#<generation>" \
          gs://${BUCKET_NAME}/database.lbdb
```

### Updating LadybugDB

```bash
kubectl rollout restart deployment/ladybugdb-explorer -n ladybugdb
kubectl rollout status  deployment/ladybugdb-explorer -n ladybugdb
```

The `Recreate` strategy ensures the old pod terminates (releasing the GCS FUSE file lock) before the new pod starts.

### Resource tuning

Default resource requests in `k8s/deployment.yaml`:

```yaml
requests:
  cpu: "500m"
  memory: "1Gi"
limits:
  memory: "2Gi"
```

GKE Autopilot provisions nodes to satisfy requests exactly, so right-size based on your workload. The `LBUG_BUFFER_POOL_SIZE` should be less than the pod memory limit.

## Cleanup

```bash
make destroy
```

> **Warning:** This deletes the GCS bucket and **all database data**. The GKE cluster itself is NOT deleted (it may be shared). Delete it separately if needed:
> ```bash
> gcloud container clusters delete ${CLUSTER_NAME} --region ${REGION}
> ```

## Troubleshooting

**Pod stuck in `Pending`**

GKE Autopilot may take 1–2 minutes to provision a new node. Check:
```bash
kubectl describe pod -l app=ladybugdb-explorer -n ladybugdb
kubectl get events -n ladybugdb --sort-by='.lastTimestamp'
```

**GCS FUSE mount failing**

Verify Workload Identity is correctly configured:
```bash
kubectl exec -it -n ladybugdb \
  $(kubectl get pod -l app=ladybugdb-explorer -n ladybugdb -o name) \
  -c explorer -- ls /database
```

Check the sidecar logs:
```bash
kubectl logs -n ladybugdb \
  $(kubectl get pod -l app=ladybugdb-explorer -n ladybugdb -o name) \
  -c gke-gcsfuse-sidecar
```

**Permission denied on GCS bucket**

Re-run the Workload Identity binding in `scripts/setup-gcp.sh` or verify:
```bash
gcloud iam service-accounts get-iam-policy \
  ${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com
```

## References

- [LadybugDB documentation](https://docs.ladybugdb.com)
- [LadybugDB GitHub](https://github.com/LadybugDB/ladybug)
- [LadybugDB Explorer Docker image](https://github.com/LadybugDB/explorer)
- [GKE Cloud Storage FUSE CSI driver](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/cloud-storage-fuse-csi-driver)
- [GKE Autopilot overview](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview)
- [Workload Identity for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
