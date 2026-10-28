# Build Guide: GitOps Kubernetes Platform on AWS EKS

Follow the parts in order. Every command is copy-paste. Lines starting with `# ` are comments.
Region everywhere: **ap-south-1 (Mumbai)**. Time: about 3 to 4 hours the first time. EKS costs money while it runs, so do Part 14 (teardown) the same day you finish.

What I could and could not check before giving you this (be honest in interviews too):
- Checked here: the app (health, metrics, failure injection, DB-down), the analyzer logic, all shell scripts (shellcheck), Terraform formatting and module inputs, Kubernetes/Argo/Prometheus manifests against schemas, `configure.sh`.
- NOT checkable here (no AWS access): the real `terraform apply`, real Jenkins/ArgoCD/Sonar runs, and whether your account allows the instance types. So no one can honestly promise "zero errors". Part 15 lists the likely trouble spots and fixes. If something fails, paste the exact error and I will fix it.

---

## Part 0. Before you start (laptop, 20 minutes)

1. **AWS account** with billing enabled. Region selector: Asia Pacific (Mumbai).
2. **Docker Hub**: create an access token (Account Settings > Personal access token > Read & Write). Save the token.
3. **GitHub**: you already have user `Mahendra0456`. Create TWO public repos (empty is fine, tick "Add a README" for both):
   - `ai-ecommerce-devops` (code + CI)
   - `ecommerce-gitops` (what ArgoCD watches)
4. **NVD API key** (free, needed by OWASP Dependency-Check): https://nvd.nist.gov/developers/request-an-api-key , confirm the email, save the key.
5. **Your laptop public IP**: open https://checkip.amazonaws.com and note it (example `49.36.1.2`). If it changes later, see Part 15.
6. **Enable Cost Explorer** (needed for the cost part): AWS Console > Billing > Cost Explorer > Launch. It can take up to 24 hours to become ready.
7. **Key pair**: you already have `my-newkey` (.pem). Keep the file on your laptop.

## Part 1. Launch devops-server (the only EC2 you create by hand)

Console > EC2 > Launch instance:
- Name: `devops-server`
- AMI: Ubuntu Server 24.04 LTS (x86_64)
- Instance type: **t3.large (8 GB)** recommended (Jenkins + SonarQube + Docker builds need memory). If your account only allows flex types, use `m7i-flex.large` or `c7i-flex.large`.
- Key pair: `my-newkey`
- Network: default VPC, **Auto-assign public IP: Enable**
- Security group (new): SSH 22 from **My IP**; Custom TCP 8080 from **My IP**
- Storage: 40 GB gp3
- Advanced details > IAM instance profile: create/attach a role `devops-server-role` (trusted entity EC2) with `AdministratorAccess` (lab only; say "least privilege is a next step" in interviews).
- Launch.

Then Elastic IP so the address survives stop/start: EC2 > Elastic IPs > Allocate > Associate with devops-server. Note this IP as `SERVER_IP`.

If a type is refused ("not eligible for Free Tier" or "not supported in AZ"), pick another from:
```
aws ec2 describe-instance-type-offerings --region ap-south-1 --location-type region \
  --query 'InstanceTypeOfferings[].InstanceType' --output text | tr '\t' '\n' | grep -E '^(t3|m7i-flex|c7i-flex)\.' | sort
```
(run it later from the server; for now choose in the console).

## Part 2. SSH in

Linux/Mac laptop:
```
chmod 400 ~/Downloads/my-newkey.pem
ssh -i ~/Downloads/my-newkey.pem ubuntu@SERVER_IP
```
Windows: PowerShell has `ssh`; same command. (Or PuTTY with a converted .ppk.)
First time answer `yes` to the fingerprint question.

On the server confirm the IAM role works:
```
sudo apt-get update -y && sudo apt-get install -y unzip
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
```
Expect `devops-server-role` printed. (If blank: attach the role in EC2 > Actions > Security > Modify IAM role.)

## Part 3. Upload the bundle and install tools

