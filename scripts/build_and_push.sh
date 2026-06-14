#!/bin/bash
set -e

# Resolve paths relative to the repo root, so this works no matter the caller's
# working directory (run directly from the repo root, or invoked by deploy.sh
# which runs from terraform/). The docker build contexts below are repo-relative.
cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-eu-central-1}"
REPO_NAME="${ECR_REPO_NAME:-gemma-inference}"

# HuggingFace token for downloading the model at image-build time. Required if the
# model repo is gated; harmless (empty) if it is ungated. Export HF_TOKEN before running.
HF_TOKEN="${HF_TOKEN:-}"

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Account:  ${ACCOUNT_ID}"
echo "Region:   ${REGION}"
echo "ECR URL:  ${ECR_URL}/${REPO_NAME}"
echo ""

# Authenticate Docker to ECR
echo "→ Authenticating Docker to ECR..."
aws ecr get-login-password --region ${REGION} | \
    docker login --username AWS --password-stdin ${ECR_URL}
echo ""

# Build vLLM image (this downloads the model — takes 10-15 min first time)
echo "→ Building vLLM image (this may take a while)..."
docker build --provenance=false --sbom=false --build-arg HF_TOKEN="${HF_TOKEN}" -t ${ECR_URL}/${REPO_NAME}:vllm containers/vllm/
echo ""

# Build proxy (auth-proxy sidecar) image
echo "→ Building proxy image..."
docker build --provenance=false --sbom=false -t ${ECR_URL}/${REPO_NAME}:proxy containers/proxy/
echo ""

# Push vLLM image
echo "→ Pushing vLLM image to ECR..."
docker push ${ECR_URL}/${REPO_NAME}:vllm
echo ""

# Push proxy image
echo "→ Pushing proxy image to ECR..."
docker push ${ECR_URL}/${REPO_NAME}:proxy
echo ""

echo "  Done! Images pushed to ECR:"
echo "  vLLM:   ${ECR_URL}/${REPO_NAME}:vllm"
echo "  proxy:  ${ECR_URL}/${REPO_NAME}:proxy"
