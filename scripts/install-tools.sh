#!/usr/bin/env bash
# Installs everything devops-server needs. Safe to run again.
# Run on Ubuntu 24.04 (x86_64):   bash scripts/install-tools.sh
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
export DEBIAN_FRONTEND=noninteractive
TARGET_USER="${SUDO_USER:-${USER:-root}}"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

if [ "$(uname -m)" != "x86_64" ]; then
  echo "This script expects an x86_64 instance (your instance is $(uname -m))." >&2
  exit 1
fi

say "Base packages"
$SUDO apt-get update -y
$SUDO apt-get install -y ca-certificates curl wget gnupg lsb-release unzip zip jq git htop tree vim \
  apt-transport-https fontconfig software-properties-common
$SUDO timedatectl set-timezone Asia/Kolkata || true

say "4 GB swap (SonarQube + Jenkins + builds need headroom)"
if ! swapon --show | grep -q '/swapfile'; then
  $SUDO fallocate -l 4G /swapfile
  $SUDO chmod 600 /swapfile
  $SUDO mkswap /swapfile
  $SUDO swapon /swapfile
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null

say "AWS CLI v2"
if ! command -v aws >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  ( cd "$tmp" && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip \
      && unzip -q awscliv2.zip && $SUDO ./aws/install )
  rm -rf "$tmp"
fi

say "Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | $SUDO sh
fi
$SUDO systemctl enable --now docker
$SUDO usermod -aG docker "$TARGET_USER" || true

say "Terraform"
if ! command -v terraform >/dev/null 2>&1; then
  curl -fsSL https://apt.releases.hashicorp.com/gpg | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | $SUDO tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y terraform
fi

say "kubectl"
if ! command -v kubectl >/dev/null 2>&1; then
  KV="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/kubectl" "https://dl.k8s.io/release/${KV}/bin/linux/amd64/kubectl"
  $SUDO install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
fi

say "Helm"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

say "Trivy"
if ! command -v trivy >/dev/null 2>&1; then
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | $SUDO sh -s -- -b /usr/local/bin
fi

say "Java 21 + Jenkins LTS"
$SUDO apt-get install -y openjdk-21-jre
$SUDO mkdir -p /etc/apt/keyrings
$SUDO wget -q -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | $SUDO tee /etc/apt/sources.list.d/jenkins.list >/dev/null
$SUDO apt-get update -y
$SUDO apt-get install -y jenkins
$SUDO usermod -aG docker jenkins
$SUDO systemctl enable jenkins
$SUDO systemctl restart jenkins

say "Kernel settings for SonarQube"
printf 'vm.max_map_count=524288\nfs.file-max=131072\n' | $SUDO tee /etc/sysctl.d/99-sonarqube.conf >/dev/null
$SUDO sysctl --system >/dev/null

say "SonarQube Community Build (container, localhost:9000 only)"
if ! $SUDO docker ps -a --format '{{.Names}}' | grep -qx sonarqube; then
  $SUDO docker run -d --name sonarqube --restart unless-stopped -p 127.0.0.1:9000:9000 \
    -v sonarqube_data:/opt/sonarqube/data \
    -v sonarqube_extensions:/opt/sonarqube/extensions \
    -v sonarqube_logs:/opt/sonarqube/logs \
    sonarqube:community
else
  $SUDO docker start sonarqube >/dev/null 2>&1 || true
fi

say "Installed versions"
aws --version || true
$SUDO docker --version || true
terraform version | head -1 || true
kubectl version --client | head -1 || true
helm version --short || true
trivy --version | head -1 || true
java -version 2>&1 | head -1 || true
echo
echo "Done. Log out and back in once so the docker group applies to your user:  exit  (then ssh in again)"
