"""Tests for scripts/destroy.sh, run end to end against stub `terraform` and `aws`.

The script is copied into a scratch repository layout and executed for real, with
stubs first on PATH that record every call and answer from canned responses. That
covers what teardown actually has to get right without an AWS account: how many times
it destroys, that nothing touches the state bucket unless asked, and the order in which
a purge deletes things.

The stubs do not evaluate --query expressions, so a wrong JMESPath would not be caught
here — these check the control flow around those calls, not the calls themselves.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash not available")

BUCKET = "gemma-inference-tfstate-123456789012"

# STUB_DESTROY_FAILURES: how many `terraform destroy` calls fail before one succeeds.
TERRAFORM_STUB = r"""#!/bin/bash
echo "terraform $*" >> "$STUB_LOG"
if [ "$1" = "destroy" ]; then
    count=$(( $(cat "$STUB_STATE/destroys" 2>/dev/null || echo 0) + 1 ))
    echo "$count" > "$STUB_STATE/destroys"
    if [ "$count" -le "${STUB_DESTROY_FAILURES:-0}" ]; then
        echo "Error: timeout while waiting for state to become 'INACTIVE'" >&2
        exit 1
    fi
fi
exit 0
"""

# STUB_TAGGING:        empty | denied | leftovers
# STUB_BUCKET:         exists | missing | forbidden
# STUB_VERSION_PAGES:  how many list-object-versions pages hold something to delete
# STUB_DELETE_ERRORS:  what delete-objects reports as length(Errors)
AWS_STUB = r"""#!/bin/bash
echo "aws $*" >> "$STUB_LOG"
case "$1 $2" in
    "sts get-caller-identity")
        echo "123456789012" ;;
    "resourcegroupstaggingapi get-resources")
        case "${STUB_TAGGING:-empty}" in
            denied)
                echo "An error occurred (AccessDeniedException) when calling the GetResources operation" >&2
                exit 254 ;;
            leftovers)
                printf 'arn:aws:ec2:eu-central-1:123456789012:natgateway/nat-0abc\tarn:aws:ecs:eu-central-1:123456789012:task-definition/gemma-inference:4\n' ;;
            *)
                echo "" ;;
        esac ;;
    "s3api head-bucket")
        case "${STUB_BUCKET:-exists}" in
            missing)
                echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2
                exit 254 ;;
            forbidden)
                echo "An error occurred (403) when calling the HeadBucket operation: Forbidden" >&2
                exit 254 ;;
        esac ;;
    "s3api list-object-versions")
        count=$(( $(cat "$STUB_STATE/lists" 2>/dev/null || echo 0) + 1 ))
        echo "$count" > "$STUB_STATE/lists"
        if [ "$count" -le "${STUB_VERSION_PAGES:-1}" ]; then
            printf '{\n    "Objects": [\n        {\n            "Key": "gemma-inference/terraform.tfstate",\n            "VersionId": "v%s"\n        }\n    ],\n    "Quiet": true\n}\n' "$count"
        else
            printf '{\n    "Objects": [],\n    "Quiet": true\n}\n'
        fi ;;
    "s3api delete-objects")
        prev=""
        for arg in "$@"; do
            [ "$prev" = "--delete" ] && payload="${arg#file://}"
            prev="$arg"
        done
        sed -n 's/.*"VersionId": "\([^"]*\)".*/deleted \1/p' "$payload" >> "$STUB_LOG"
        echo "${STUB_DELETE_ERRORS:-0}" ;;
    "s3api delete-bucket")
        ;;
    *)
        echo "unexpected aws call: $*" >&2
        exit 1 ;;
