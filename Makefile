# ---------------------------------------------------------------------------
# Makefile — LadybugDB on GKE Autopilot
#
# Usage:
#   cp .env.example .env          # fill in your values
#   set -a && source .env && set +a
#   make setup-gcp                 # provision GCP resources
#   make deploy                    # deploy LadybugDB to GKE
# ---------------------------------------------------------------------------

# Load .env if present
-include .env
export

NAMESPACE   ?= ladybugdb
KUBE_APPLY  := kubectl apply -f

.PHONY: help setup-gcp deploy destroy status port-forward port-forward-mcp \
        rollout rollout-mcp patch-sa patch-pv

help:
	@echo ""
	@echo "LadybugDB GKE Autopilot — available targets"
	@echo "--------------------------------------------"
	@echo "  setup-gcp         Provision GCP resources (bucket, SA, Workload Identity, cluster)"
	@echo "  deploy            Apply all Kubernetes manifests"
	@echo "  status            Show pod and service status"
	@echo "  rollout           Wait for Explorer deployment rollout to complete"
	@echo "  rollout-mcp       Wait for MCP server deployment rollout to complete"
	@echo "  port-forward      Forward localhost:8000 to the LadybugDB Explorer"
	@echo "  port-forward-mcp  Forward localhost:8080 to the LadybugDB MCP server"
	@echo "  destroy           Remove all Kubernetes and GCP resources (irreversible!)"
	@echo ""

# ---------------------------------------------------------------------------
# Provision GCP resources
# ---------------------------------------------------------------------------
setup-gcp:
	@bash scripts/setup-gcp.sh

# ---------------------------------------------------------------------------
# Patch manifests with real values and deploy
# ---------------------------------------------------------------------------
deploy: _check-env patch-sa patch-pv
	$(KUBE_APPLY) k8s/namespace.yaml
	$(KUBE_APPLY) k8s/serviceaccount.yaml
	$(KUBE_APPLY) k8s/pv.yaml
	$(KUBE_APPLY) k8s/pvc.yaml
	$(KUBE_APPLY) k8s/deployment.yaml
	$(KUBE_APPLY) k8s/service.yaml
	$(KUBE_APPLY) k8s/mcp-server-deployment.yaml
	$(KUBE_APPLY) k8s/mcp-server-service.yaml
	@echo ""
	@echo "Deployment submitted. Run 'make rollout' and 'make rollout-mcp' to wait for pods."

patch-sa:
	@echo "==> Patching serviceaccount.yaml with PROJECT_ID=${PROJECT_ID}"
	sed -i '' "s/PROJECT_ID/${PROJECT_ID}/g" k8s/serviceaccount.yaml

patch-pv:
	@echo "==> Patching pv.yaml with BUCKET_NAME=${BUCKET_NAME}"
	sed -i '' "s/BUCKET_NAME/${BUCKET_NAME}/g" k8s/pv.yaml

rollout:
	kubectl rollout status deployment/ladybugdb-explorer -n $(NAMESPACE)

rollout-mcp:
	kubectl rollout status deployment/ladybugdb-mcp-server -n $(NAMESPACE)

status:
	@echo "=== Pods ==="
	kubectl get pods -n $(NAMESPACE)
	@echo ""
	@echo "=== Services ==="
	kubectl get services -n $(NAMESPACE)
	@echo ""
	@echo "=== PersistentVolumeClaim ==="
	kubectl get pvc -n $(NAMESPACE)

port-forward:
	@echo "Open http://localhost:8000 to access LadybugDB Explorer"
	kubectl port-forward -n $(NAMESPACE) \
	  svc/ladybugdb-explorer 8000:80

port-forward-mcp:
	@echo "MCP SSE endpoint: http://localhost:8080/sse"
	kubectl port-forward -n $(NAMESPACE) \
	  svc/ladybugdb-mcp-server 8080:80

destroy:
	@bash scripts/teardown.sh

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
_check-env:
ifndef PROJECT_ID
	$(error PROJECT_ID is not set. Copy .env.example to .env and fill in values.)
endif
ifndef BUCKET_NAME
	$(error BUCKET_NAME is not set. Copy .env.example to .env and fill in values.)
endif
