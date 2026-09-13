#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TFVARS="${REPO_ROOT}/terraform/terraform.tfvars"

echo "  Gemma 4 Cloud Deployment — Destroy"
echo ""
echo "  WARNING: This will destroy ALL infrastructure"
echo "  and delete all resources in AWS."
echo ""
echo "  The Terraform state bucket is not touched — it is created outside"
echo "  the stack and has to be deleted manually if you no longer need it."
echo ""

# Same non-interactive contract as deploy.sh: AUTO_APPROVE=1 skips the prompt, and
# routing through a helper stops `set -e` from killing the script without a message
# when stdin is closed.
AUTO_APPROVE="${AUTO_APPROVE:-0}"

if [ "$AUTO_APPROVE" = "1" ]; then
    echo "  Destroying without confirmation (AUTO_APPROVE=1)."
    echo ""
else
    read -r -p "  Are you sure? Type 'yes' to confirm: " reply || reply=""
    echo ""

    if [ "$reply" != "yes" ]; then
        echo "  Cancelled. Nothing was destroyed."
        exit 0
    fi
fi

# terraform.tfvars is gitignored, and public_api_key, internal_api_key and alert_email
# have no defaults — Terraform needs values for them to build a destroy plan, and
# -auto-approve does not suppress variable prompting. Fail with a clear message here
# rather than an opaque "No value for required variable" later.
if [ ! -f "$TFVARS" ]; then
    echo "  Missing terraform/terraform.tfvars."
    echo "  Terraform needs the same variable values to destroy as it did to apply."
    echo "  Copy terraform/terraform.tfvars.example and fill in your values."
    exit 1
fi

cd "${REPO_ROOT}/terraform"

# The backend is a partial configuration, so Terraform has to be pointed at the state
# bucket before anything can be destroyed. backend.hcl is written by deploy.sh but is
# gitignored, so a fresh clone — exactly the case that needs the bootstrap most — does
# not have one. Rebuild it the same way deploy.sh does when it is missing.
if [ ! -f backend.hcl ]; then
    echo "→ No backend.hcl (fresh clone?). Reconstructing it..."

    tfvar() {
        local value
        value=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" | head -1 | cut -d'"' -s -f2 || true)
        echo "${value:-$2}"
    }

    if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
        echo "  AWS credentials are not configured. Run 'aws configure' first."
        exit 1
    fi

    PROJECT_NAME=$(tfvar project_name gemma-inference)
    REGION=$(tfvar aws_region eu-central-1)

    cat > backend.hcl <<EOF
bucket = "${PROJECT_NAME}-tfstate-${ACCOUNT_ID}"
region = "${REGION}"
EOF

    echo "  Using s3://${PROJECT_NAME}-tfstate-${ACCOUNT_ID} in ${REGION}."
    echo ""
fi

echo "→ Initialising Terraform against the state bucket..."
terraform init -reconfigure -backend-config=backend.hcl
echo ""

echo "→ Destroying infrastructure..."
terraform destroy -auto-approve
echo ""
echo "  All resources destroyed."
