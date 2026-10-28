"""Incident analyzer.

Alertmanager calls POST /alert. The analyzer reads recent error logs from
Elasticsearch, classifies them with rules (always works), optionally asks an LLM on
Amazon Bedrock for a plain-English summary, and stores the report in the
`incident-reports` index so it can be read in Kibana.
"""
import json
import os
import re
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

ES = os.environ.get("ES_URL", "").rstrip("/")
WINDOW_MIN = int(os.environ.get("WINDOW_MINUTES", "10"))
PORT = int(os.environ.get("PORT", "5000"))
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "ap-south-1")

# (classification, regex, severity, probable cause, investigation steps, remediation)
RULES = [
    ("Faulty release (application 5xx)", r"Injected failure|Order failed", "high",
     "The newest version is returning server errors",
     ["kubectl argo rollouts get rollout ecommerce -n ecommerce",
      "Compare the error-rate panel in Grafana before and after the release",
      "Check the last commit in the ecommerce-gitops repo"],
     "Let Argo Rollouts abort the canary, then git revert the release commit in the GitOps repo"),
    ("Database connectivity", r"timeout|ECONNREFUSED|ServerSelection|Database", "high",
     "MongoDB is unreachable, down or overloaded",
     ["kubectl get pods,svc,endpoints -n ecommerce | grep mongo",
      "kubectl logs deploy/mongo -n ecommerce",
      "Check MONGO_URI in the ConfigMap and the PVC status"],
     "Bring the MongoDB pod and Service back and verify the connection settings"),
    ("Memory exhaustion", r"out of memory|OOM|heap", "critical",
     "A container is running out of memory",
     ["kubectl describe pod -n ecommerce", "Check memory graphs in Grafana"],
     "Raise the memory limit or fix the leak, then roll out again"),
    ("DNS resolution", r"ENOTFOUND|EAI_AGAIN", "medium",
     "A service name cannot be resolved",
     ["kubectl get pods -n kube-system | grep coredns", "Check service names in the ConfigMap"],
     "Fix the service name or restart CoreDNS"),
]


def fetch_logs(minutes=WINDOW_MIN, size=100):
    query = {
        "size": size,
        "sort": [{"@timestamp": "desc"}],
        "query": {"bool": {"filter": [
            {"range": {"@timestamp": {"gte": f"now-{minutes}m"}}},
            {"match": {"kubernetes.namespace": "ecommerce"}},
            {"match": {"message": "error"}},
        ]}},
    }
    req = urllib.request.Request(f"{ES}/filebeat-*/_search", json.dumps(query).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return [h["_source"].get("message", "") for h in json.load(resp)["hits"]["hits"]]


def llm_summary(report):
    """Optional. Only runs when BEDROCK_MODEL_ID is set. Never raises."""
    if not BEDROCK_MODEL_ID:
        return None
    try:
        import boto3
        evidence = [e[:300] for e in report.get("evidence", [])[:3]]
        prompt = ("You are an SRE assistant. In 3 short sentences explain this incident to an on-call "
                  "engineer and name the first thing to check.\n"
                  f"Alert: {report['alert']}\nClassification: {report['classification']}\n"
                  f"Probable cause: {report['probable_cause']}\nLog evidence: {evidence}")
        client = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
        resp = client.converse(modelId=BEDROCK_MODEL_ID,
                               messages=[{"role": "user", "content": [{"text": prompt}]}],
                               inferenceConfig={"maxTokens": 300, "temperature": 0.2})
        return resp["output"]["message"]["content"][0]["text"]
    except Exception as exc:  # noqa: BLE001
        print("llm summary failed:", exc, flush=True)
        return None


def analyze(alert_name):
    try:
        logs, err = fetch_logs(), None
    except Exception as exc:  # noqa: BLE001
        logs, err = [], str(exc)

    best = None
    for name, pattern, severity, cause, steps, fix in RULES:
        hits = [line for line in logs if re.search(pattern, line, re.I)]
        if hits and (best is None or len(hits) > best[0]):
            best = (len(hits), name, severity, cause, steps, fix, hits[:3])

    report = {
        "@timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "alert": alert_name,
        "error_lines_analyzed": len(logs),
    }
    if best:
        report.update(classification=best[1], severity=best[2], probable_cause=best[3],
                      investigation=best[4], remediation=best[5], evidence=best[6])
    else:
        report.update(classification="Unknown", severity="medium",
                      probable_cause="No known error pattern in recent logs"
                                     + (f" (log query failed: {err})" if err else ""),
                      investigation=["Check pod status and events", "Search Kibana manually"],
                      remediation="Manual investigation", evidence=[])
    summary = llm_summary(report)
    if summary:
        report["ai_summary"] = summary
    return report


def store(report):
    req = urllib.request.Request(f"{ES}/incident-reports/_doc", json.dumps(report).encode(),
                                 {"Content-Type": "application/json"}, method="POST")
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as exc:  # noqa: BLE001
        print("store failed:", exc, flush=True)


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, text):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(text.encode())

    def do_GET(self):
        self._reply(200 if self.path == "/healthz" else 404, "ok")

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            names = {a.get("labels", {}).get("alertname", "unknown")
                     for a in body.get("alerts", [])} or {"manual"}
            for name in names:
                report = analyze(name)
                print(json.dumps(report, indent=2), flush=True)
                store(report)
        except Exception as exc:  # noqa: BLE001
            print("request failed:", exc, flush=True)
        self._reply(200, "ok")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
