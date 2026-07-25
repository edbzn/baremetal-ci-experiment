#!/usr/bin/env bash
# Installs the monitoring/alerting stack: kube-state-metrics + two
# OpenTelemetry Collector releases (node-local daemonset for
# kubelet/log data, cluster-wide deployment for kube-state-metrics),
# both exporting to New Relic via OTLP.
#
# Prerequisite: cluster/newrelic-license-secret.yaml must exist with a
# real license key (copy from newrelic-license-secret.yaml.example,
# gitignored - never commit the real key). Not run automatically as
# part of any other setup - this is a deliberate, one-time step once a
# New Relic account/key exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$CLUSTER_DIR/newrelic-license-secret.yaml" ]; then
  echo "Missing $CLUSTER_DIR/newrelic-license-secret.yaml" >&2
  echo "Copy newrelic-license-secret.yaml.example, fill in the real license key, then re-run." >&2
  exit 1
fi

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$CLUSTER_DIR/newrelic-license-secret.yaml"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
helm repo update prometheus-community open-telemetry >/dev/null

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --version 8.0.0 \
  -n kube-system \
  -f "$CLUSTER_DIR/kube-state-metrics-values.yaml"

helm upgrade --install otel-collector-node open-telemetry/opentelemetry-collector \
  --version 0.165.0 \
  -n monitoring \
  -f "$CLUSTER_DIR/otel-collector-daemonset-values.yaml"

helm upgrade --install otel-collector-cluster open-telemetry/opentelemetry-collector \
  --version 0.165.0 \
  -n monitoring \
  -f "$CLUSTER_DIR/otel-collector-cluster-values.yaml"

echo "Done. Verify: kubectl get pods -n monitoring -n kube-system -l app.kubernetes.io/name=kube-state-metrics"
echo "New Relic data should appear within a few minutes under Infrastructure > Kubernetes."