On your laptop (new terminal, in the folder where you saved `ecom-platform-bundle.zip`):
```
scp -i ~/Downloads/my-newkey.pem ecom-platform-bundle.zip ubuntu@SERVER_IP:~
```
On the server:
```
cd ~ && unzip -o ecom-platform-bundle.zip
ls            # ai-ecommerce-devops  ecommerce-gitops  ecom-platform-bundle.zip
cd ~/ai-ecommerce-devops
bash scripts/install-tools.sh
```
This installs AWS CLI, Docker, Terraform, kubectl, Helm, Trivy, Java 21, Jenkins, and starts SonarQube (about 5 to 10 minutes). When it finishes:
```
exit
```
and SSH in again (so the docker group applies). Check:
```
docker ps                 # shows sonarqube
terraform -version; kubectl version --client; helm version --short; trivy --version | head -1
aws sts get-caller-identity   # must show your account id and the devops-server-role
sudo systemctl status jenkins --no-pager | head -5
```

## Part 4. GitHub access from the server

```
ssh-keygen -t ed25519 -C "devops-server" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```
GitHub > Settings > SSH and GPG keys > New SSH key > paste. Then:
```
ssh -T git@github.com     # "Hi Mahendra0456! You've successfully authenticated"
git config --global user.name "Mahendra Swain"
git config --global user.email "nicemahendra96@gmail.com"
git config --global init.defaultBranch main
```

## Part 5. Put the code into your two repos

```
cd ~
git clone git@github.com:Mahendra0456/ai-ecommerce-devops.git repo-code
git clone git@github.com:Mahendra0456/ecommerce-gitops.git repo-gitops
```
Move any old content (old K3s version) out of the way, keep history:
```
cd ~/repo-code
mkdir -p legacy-k3s
git ls-files | grep -v '^README.md$' | grep -v '^legacy-k3s/' | xargs -r -I{} git mv --force {} legacy-k3s/{} 2>/dev/null || true
cd ~
```
(If the repo only has a README, nothing moves; that is fine.)

Copy the new bundle in and configure it. `configure.sh` needs: your Docker Hub username, your laptop IP, an email for cost alerts, and optionally the key pair name.
```
cd ~
rsync -a --exclude .git ~/ai-ecommerce-devops/ ~/repo-code/
rsync -a --exclude .git ~/ecommerce-gitops/   ~/repo-gitops/
cd ~/repo-code
bash configure.sh YOUR_DOCKERHUB_USER YOUR_LAPTOP_IP you@example.com my-newkey
```
It creates the S3 state bucket `mahendra-tfstate-<account-id>`, fills placeholders in both repos, and writes `terraform.tfvars` (git-ignored). Check nothing is left:
```
grep -rn "mahendra46\|Mahendra0456\|mahendra-tfstate-977133951325" ~/repo-code ~/repo-gitops --include='*' -I | grep -v '/.git/' || echo "all placeholders replaced"
```
Publish both repos:
```
cd ~/repo-code   && git add -A && git commit -m "GitOps EKS platform" && git push origin main
cd ~/repo-gitops && git add -A && git commit -m "Initial GitOps repo" && git push origin main
```
From now on work in `~/repo-code` (call it the code repo) and `~/repo-gitops`.
(Jenkins will push to repo-gitops, so always `git pull --rebase` there before editing.)

## Part 6. Build the AWS infrastructure with Terraform (15 to 20 minutes)

```
cd ~/repo-code/terraform-eks
terraform init
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```
It creates: VPC, one NAT gateway, EKS cluster + 2 worker nodes, add-ons (CNI, kube-proxy, CoreDNS, EBS CSI, pod identity), and the ELK EC2 server (Docker Compose Elasticsearch + Kibana, starts itself).

Verify:
```
terraform output
```
Wait 3 to 5 minutes, then check ELK (from devops-server):
```
curl -s http://$(terraform output -raw elk_private_ip):9200 | head -5     # JSON with "cluster_name"
```
If it does not answer after 6 minutes see Part 15.

## Part 7. Install the cluster add-ons (one script, about 10 minutes)

