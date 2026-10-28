#!/bin/bash
# Installs everything the cluster needs EXCEPT the application (ArgoCD deploys that later).
# Run from the repo root on devops-server:  bash scripts/cluster-bootstrap.sh
set -euo pipefail
export AWS_DEFAULT_REGION=ap-south-1
cd "$(dirname "$0")/.."

echo "== 1/9 kubeconfig"
eval "$(terraform -chdir=terraform-eks output -raw update_kubeconfig)"
ELK_IP=$(terraform -chdir=terraform-eks output -raw elk_private_ip)
echo "ELK private IP: $ELK_IP"

echo "== 2/9 waiting for nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl get nodes

echo "== 3/9 gp3 default storage class"
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class- --overwrite 2>/dev/null || true
kubectl apply -f cluster/storageclass-gp3.yaml

echo "== 4/9 metrics-server (needed by HPA)"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s

echo "== 5/9 Prometheus + Grafana + Alertmanager"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f monitoring/values.yaml --wait --timeout 15m

echo "== 6/9 Filebeat -> Elasticsearch"
kubectl create ns logging --dry-run=client -o yaml | kubectl apply -f -
sed "s/__ELK_IP__/$ELK_IP/g" logging/filebeat.yaml | kubectl apply -f -

echo "== 7/9 Incident analyzer"
kubectl -n monitoring create configmap analyzer-code \
  --from-file=analyze.py=ai/incident-analysis/analyze.py --dry-run=client -o yaml | kubectl apply -f -
sed "s/__ELK_IP__/$ELK_IP/g" monitoring/incident-analyzer.yaml | kubectl apply -f -

echo "== 8/9 Argo Rollouts"
kubectl create ns argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

echo "== 9/9 ArgoCD"
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=600s

if ! command -v kubectl-argo-rollouts >/dev/null 2>&1; then
  curl -sSLo /tmp/kar https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
  sudo install -m 0755 /tmp/kar /usr/local/bin/kubectl-argo-rollouts
fi

echo
echo "Done. ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo "Next: run the first Jenkins build, THEN: kubectl apply -f ~/ecommerce-gitops/argocd/application.yaml"
