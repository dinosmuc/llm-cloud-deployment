#!/bin/bash
set -e

cd "$(dirname "$0")/../terraform"

echo "  Gemma 4 Cloud Deployment — Destroy"
echo ""
echo "  WARNING: This will destroy ALL infrastructure"
echo "  and delete all resources in AWS."
echo ""
read -p "  Are you sure? Type 'yes' to confirm: " confirm
echo ""

if [ "$confirm" = "yes" ]; then
    echo "→ Destroying infrastructure..."
    terraform destroy -auto-approve
    echo ""
    echo "  All resources destroyed."
else
    echo "  Cancelled. Nothing was destroyed."
fi