#!/bin/bash
set -e

# Configuration
REGION="eu-central-1"
REPO_NAME="phi3-inference"

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "========================================="
echo "  Phi-3 Cloud Deployment — Build & Push"
echo "========================================="
echo ""
echo "Account:  ${ACCOUNT_ID}"
echo "Region:   ${REGION}"
echo "ECR URL:  ${ECR_URL}/${REPO_NAME}"
echo ""

# Authenticate Docker to ECR
echo "→ Authenticating Docker to ECR..."
aws ecr get-login-password --region ${REGION} | \
    docker login --username AWS --password-stdin ${ECR_URL}
echo ""

# Build TGI image (this downloads the model — takes 10-15 min first time)
echo "→ Building TGI image (this may take a while)..."
docker build -t ${ECR_URL}/${REPO_NAME}:tgi containers/vllm/
echo ""

# Build nginx image
echo "→ Building nginx image..."
docker build -t ${ECR_URL}/${REPO_NAME}:nginx containers/nginx/
echo ""

# Push TGI image
echo "→ Pushing TGI image to ECR..."
docker push ${ECR_URL}/${REPO_NAME}:tgi
echo ""

# Push nginx image
echo "→ Pushing nginx image to ECR..."
docker push ${ECR_URL}/${REPO_NAME}:nginx
echo ""

echo "========================================="
echo "  Done! Images pushed to ECR:"
echo "  TGI:   ${ECR_URL}/${REPO_NAME}:tgi"
echo "  nginx: ${ECR_URL}/${REPO_NAME}:nginx"
echo "========================================="