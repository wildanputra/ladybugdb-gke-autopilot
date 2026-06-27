#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup-gcp.sh — Provision GCP resources required for LadybugDB on GKE
#
# What this script does:
#   1. Creates a GCS bucket for database storage
#   2. Creates a GCP Service Account (GSA)
#   3. Grants the GSA read/write access to the GCS bucket
#   4. Enables Workload Identity between the K8s SA and the GSA
#   5. Creates an Autopilot GKE cluster (if it doesn't already exist)
#
# Prerequisites:
#   - gcloud CLI authenticated and configured
#   - kubectl configured (or run after --get-credentials)
#   - Source .env before running: set -a && source .env && set +a
# ---------------------------------------------------------------------------

: "${PROJECT_ID:?Set PROJECT_ID in .env}"
: "${REGION:?Set REGION in .env}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME in .env}"
: "${BUCKET_NAME:?Set BUCKET_NAME in .env}"
: "${NAMESPACE:?Set NAMESPACE in .env}"
: "${GSA_NAME:?Set GSA_NAME in .env}"
: "${KSA_NAME:?Set KSA_NAME in .env}"

GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> Setting active project to ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

echo "==> Enabling required APIs"
gcloud services enable \
  container.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com

# ---------------------------------------------------------------------------
# GKE Autopilot cluster
# ---------------------------------------------------------------------------
if ! gcloud container clusters describe "${CLUSTER_NAME}" \
    --region "${REGION}" --quiet 2>/dev/null; then
  echo "==> Creating GKE Autopilot cluster: ${CLUSTER_NAME}"
  gcloud container clusters create-auto "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" \
    --workload-pool="${PROJECT_ID}.svc.id.goog"
else
  echo "==> Cluster ${CLUSTER_NAME} already exists, skipping creation"
fi

echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}"

# ---------------------------------------------------------------------------
# GCS bucket
# ---------------------------------------------------------------------------
if ! gsutil ls -b "gs://${BUCKET_NAME}" 2>/dev/null; then
  echo "==> Creating GCS bucket: gs://${BUCKET_NAME}"
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${BUCKET_NAME}"
  gsutil versioning set on "gs://${BUCKET_NAME}"
  gsutil lifecycle set - "gs://${BUCKET_NAME}" <<'EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {
        "age": 30,
        "isLive": false
      }
    }
  ]
}
EOF
else
  echo "==> Bucket gs://${BUCKET_NAME} already exists, skipping"
fi

# Prevent public access
gsutil pap set enforced "gs://${BUCKET_NAME}"

# ---------------------------------------------------------------------------
# GCP Service Account
# ---------------------------------------------------------------------------
if ! gcloud iam service-accounts describe "${GSA_EMAIL}" --quiet 2>/dev/null; then
  echo "==> Creating GCP Service Account: ${GSA_EMAIL}"
  gcloud iam service-accounts create "${GSA_NAME}" \
    --display-name "LadybugDB GKE Service Account" \
    --project "${PROJECT_ID}"
else
  echo "==> Service account ${GSA_EMAIL} already exists, skipping"
fi

echo "==> Granting ${GSA_EMAIL} read/write access to gs://${BUCKET_NAME}"
gsutil iam ch "serviceAccount:${GSA_EMAIL}:roles/storage.objectAdmin" \
  "gs://${BUCKET_NAME}"

# ---------------------------------------------------------------------------
# Workload Identity binding
# ---------------------------------------------------------------------------
echo "==> Binding K8s SA ${KSA_NAME} to GSA ${GSA_EMAIL} via Workload Identity"
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
  --project "${PROJECT_ID}"

echo ""
echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Edit k8s/serviceaccount.yaml — replace PROJECT_ID with: ${PROJECT_ID}"
echo "  2. Edit k8s/pv.yaml             — replace BUCKET_NAME with: ${BUCKET_NAME}"
echo "  3. Run: make deploy"
