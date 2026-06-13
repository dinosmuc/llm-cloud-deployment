#!/bin/bash
set -e

echo "  Gemma 4 Cloud Deployment — Deploy"


cd "$(dirname "$0")/../terraform"

echo "→ Initialising Terraform..."
terraform init
echo ""

echo "→ Planning infrastructure changes..."
terraform plan -out=tfplan
echo ""

read -p "  Apply these changes? Type 'yes' to confirm: " confirm
echo ""

if [ "$confirm" != "yes" ]; then
    rm -f tfplan
    echo "  Cancelled. Nothing was applied."
    exit 0
fi

echo "→ Applying infrastructure..."
terraform apply tfplan
rm -f tfplan
echo ""

echo "  Deployment Complete!"
echo ""

terraform output