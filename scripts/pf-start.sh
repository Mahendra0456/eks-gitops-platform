#!/bin/bash
# Starts background port-forwards on devops-server. Reach them from your laptop through the SSH tunnel.
#   Grafana -> http://localhost:3000     ArgoCD -> https://localhost:8081
nohup kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 >/tmp/pf-grafana.log 2>&1 &
nohup kubectl port-forward -n argocd svc/argocd-server 8081:443 >/tmp/pf-argocd.log 2>&1 &
sleep 2
echo "Port-forwards started. Logs: /tmp/pf-grafana.log /tmp/pf-argocd.log"
