#!/bin/bash
set -euo pipefail

# Static checks and unit tests. Needs no AWS credentials, no deployment and no
# Docker — a fresh terraform init does still download providers from the registry.
# This is what CI runs on every push.

cd "$(dirname "$0")/.."

echo "  Gemma 4 Cloud Deployment — Checks"
echo ""

echo "→ Terraform formatting..."
terraform -chdir=terraform fmt -check -recursive

# -backend=false validates the configuration without touching S3 or credentials.
# It also leaves an existing local init alone.
echo "→ Terraform validation..."
terraform -chdir=terraform init -backend=false -input=false >/dev/null
terraform -chdir=terraform validate

echo "→ Shell script syntax..."
# One invocation per file: `bash -n scripts/*.sh` passes the first path as the script
# and every other path as its positional arguments, so only the first was checked.
for script in scripts/*.sh; do
    bash -n "$script"
done

echo "→ Python syntax..."
python3 -m compileall -q containers/proxy

echo "→ Proxy tests..."
python3 -m pytest tests -q

echo "→ Frontend tests..."
node --test "tests/**/*.test.js"

echo ""
echo "  All checks passed."
