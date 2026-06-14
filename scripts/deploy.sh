#!/bin/bash
set -e

echo "  Gemma 4 Cloud Deployment — Deploy"
echo ""

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "${REPO_ROOT}/terraform"

echo "→ Initialising Terraform..."
terraform init
echo ""

# Step 1: ECR must exist before images can be pushed. A plain full apply would
# create the task definition referencing images that aren't in ECR yet, leaving
# the first request to fail with an image-pull error. So create ECR first.
echo "→ Step 1/3: Creating the ECR repository (terraform apply -target=module.ecr)..."
read -p "  Apply ECR repository? Type 'yes' to confirm: " confirm
echo ""
if [ "$confirm" != "yes" ]; then
    echo "  Cancelled. Nothing was applied."
    exit 0
fi
terraform apply -target=module.ecr -auto-approve
echo ""

# Step 2: build and push the vllm + proxy images into the now-existing repo.
# Docker layer caching makes repeat runs fast (the model-download layer is reused
# unless the Dockerfile or HF_TOKEN changes), and ECR skips layers it already has.
echo "→ Step 2/3: Building and pushing container images..."
"${REPO_ROOT}/scripts/build_and_push.sh"
echo ""

# Step 3: apply the rest of the stack.
echo "→ Step 3/3: Planning the remaining infrastructure..."
terraform plan -out=tfplan
echo ""

read -p "  Apply these changes? Type 'yes' to confirm: " confirm
echo ""

if [ "$confirm" != "yes" ]; then
    rm -f tfplan
    echo "  Cancelled. ECR and images exist, but the rest of the stack was not applied."
    exit 0
fi

echo "→ Applying infrastructure..."
terraform apply tfplan
rm -f tfplan
echo ""

echo "  Deployment Complete!"
echo ""

terraform output