```
cd ~/repo-code
bash scripts/cluster-bootstrap.sh
```
It sets kubeconfig, waits for nodes, sets gp3 as default storage, installs metrics-server, Prometheus+Grafana+Alertmanager, Filebeat, the incident analyzer, Argo Rollouts and ArgoCD, and prints the ArgoCD admin password. **Copy that password.**

Check:
```
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed     # should be only the header line
```
Pods that say `ContainerCreating` for a minute are normal.

## Part 8. Jenkins and SonarQube setup (laptop browser through an SSH tunnel)

Open a tunnel from your laptop (leave this terminal open):
```
ssh -i ~/Downloads/my-newkey.pem -L 9000:localhost:9000 -L 3000:localhost:3000 -L 8081:localhost:8081 ubuntu@SERVER_IP
```
Start the port-forwards on the server (in the SSH session):
```
cd ~/repo-code && bash scripts/pf-start.sh
```

### 8.1 SonarQube (http://localhost:9000)
1. Login `admin` / `admin`, set a new password.
2. My Account > Security > Generate token (type: User token). Save as `SONAR_TOKEN`.
3. **Quality Gates > Sonar way > Copy** as `ecom-gate`. In the copy, delete the condition "Coverage on New Code" (and "Duplications"/"Security Hotspots Reviewed" if they fail on a tiny app). Then "Set as Default". Reason: the sample app has no coverage report, so the default gate would fail every build.
4. Project key must match `application/sonar-project.properties` (already set).

### 8.2 Jenkins (http://SERVER_IP:8080)
1. Unlock: `sudo cat /var/lib/jenkins/secrets/initialAdminPassword` > paste > Install suggested plugins > create admin user.
2. Manage Jenkins > Plugins > Available: install **Pipeline: Stage View** (optional) and make sure **Git**, **Credentials Binding**, **SSH Agent** are present (they come with suggested plugins). Restart if asked.
3. Manage Jenkins > Nodes > Built-In Node > number of executors = 1.
4. Manage Jenkins > Credentials > System > Global > Add credentials:
   - Username with password, ID `dockerhub-creds`: username = Docker Hub user, password = the Docker Hub token.
   - Secret text, ID `sonar-token`: the Sonar token.
   - Secret text, ID `nvd-api-key`: your NVD key.
   - SSH Username with private key, ID `gitops-deploy-key`: do 8.3 first.

### 8.3 Deploy key so Jenkins can push to the GitOps repo
On the server:
```
ssh-keygen -t ed25519 -f ~/.ssh/gitops_deploy -N "" -C "jenkins-gitops"
cat ~/.ssh/gitops_deploy.pub
cat ~/.ssh/gitops_deploy        # paste this whole private key into the Jenkins credential (Username: git)
```
GitHub > repo `ecommerce-gitops` > Settings > Deploy keys > Add key > paste the **.pub**, tick **Allow write access**.

### 8.4 Create the pipeline job
New Item > name `ecommerce-pipeline` > Pipeline > OK.
- Pipeline definition: **Pipeline script from SCM**
- SCM: Git; Repository URL: `https://github.com/Mahendra0456/ai-ecommerce-devops.git` (public, no credentials)
- Branch: `*/main`
- Script Path: `jenkins/Jenkinsfile`
- Save.
(The Jenkinsfile polls GitHub every ~2 minutes, so no webhook is needed.)

## Part 9. First build, THEN ArgoCD

The GitOps repo points at image tag `bootstrap`, which does not exist. Build #1 pushes a real image and updates the tag.

1. Jenkins > `ecommerce-pipeline` > **Build Now**.
2. Expected: Gitleaks, Sonar, Dependency-Check (first run downloads the vulnerability database: 10 to 30 minutes, later runs are fast), Trivy, Test, Build, Image scan, Push, Update GitOps Repo. All green.
3. Verify on GitHub: repo `ecommerce-gitops` has a commit `ci: deploy image tag 1`, and Docker Hub has `ecommerce:1`.

