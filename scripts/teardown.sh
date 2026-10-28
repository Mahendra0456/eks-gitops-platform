#!/bin/bash
# Removes everything Kubernetes created outside Terraform (load balancers, volumes), then destroys the infrastructure.
set -u
export AWS_DEFAULT_REGION=ap-south-1
echo "== Stopping helpers"
pkill -f "kubectl port-forward" || true
pkill -f traffic.sh || true

echo "== Deleting the ArgoCD application so nothing is recreated"
kubectl delete application ecommerce -n argocd --ignore-not-found --wait=false || true

echo "== Deleting namespaces (frees load balancers and EBS volumes)"
kubectl delete ns ecommerce monitoring logging argocd argo-rollouts --ignore-not-found --timeout=300s || true
echo "Waiting 120 s for AWS to remove load balancers and volumes..."
sleep 120

echo "== Leftover checks (both lists should be empty)"
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
aws ec2 describe-volumes --filters "Name=tag-key,Values=kubernetes.io/cluster/ecom-eks" --query 'Volumes[].VolumeId' --output text

read -r -p "Run terraform destroy now? (yes/no) " ANSWER
if [ "$ANSWER" = "yes" ]; then
  cd "$(dirname "$0")/../terraform-eks" && terraform destroy
fi
