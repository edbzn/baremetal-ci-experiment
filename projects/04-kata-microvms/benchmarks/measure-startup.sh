#!/usr/bin/env bash
# Measures pod cold-start time (creation -> Ready) for a given RuntimeClass,
# averaged over N runs. Each run uses a uniquely-named pod to avoid image
# cache effects from a prior run of the SAME pod name, though the image
# itself will be warm on the node after the first run either way.
set -euo pipefail

RUNTIME_CLASS="${1:-}"   # empty string = default (runc)
RUNS="${2:-5}"
IMAGE="192.168.122.200:5000/alpine-test:v1"

for i in $(seq 1 "$RUNS"); do
  NAME="startup-test-${RUNTIME_CLASS:-runc}-${i}-$$"
  RC_FIELD=""
  if [ -n "$RUNTIME_CLASS" ]; then
    RC_FIELD="\"runtimeClassName\": \"${RUNTIME_CLASS}\","
  fi

  START=$(date +%s.%N)
  kubectl run "$NAME" --image="$IMAGE" --restart=Never \
    --overrides="{\"spec\": {${RC_FIELD} \"containers\": [{\"name\": \"${NAME}\", \"image\": \"${IMAGE}\", \"command\": [\"sleep\", \"3600\"]}]}}" \
    > /dev/null

  kubectl wait --for=condition=Ready "pod/${NAME}" --timeout=120s > /dev/null
  END=$(date +%s.%N)

  ELAPSED=$(echo "$END - $START" | bc)
  echo "run ${i}: ${ELAPSED}s"

  kubectl delete pod "$NAME" --wait=false > /dev/null
done
