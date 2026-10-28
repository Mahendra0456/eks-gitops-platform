#!/usr/bin/env bash
# One-time setup of the values that are specific to you. Run from the root of the app repo
# (the GitOps repo must be cloned next to it as ../ecommerce-gitops):
#
#   bash configure.sh <dockerhub_user> <laptop_public_ip> <alert_email> [aws_key_pair_name]
#
# Optional overrides (instance types): NODE_TYPE, NODE_COUNT, ELK_TYPE
#   NODE_TYPE=c7i-flex.large NODE_COUNT=3 bash configure.sh mahendra46 49.36.10.20 you@gmail.com
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: bash configure.sh <dockerhub_user> <laptop_public_ip> <alert_email> [aws_key_pair_name]" >&2
  exit 1
fi

DH="$1"
IP="$2"
EMAIL="$3"
KEY="${4:-my-newkey}"
GH="Mahendra0456"
REGION="ap-south-1"
NODE_TYPE="${NODE_TYPE:-m7i-flex.large}"
NODE_COUNT="${NODE_COUNT:-2}"
ELK_TYPE="${ELK_TYPE:-c7i-flex.large}"

[[ "$DH" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]                        || { echo "Docker Hub user must be lowercase letters/digits (got: $DH)" >&2; exit 1; }
[[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]                  || { echo "Laptop IP must look like 49.36.10.20, without /32 (got: $IP)" >&2; exit 1; }
[[ "$EMAIL" =~ ^[^@|\&\\[:space:]]+@[^@|\&\\[:space:]]+$ ]]   || { echo "Email looks wrong (got: $EMAIL)" >&2; exit 1; }
[[ "$KEY" =~ ^[A-Za-z0-9_.-]+$ ]]                             || { echo "Key pair name looks wrong (got: $KEY)" >&2; exit 1; }
[[ "$NODE_COUNT" =~ ^[0-9]+$ ]]                               || { echo "NODE_COUNT must be a number" >&2; exit 1; }

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
GITOPS_DIR="/home/ubuntu/repo-gitops"
[ -d "$GITOPS_DIR" ] || { echo "Expected the GitOps repo at $GITOPS_DIR (clone it next to this repo first)" >&2; exit 1; }

export AWS_DEFAULT_REGION="$REGION"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="mahendra-tfstate-${ACCOUNT}"
echo "AWS account : $ACCOUNT"
echo "State bucket: $BUCKET"

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  echo "Created bucket $BUCKET"
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

# Replace the placeholders in every text file of both repos
for dir in "$APP_DIR" "$GITOPS_DIR"; do
  while IFS= read -r -d '' f; do
    sed -i \
      -e "s|__DOCKERHUB_USER__|$DH|g" \
      -e "s|__GITHUB_USER__|$GH|g" \
      -e "s|__STATE_BUCKET__|$BUCKET|g" "$f"
  done < <(grep -rIlZ -e '__DOCKERHUB_USER__' -e '__GITHUB_USER__' -e '__STATE_BUCKET__' "$dir" \
             --exclude-dir=.git --exclude-dir=node_modules --exclude=configure.sh || true)
done

# Local-only values (git-ignored, they never reach GitHub)
cat > "$APP_DIR/terraform-eks/terraform.tfvars" <<TFV
my_ip_cidr = "${IP}/32"
key_name   = "${KEY}"
node_type  = "${NODE_TYPE}"
node_count = ${NODE_COUNT}
elk_type   = "${ELK_TYPE}"
TFV
cat > "$APP_DIR/terraform-cost/terraform.tfvars" <<TFV
alert_email = "${EMAIL}"
TFV

echo
echo "Remaining placeholders (the next lines should be empty):"
grep -rIn -e '__DOCKERHUB_USER__' -e '__GITHUB_USER__' -e '__STATE_BUCKET__' "$APP_DIR" "$GITOPS_DIR" \
  --exclude-dir=.git --exclude-dir=node_modules --exclude=configure.sh || true
echo
echo "Configured. Review terraform-eks/terraform.tfvars, then commit both repos and continue with the guide."