Only now create the ArgoCD application:
```
cd ~/repo-gitops && git pull --rebase
kubectl apply -f ~/repo-gitops/argocd/application.yaml
kubectl get applications -n argocd
kubectl get pods -n ecommerce -w        # Ctrl+C when 4 app pods + mongo are Running
kubectl argo rollouts get rollout ecommerce -n ecommerce
```
Get the app URL (a few minutes for the load balancer DNS):
```
kubectl get svc ecommerce -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```
Open `http://<that-hostname>` in your browser. You should see ShopKart.

UIs:
- ArgoCD: https://localhost:8081 (accept the certificate warning), user `admin`, password from Part 7.
- Grafana: http://localhost:3000, user `admin`, password:
  `kubectl get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo`
  Dashboard "ShopKart" is pre-loaded.
- Kibana: http://ELK_PUBLIC_IP:5601 (`terraform -chdir=terraform-eks output -raw elk_public_ip`). Stack Management > Data Views > create `filebeat-*` (time field `@timestamp`) and later `incident-reports`.

## Part 10. Demo 1: a good release (canary rolls forward)

```
cd ~/repo-gitops && git pull --rebase
cd ~/repo-code
sed -i 's|<h2>ShopKart</h2>|<h2>ShopKart v2</h2>|' application/public/index.html
git add -A && git commit -m "feat: v2 header" && git push origin main
```
Within about 2 minutes Jenkins starts a build; after it pushes the new tag, ArgoCD syncs and the rollout moves 25% > 50% > 100%.
Watch: `kubectl argo rollouts get rollout ecommerce -n ecommerce --watch`

## Part 11. Demo 2: a bad release (auto abort)

```
cd ~/repo-gitops && git pull --rebase
sed -i 's|^failRate:.*|failRate: "0.5"|' apps/ecommerce/values.yaml
git commit -am "demo: bad release (50% errors)" && git push origin main
```
Generate traffic (needed so Prometheus sees errors):
```
cd ~/repo-code
HOST=$(kubectl get svc ecommerce -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
nohup bash scripts/traffic.sh $HOST 3 >/dev/null 2>&1 &
kubectl argo rollouts get rollout ecommerce -n ecommerce --watch
```
Expected: canary pods fail the `error-rate` analysis and the rollout becomes **Degraded / aborted**; stable pods keep serving. Recover:
```
pkill -f traffic.sh
cd ~/repo-gitops && git pull --rebase && git revert --no-edit HEAD && git push origin main
```
Note: whether the alert fires depends on timing; the analysis abort is the dependable part of this demo.

## Part 12. Demo 3: database outage and incident report (the reliable alert demo)

ArgoCD self-heal would undo `kubectl scale`, so do it through Git:
```
cd ~/repo-gitops && git pull --rebase
sed -i 's|^  replicas: 1|  replicas: 0|' apps/ecommerce/values.yaml     # the mongo block
git commit -am "demo: database outage" && git push origin main
```
(Check with `grep -n -B1 'replicas' apps/ecommerce/values.yaml` that only the `mongo:` value changed.)
With traffic running, after 1 to 3 minutes the app returns 5xx, Alertmanager fires `HighErrorRate`, the analyzer receives it and writes a report. Read it:
```
kubectl logs deploy/incident-analyzer -n monitoring --tail=40
```
and in Kibana > Discover > `incident-reports`: classification "Database connectivity", probable cause, investigation steps, remediation. Restore: `git revert --no-edit HEAD && git push origin main`.

## Part 13. Demo 4: autoscaling, and Cost Anomaly Detection

HPA (min 4, max 6, CPU 50%):
```
kubectl get hpa -n ecommerce
bash ~/repo-code/scripts/traffic.sh $HOST 20 &     # heavy load, watch: kubectl get hpa -n ecommerce -w
pkill -f traffic.sh                                   # stop when done
```
Cost stack (separate Terraform stack, so it survives the EKS teardown):
```
cd ~/repo-code/terraform-cost
terraform init && terraform plan -out tfplan && terraform apply tfplan
```
Open the email AWS sends and **confirm the subscription**. You get a $25 monthly budget with alerts and an anomaly monitor with daily email.
Screenshots to take (save under `docs/screenshots/`): Jenkins green pipeline, ArgoCD synced, canary in progress, aborted bad release, Grafana dashboard, Kibana incident report, HPA scaling, Budgets page.

