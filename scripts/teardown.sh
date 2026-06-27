#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# teardown.sh — Remove all GCP and Kubernetes resources for LadybugDB
#
# WARNING: This will delete the GCS bucket and all database data.
#          Ensure you have a backup before running this script.
# ---------------------------------------------------------------------------

: "${PROJECT_ID:?Set PROJECT_ID in .env}"
: "${REGION:?Set REGION in .env}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME in .env}"
: "${BUCKET_NAME:?Set BUCKET_NAME in .env}"
: "${NAMESPACE:?Set NAMESPACE in .env}"
: "${GSA_NAME:?Set GSA_NAME in .env}"

GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "WARNING: This will permanently delete:"
echo "  - Kubernetes namespace: ${NAMESPACE} (and all resources in it)"
echo "  - GCS bucket: gs://${BUCKET_NAME} (and ALL database data)"
echo "  - GCP Service Account: ${GSA_EMAIL}"
echo ""
read -r -p "Type 'yes' to confirm: " confirm
if [[ "${confirm}" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

echo "==> Deleting Kubernetes resources"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true
kubectl delete pv ladybugdb-pv --ignore-not-found=true

echo "==> Deleting GCS bucket: gs://${BUCKET_NAME}"
gsutil -m rm -r "gs://${BUCKET_NAME}" || true

echo "==> Deleting GCP Service Account: ${GSA_EMAIL}"
gcloud iam service-accounts delete "${GSA_EMAIL}" \
  --project "${PROJECT_ID}" --quiet || true

echo ""
echo "==> Teardown complete."
echo "Note: The GKE cluster '${CLUSTER_NAME}' was NOT deleted."
echo "      Run 'gcloud container clusters delete ${CLUSTER_NAME} --region ${REGION}' to remove it."
