#!/bin/bash
set -euo pipefail

# AWS CLI v2 pipes any non-empty output through a pager when stdout is a terminal.
# That turns an informational response into a blocking prompt that no amount of
# AUTO_APPROVE can answer: `aws s3api head-bucket` used to print nothing on success,
# but current versions return a JSON body, so the second deploy in any account — the
# one where the state bucket already exists — stopped dead on a full-screen pager.
# Disable paging for every AWS call here rather than redirecting them one at a time.
export AWS_PAGER=""

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TFVARS="${REPO_ROOT}/terraform/terraform.tfvars"

# PURGE_STATE=1 also deletes the Terraform state bucket once the destroy has succeeded.
# Off by default — see STATE BUCKET near the end for why.
PURGE_STATE="${PURGE_STATE:-0}"

echo "  Gemma 4 Cloud Deployment — Destroy"
echo ""
echo "  WARNING: This will destroy ALL infrastructure"
echo "  and delete all resources in AWS."
echo ""
if [ "$PURGE_STATE" = "1" ]; then
    echo "  PURGE_STATE=1: the Terraform state bucket, and every version of the state"
    echo "  file in it, is deleted as well once the destroy has succeeded."
else
    echo "  The Terraform state bucket is kept. Set PURGE_STATE=1 to delete it as well."
fi
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

# Same parser as deploy.sh. The project name and region are needed both to rebuild
# backend.hcl and for the leftover check after the destroy.
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

# The backend is a partial configuration, so Terraform has to be pointed at the state
# bucket before anything can be destroyed. backend.hcl is written by deploy.sh but is
# gitignored, so a fresh clone — exactly the case that needs the bootstrap most — does
# not have one. Rebuild it the same way deploy.sh does when it is missing.
if [ ! -f backend.hcl ]; then
    echo "→ No backend.hcl (fresh clone?). Reconstructing it..."

    cat > backend.hcl <<EOF
bucket = "${PROJECT_NAME}-tfstate-${ACCOUNT_ID}"
region = "${REGION}"
EOF

    echo "  Using s3://${PROJECT_NAME}-tfstate-${ACCOUNT_ID} in ${REGION}."
    echo ""
fi

# backend.hcl is what Terraform actually uses, so the bucket is read back from it
# rather than derived a second time.
backend_setting() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" backend.hcl | head -1 | cut -d'"' -s -f2 || true
}

STATE_BUCKET=$(backend_setting bucket)
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_NAME}-tfstate-${ACCOUNT_ID}}"
STATE_REGION=$(backend_setting region)
STATE_REGION="${STATE_REGION:-${REGION}}"

