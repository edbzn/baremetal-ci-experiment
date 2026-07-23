#!/usr/bin/env bash
# Minimal local "CI runner": build via rootless BuildKit, push to the local
# registry, smoke-test the result in a locked-down container, publish an
# artifact record. Assumes ci-registry and ci-buildkitd (see README) are up.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR/sample-app"
ARTIFACTS_DIR="$PROJECT_DIR/artifacts"
REGISTRY="ci-registry:5000"
IMAGE="sample-app"
TAG="${1:-ci-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)}"

mkdir -p "$ARTIFACTS_DIR"
BUILD_LOG="$ARTIFACTS_DIR/build-${TAG}.log"

echo "== [1/3] Build + push ${REGISTRY}/${IMAGE}:${TAG} ==" | tee "$BUILD_LOG"
docker run --rm \
  --network ci-experiment \
  --entrypoint buildctl \
  -v "$APP_DIR:/build-context:ro" \
  moby/buildkit:rootless \
  --addr tcp://ci-buildkitd:1234 \
  build \
  --frontend dockerfile.v0 \
  --local context=/build-context \
  --local dockerfile=/build-context \
  --output "type=image,name=${REGISTRY}/${IMAGE}:${TAG},push=true,registry.insecure=true" \
  --export-cache "type=registry,ref=${REGISTRY}/${IMAGE}:buildcache,mode=max" \
  --import-cache "type=registry,ref=${REGISTRY}/${IMAGE}:buildcache" \
  2>&1 | tee -a "$BUILD_LOG"

echo "== [2/3] Smoke test: run the built image locked down ==" | tee -a "$BUILD_LOG"
docker pull "localhost:5000/${IMAGE}:${TAG}" >> "$BUILD_LOG" 2>&1
RUN_OUTPUT=$(docker run --rm \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 64 \
  --memory 64m \
  "localhost:5000/${IMAGE}:${TAG}")
echo "$RUN_OUTPUT" | tee -a "$BUILD_LOG"

echo "== [3/3] Publish artifact record ==" | tee -a "$BUILD_LOG"
DIGEST=$(curl -sS "http://localhost:5000/v2/${IMAGE}/manifests/${TAG}" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
  -D - -o /dev/null 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
DIGEST="${DIGEST:-unknown}"
ARTIFACT_JSON="$ARTIFACTS_DIR/${IMAGE}-${TAG}.json"
cat > "$ARTIFACT_JSON" <<EOF
{
  "image": "${REGISTRY}/${IMAGE}:${TAG}",
  "digest": "${DIGEST}",
  "run_output": $(printf '%s' "$RUN_OUTPUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),
  "build_log": "artifacts/build-${TAG}.log"
}
EOF

echo "CI job complete."
echo "  image:    ${REGISTRY}/${IMAGE}:${TAG}"
echo "  digest:   ${DIGEST}"
echo "  artifact: ${ARTIFACT_JSON}"