esac
"""

SLEEP_STUB = """#!/bin/bash
echo "sleep $*" >> "$STUB_LOG"
"""


def write_stub(directory, name, body):
    path = directory / name
    path.write_text(body)
    path.chmod(0o755)


def run_destroy(tmp_path, **environment):
    """Run a copy of destroy.sh with AUTO_APPROVE=1 and the stubs first on PATH.

    Returns the completed process, the recorded calls in order, and the TMPDIR the
    script was given, so a test can check that nothing was left behind in it.
    """
    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    (repo / "terraform").mkdir()
    shutil.copy(ROOT / "scripts" / "destroy.sh", repo / "scripts" / "destroy.sh")
    (repo / "terraform" / "terraform.tfvars").write_text(
        'aws_region   = "eu-central-1"\nproject_name = "gemma-inference"\n'
    )

    stubs = tmp_path / "stubs"
    stubs.mkdir()
    write_stub(stubs, "terraform", TERRAFORM_STUB)
    write_stub(stubs, "aws", AWS_STUB)
    write_stub(stubs, "sleep", SLEEP_STUB)

    state = tmp_path / "state"
    state.mkdir()
    scratch = tmp_path / "tmp"
    scratch.mkdir()
    log = tmp_path / "calls.log"
    log.touch()

    result = subprocess.run(
        ["bash", str(repo / "scripts" / "destroy.sh")],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=60,
        env={
            "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
            "STUB_LOG": str(log),
            "STUB_STATE": str(state),
            "TMPDIR": str(scratch),
            "AUTO_APPROVE": "1",
            **environment,
        },
    )

    return result, log.read_text().splitlines(), scratch


def destroys(calls):
    return [call for call in calls if call.startswith("terraform destroy")]


def s3_operations(calls):
    return [call.split()[2] for call in calls if call.startswith("aws s3api ")]


def output(result):
    return result.stdout + result.stderr


def test_clean_teardown_keeps_the_state_bucket_and_prints_the_purge_command(tmp_path):
    result, calls, _ = run_destroy(tmp_path)

    assert result.returncode == 0, output(result)
    assert len(destroys(calls)) == 1
    assert not any(call.startswith("sleep") for call in calls), "retried a destroy that succeeded"
    assert s3_operations(calls) == ["head-bucket"], (
        "did more than check the state bucket exists without PURGE_STATE=1"
    )

    assert "nothing left" in result.stdout
    assert BUCKET in result.stdout

    # Printed without AUTO_APPROVE=1: copied out of the scrollback later, against a
    # fresh deployment, it must still ask before destroying anything.
    lines = [line.strip() for line in result.stdout.splitlines()]
    assert "PURGE_STATE=1 ./scripts/destroy.sh" in lines


def test_a_failing_destroy_is_retried_exactly_once(tmp_path):
    """A destroy that never succeeds: two attempts, one wait, then a non-zero exit.

    PURGE_STATE=1 is set on purpose — deleting the state of a half-destroyed stack
    would orphan everything still running.
    """
    result, calls, _ = run_destroy(tmp_path, STUB_DESTROY_FAILURES="99", PURGE_STATE="1")

    assert result.returncode != 0, output(result)
    assert len(destroys(calls)) == 2, calls
    assert [call for call in calls if call.startswith("sleep")] == ["sleep 60"]

    assert not any("get-resources" in call for call in calls)
    assert s3_operations(calls) == ["head-bucket"], "touched the state bucket after a failed destroy"

    assert "failed again" in result.stdout


def test_a_destroy_that_succeeds_on_the_retry_carries_on(tmp_path):
    result, calls, _ = run_destroy(tmp_path, STUB_DESTROY_FAILURES="1")

    assert result.returncode == 0, output(result)
    assert len(destroys(calls)) == 2
    assert [call for call in calls if call.startswith("sleep")] == ["sleep 60"]
    assert "nothing left" in result.stdout


def test_purge_deletes_every_version_before_the_bucket(tmp_path):
    """Versioned bucket: delete-bucket must come only after listing comes back empty."""
    result, calls, scratch = run_destroy(tmp_path, PURGE_STATE="1", STUB_VERSION_PAGES="2")

    assert result.returncode == 0, output(result)
    assert s3_operations(calls) == [
        "head-bucket",
        "list-object-versions",
        "delete-objects",
        "list-object-versions",
        "delete-objects",
        "list-object-versions",
        "delete-bucket",
    ]
    assert [call for call in calls if call.startswith("deleted ")] == ["deleted v1", "deleted v2"]
    assert list(scratch.iterdir()) == [], "the batch temp file was not cleaned up"


def test_a_state_bucket_that_no_longer_exists_is_not_an_error(tmp_path):
    """Re-running after a purge. terraform init would stop with "S3 bucket does not
    exist", so the destroy is skipped — there is no state left to destroy from — but
    the leftover check still runs."""
    result, calls, _ = run_destroy(tmp_path, PURGE_STATE="1", STUB_BUCKET="missing")

    assert result.returncode == 0, output(result)
    assert not any(call.startswith("terraform") for call in calls), calls
    assert any("get-resources" in call for call in calls), "skipped the leftover check"
    assert s3_operations(calls) == ["head-bucket"]
    assert "does not exist" in result.stdout


def test_only_a_404_counts_as_a_missing_state_bucket(tmp_path):
    """A 403 is someone else's bucket or a missing permission, not an absent one —
    that must still reach terraform, which reports it, rather than skip the destroy."""
    result, calls, _ = run_destroy(tmp_path, STUB_BUCKET="forbidden")

    assert len(destroys(calls)) == 1, calls


def test_purge_stops_before_the_bucket_when_a_version_cannot_be_deleted(tmp_path):
    result, calls, scratch = run_destroy(tmp_path, PURGE_STATE="1", STUB_DELETE_ERRORS="1")

    assert result.returncode != 0, output(result)
    assert "delete-bucket" not in s3_operations(calls)
    assert list(scratch.iterdir()) == [], "the batch temp file was not cleaned up"


def test_missing_tagging_permission_is_unknown_not_failure(tmp_path):
    result, _, _ = run_destroy(tmp_path, STUB_TAGGING="denied")

    assert result.returncode == 0, output(result)
    assert "unknown" in result.stdout
    assert "nothing left" not in result.stdout


def test_survivors_are_listed_and_task_definition_revisions_counted_apart(tmp_path):
    result, _, _ = run_destroy(tmp_path, STUB_TAGGING="leftovers")

    assert result.returncode == 0, output(result)
    assert "nothing left" not in result.stdout
    assert "natgateway/nat-0abc" in result.stdout

    # Terraform can only deregister task definitions, so these survive every teardown;
    # listing them as survivors would make the check cry wolf every time.
    assert "task-definition/gemma-inference:4" not in result.stdout
    assert "1 ECS task definition revision" in result.stdout