# No state bucket means no Terraform state to destroy from — usually because an earlier
# PURGE_STATE=1 run removed it — and terraform init would only stop with "S3 bucket does
# not exist". Skip to the leftover check instead, which still looks at what is really
# there. Only a 404 counts as missing: any other error (no permission, a bucket owned by
# another account) goes on to terraform init, which reports it.
STATE_BUCKET_MISSING=0
if ! bucket_error=$(aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$STATE_REGION" 2>&1); then
    if printf '%s' "$bucket_error" | grep -q '(404)'; then
        STATE_BUCKET_MISSING=1
    fi
fi


# DESTROY
# The common failure is a timeout while the ECS service drains its tasks, which a
# second pass a minute later finishes. Two explicit attempts and no loop: a destroy that
# fails for a real reason must stop and say so, not keep retrying unattended.

RETRY_DELAY_SECONDS=60

if [ "$STATE_BUCKET_MISSING" = "1" ]; then
    echo "→ No state bucket s3://${STATE_BUCKET} in account ${ACCOUNT_ID}."
    echo "  There is no Terraform state to destroy from, so terraform destroy is skipped."
    echo "  An earlier PURGE_STATE=1 run is the usual reason. If you deployed from another"
    echo "  AWS account, switch credentials and run this again."
    echo ""
else
    echo "→ Initialising Terraform against the state bucket..."
    terraform init -reconfigure -backend-config=backend.hcl
    echo ""

    echo "→ Destroying infrastructure (attempt 1 of 2)..."
    if ! terraform destroy -auto-approve; then
        echo ""
        echo "  terraform destroy failed. The usual cause is a timeout while the ECS service"
        echo "  drains, which a second attempt finishes."
        echo "  Retrying once in ${RETRY_DELAY_SECONDS} seconds..."
        echo ""
        sleep "$RETRY_DELAY_SECONDS"

        echo "→ Destroying infrastructure (attempt 2 of 2)..."
        if ! terraform destroy -auto-approve; then
            echo ""
            echo "  terraform destroy failed again. Not retrying a second time."
            echo "  Some resources may still exist and cost money. Read the error above, fix"
            echo "  the cause, then run ./scripts/destroy.sh again. The state bucket was not"
            echo "  touched."
            exit 1
        fi
    fi
    echo ""
    echo "  All resources in the Terraform state destroyed."
    echo ""
fi


# LEFTOVER CHECK
# A smoke test, not a guarantee: it only sees resources that carry a Name tag, and only
# in this region — global resources such as the CloudFront distribution may not appear.
#
# Tag filter values match exactly, with no wildcards — "Values=gemma-inference*" matches
# only a tag whose value is literally that — so every Name-tagged resource is fetched
# and the prefix is matched in --query instead. project_name is part of the S3 bucket
# names, so AWS only accepts one made of characters that are safe inside that literal.
#
# Terraform can only deregister ECS task definitions, and ECS keeps every revision as
# INACTIVE. They would turn up after every single teardown, so they are counted apart
# rather than reported as survivors. They cost nothing.
#
# Reading tags needs tag:GetResources, which not every deploy role has. A failed query is
# reported as unknown instead of failing a teardown that has already succeeded — the
# same approach as the GPU quota check in deploy.sh.
report_leftovers() {
    local arns survivors revisions

    if ! arns=$(aws resourcegroupstaggingapi get-resources \
        --tag-filters Key=Name --region "$REGION" \
        --query "ResourceTagMappingList[?Tags[?Key=='Name' && starts_with(Value, '${PROJECT_NAME}-')]].ResourceARN" \
        --output text 2>/dev/null | tr '\t' '\n'); then
        echo "  Leftover check: unknown — could not read tags (needs tag:GetResources)."
        echo "  Check the AWS console if you need to be sure nothing is left."
        return 0
    fi

    # Text output prints one line per result page, and "None" for a null result.
    survivors=$(printf '%s\n' "$arns" | awk 'NF && $0 != "None" && !/:task-definition\//')
    revisions=$(printf '%s\n' "$arns" | awk '/:task-definition\// { n++ } END { print n + 0 }')

    if [ -z "$survivors" ]; then
        echo "  Leftover check: nothing left with a Name=${PROJECT_NAME}-* tag in ${REGION}."
    else
        echo "  Leftover check: WARNING, still tagged Name=${PROJECT_NAME}-* in ${REGION}:"
        printf '%s\n' "$survivors" | sed 's/^/    /'
        echo "  Something deleted moments ago can still be listed for a while — confirm each"
        echo "  one in the console before removing it by hand."
    fi

    if [ "$revisions" -gt 0 ]; then
        echo "  Not counted: ${revisions} ECS task definition revision(s), which ECS keeps as"
        echo "  INACTIVE after Terraform deregisters them. They cost nothing."
    fi

    echo "  This is a smoke test, not a guarantee: resources without a Name tag, and"
    echo "  global ones such as CloudFront, are not covered."
}

echo "→ Checking for leftovers..."
report_leftovers
echo ""


# STATE BUCKET
# deploy.sh creates this bucket outside Terraform, because a backend cannot create
# itself, so terraform destroy never touches it and this script is the symmetric place
# to remove it. It is kept unless PURGE_STATE=1: it holds the versioned history of the
# state file, costs next to nothing, and the next deploy picks it straight back up.
#
# The bucket is versioned, so `aws s3 rb --force` cannot empty it — that deletes only
# the current objects, which just stacks delete markers on top of every old version.
# Each pass below lists up to 1,000 versions and delete markers (S3's default page, and
# also the most one delete-objects call accepts) and deletes exactly those by version
# ID. A pass either removes everything it listed or stops the purge, so the bucket only
# ever gets emptier; the pass limit is a backstop in case something keeps writing to it.
#
# The body is ( ) rather than { }: it runs in a subshell, so the EXIT trap that removes
# the temp file belongs to this function alone.
purge_state_bucket() (
    bucket="$1"
    region="$2"

    batch=$(mktemp) || exit 1
    trap 'rm -f "$batch"' EXIT

    for _ in $(seq 1 100); do
        if ! aws s3api list-object-versions --bucket "$bucket" --region "$region" \
            --no-paginate --output json \
            --query '{Objects: [Versions || `[]`, DeleteMarkers || `[]`][].{Key: Key, VersionId: VersionId}, Quiet: `true`}' \
            > "$batch"; then
            echo "  Could not list the object versions in s3://${bucket}."
            exit 1
        fi

        grep -q '"Key"' "$batch" || break

        if ! failed=$(aws s3api delete-objects --bucket "$bucket" --region "$region" \
            --delete "file://${batch}" --query 'length(Errors || `[]`)' --output text); then
            echo "  Could not delete object versions from s3://${bucket}."
            exit 1
        fi

        if [ "$failed" != "0" ]; then
            echo "  S3 refused to delete ${failed} object version(s) in s3://${bucket}."
            exit 1
        fi
    done

    if ! aws s3api delete-bucket --bucket "$bucket" --region "$region"; then
        echo "  Could not delete s3://${bucket}."
        exit 1
    fi

    echo "  Deleted every object version and delete marker, then s3://${bucket}."
)

echo "→ Terraform state bucket..."
if [ "$STATE_BUCKET_MISSING" = "1" ]; then
    echo "  s3://${STATE_BUCKET} does not exist — nothing to keep or delete."
elif [ "$PURGE_STATE" = "1" ]; then
    if ! purge_state_bucket "$STATE_BUCKET" "$STATE_REGION"; then
        echo ""
        echo "  The infrastructure is destroyed, but the state bucket was not fully deleted."
        echo "  Fix the error above, then run PURGE_STATE=1 ./scripts/destroy.sh again."
        exit 1
    fi
else
    echo "  Kept s3://${STATE_BUCKET}. To delete it, including every version of the"
    echo "  state file it holds, run:"
    echo ""
    echo "    PURGE_STATE=1 ./scripts/destroy.sh"
fi
echo ""
echo "  Teardown complete."
