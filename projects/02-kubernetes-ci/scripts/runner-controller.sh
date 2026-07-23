#!/usr/bin/env bash
# Minimal "runner controller": watches a queue directory for CI task
# definitions and creates one ephemeral Job (one pod) per task. This stands
# in for a real GitLab/GitHub runner controller — the point is the pattern
# (queue -> one Job per task -> observe completion), not a production
# implementation.
#
# Usage: ./runner-controller.sh [queue-dir]
#   Drop a *.task file into the queue dir to enqueue a job. Each file is a
#   shell command to run inside the CI job container.
set -euo pipefail

NAMESPACE="ci"
IMAGE="ci-registry:5000/sample-app:v1"
QUEUE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/queue}"
PROCESSED_DIR="$QUEUE_DIR/.processed"

mkdir -p "$QUEUE_DIR" "$PROCESSED_DIR"
echo "Runner controller watching: $QUEUE_DIR (namespace=$NAMESPACE)"
echo "Press Ctrl-C to stop."

sanitize_name() {
  # Job names must be valid DNS labels: lowercase, alnum + '-', <=63 chars.
  echo "ci-job-$(basename "$1" .task | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-')-$(date +%s%N | tail -c 6)"
}

while true; do
  shopt -s nullglob
  for task_file in "$QUEUE_DIR"/*.task; do
    task_name=$(basename "$task_file")
    job_name=$(sanitize_name "$task_file")
    command=$(cat "$task_file")

    echo "[$(date -u +%FT%TZ)] picked up ${task_name} -> Job/${job_name}"

    kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${NAMESPACE}
  labels:
    app: ci-runner
    task: $(basename "$task_file" .task)
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app: ci-runner
        task: $(basename "$task_file" .task)
    spec:
      restartPolicy: Never
      # Pin CI jobs to the trusted-ci node pool (see manifests/08-*.yaml /
      # README step 4): tolerate its taint and require its label, so CI load
      # never lands on the system pool by accident.
      tolerations:
        - key: node-role
          operator: Equal
          value: trusted-ci
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role
                    operator: In
                    values: ["trusted-ci"]
      containers:
        - name: task
          image: ${IMAGE}
          command: ["sh", "-c", $(printf '%s' "$command" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
          resources:
            requests:
              cpu: "100m"
              memory: "32Mi"
            limits:
              cpu: "500m"
              memory: "128Mi"
              ephemeral-storage: "200Mi"
EOF

    mv "$task_file" "$PROCESSED_DIR/${task_name}.$(date +%s)"
  done
  sleep 2
done
