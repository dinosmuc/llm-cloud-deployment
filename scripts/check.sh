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
# Node is needed for these four SSE tests and nothing else in the project: the
# frontend is plain HTML/JS with no build step. Skip rather than fail when it is
# absent, so a reviewer without Node still gets the Terraform, shell, Python and
# proxy checks instead of a hard stop at the last step.
if command -v node >/dev/null 2>&1; then
    node --test "tests/**/*.test.js"
else
    echo "  SKIPPED: node not found. The 4 SSE tests need Node >= 22;"
    echo "  the other 24 tests above have run. Install Node for the full suite."
fi

echo ""
echo "  All checks passed."