## Part 14. Teardown (do this the same day)

```
cd ~/repo-code && bash scripts/teardown.sh
```
It deletes the ArgoCD app and namespaces (frees load balancers and disks), waits, shows leftovers (both lists must be empty), then asks before `terraform destroy`. Keep `terraform-cost` (it is nearly free). Stop (not terminate) devops-server when not working; the Elastic IP costs a little while the server is stopped.
Final check in the console: EC2 (only devops-server), Load Balancers (none), NAT gateways (none), Volumes (only devops-server's).

## Part 15. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `terraform init` S3 403 / NoSuchBucket | Run `configure.sh` first; role needs S3 access; bucket name must match `terraform-eks/provider.tf` |
| Apply fails `InvalidParameterCombination ... not eligible for Free Tier` or instance type unsupported | Edit `node_type` / `elk_type` in `terraform.tfvars` (use a type from the describe-instance-type-offerings command), re-plan |
| Apply fails on NAT / EKS "not allowed" | Account is on a restricted plan; upgrade the AWS account plan (EKS and NAT are not free-tier) |
| Nodes stay NotReady | Wait 5 minutes; `kubectl describe node`; check vpc-cni add-on in the console |
| ELK `curl :9200` fails | Wait 5 more minutes; `ssh ubuntu@<elk_public_ip>` then `sudo docker ps` and `sudo cat /var/log/cloud-init-output.log | tail -30` |
| Pods `Pending` on volumes | `kubectl get storageclass` must show `gp3 (default)`; re-run step 3 of bootstrap |
| Jenkins build fails at Gitleaks | A secret pattern was found; read the redacted output, remove it, rotate the key |
| Sonar stage "Quality Gate failed" | Do 8.1 step 3 (custom gate without coverage) |
| Sonar stage cannot connect | `docker ps` shows sonarqube? wait 2 minutes after start; `curl localhost:9000/api/system/status` |
| Dependency-Check very slow / 403 | First run is slow; check the NVD key credential `nvd-api-key` |
| Trivy fails with CRITICAL | Update the base image/dependency, or add an entry to `.trivyignore` with a reason |
| Trivy DB download rate limit | Add `--db-repository public.ecr.aws/aquasecurity/trivy-db` to both trivy commands |
| `Update GitOps Repo` fails with permission denied | Deploy key missing write access, or credential holds the .pub instead of the private key |
| Push rejected (non-fast-forward) in repo-gitops | `git pull --rebase` first, then push |
| ArgoCD app `ImagePullBackOff` | You created the app before build #1; wait for Jenkins to push a tag, or run build #1 |
| ArgoCD Application OutOfSync with HPA | Already handled by `ignoreDifferences`; click Refresh |
| Browser cannot reach Jenkins | Your laptop IP changed. Update the devops-server security group, and for ELK edit `my_ip_cidr` in `terraform-eks/terraform.tfvars` then `terraform apply` |
| Cost Explorer errors in `terraform-cost` | Enable Cost Explorer (Part 0.6) and retry after a few hours |
| Port-forward UIs dead after reboot | `bash scripts/pf-stop.sh && bash scripts/pf-start.sh` |

## Part 16. Resume wording (use only what you actually ran)

- Built a GitOps delivery platform on AWS EKS (Terraform, ArgoCD, Argo Rollouts) with canary releases that analyse Prometheus error rates and abort bad releases automatically.
- Designed a Jenkins DevSecOps pipeline (Gitleaks, SonarQube quality gate, OWASP Dependency-Check, Trivy) that updates a separate GitOps repo; Jenkins never has cluster access.
- Implemented observability and incident response: Prometheus/Grafana, Filebeat to Elasticsearch/Kibana, and a rule-based analyzer triggered by Alertmanager that writes classified incident reports.
- Added HPA autoscaling and cost controls (AWS Budgets, Cost Anomaly Detection) with Terraform; infrastructure kept in S3 remote state.
Do not claim "AI/LLM" unless you enable the optional Bedrock summary; say "rule-based incident analysis".
