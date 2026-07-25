#!/usr/bin/env bash
# Installs the OSS monitoring/alerting/logging stack:
#   - kube-prometheus-stack (Prometheus + Grafana + Alertmanager +
#     kube-state-metrics + node-exporter)
#   - Loki (log storage)
#   - Alloy (log shipper, DaemonSet)
#
# No external account/API key needed - fully self-hosted. See
# docs/monitoring-alerts.md for the alert rules to configure in Grafana
# once this is running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update prometheus-community grafana >/dev/null

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.19.1 \
  -n monitoring \
  -f "$CLUSTER_DIR/kube-prometheus-stack-values.yaml"

helm upgrade --install loki grafana/loki \
  --version 7.1.0 \
  -n monitoring \
  -f "$CLUSTER_DIR/loki-values.yaml"

helm upgrade --install alloy grafana/alloy \
  --version 1.11.0 \
  -n monitoring \
  -f "$CLUSTER_DIR/alloy-values.yaml"

echo "Done. Verify: kubectl get pods -n monitoring"
echo "Grafana LoadBalancer IP: kubectl get svc -n monitoring kube-prometheus-stack-grafana"
echo "Default login: admin / (see grafana.adminPassword in kube-prometheus-stack-values.yaml - change this before any real use)"
echo "Add Loki as a Grafana data source: http://loki.monitoring.svc.cluster.local:3100 (Prometheus data source is auto-configured by the chart)"
