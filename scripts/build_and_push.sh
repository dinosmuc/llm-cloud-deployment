set -e

REGION="${AWS_REGION:-eu-central-1}"
REPO_NAME="${ECR_REPO_NAME:-gemma-inference}"

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
docker build -t ${ECR_URL}/${REPO_NAME}:vllm containers/vllm/
echo ""

# Build proxy (auth-proxy sidecar) image
echo "→ Building proxy image..."
docker build -t ${ECR_URL}/${REPO_NAME}:proxy containers/proxy/
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
