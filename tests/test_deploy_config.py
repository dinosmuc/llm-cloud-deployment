"""Tests for the contract between the automation and the configuration it reads.

test_proxy.py and sse.test.js both cover the request path. These cover the part a
*different person on a different machine* actually depends on: that
terraform.tfvars.example declares everything Terraform will demand, that the
placeholders it ships are exactly the ones variables.tf refuses to deploy, that
app.js and the module rendering it agree on the template variables, that
deploy.sh's own tfvars parser can read the example file, and that the
terraform.tfvars deploy.sh writes when there is none would actually be accepted.

None of this needs AWS, Docker or a deployment.
"""

import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

VARIABLES_TF = (ROOT / "terraform" / "variables.tf").read_text()
TFVARS_EXAMPLE = (ROOT / "terraform" / "terraform.tfvars.example").read_text()
DEPLOY_SH = (ROOT / "scripts" / "deploy.sh").read_text()
DESTROY_SH = (ROOT / "scripts" / "destroy.sh").read_text()


def variable_blocks():
    """Map each variable name in variables.tf to its block text.

    Sliced between consecutive `variable "x" {` headers rather than by counting
    braces, so a brace inside a description or a validation regex cannot confuse it.
    """
    starts = [
        (m.group(1), m.start())
        for m in re.finditer(r'variable\s+"([^"]+)"\s*\{', VARIABLES_TF)
    ]
    assert starts, "no variable blocks found in variables.tf"

    return {
        name: VARIABLES_TF[pos: starts[i + 1][1] if i + 1 < len(starts) else len(VARIABLES_TF)]
        for i, (name, pos) in enumerate(starts)
    }


def example_value(name):
    match = re.search(r'^\s*%s\s*=\s*"([^"]*)"' % re.escape(name), TFVARS_EXAMPLE, re.M)
    return match.group(1) if match else None


def test_example_tfvars_declares_every_variable_without_a_default():
    """A variable with no default is one Terraform will stop and ask for."""
    required = [
        name
        for name, block in variable_blocks().items()
        if not re.search(r"^\s*default\s*=", block, re.M)
    ]

    assert required, "expected at least one required variable"

    missing = [name for name in required if example_value(name) is None]

    assert not missing, (
        "terraform.tfvars.example is missing required variable(s): "
        + ", ".join(missing)
        + ". A clean clone would fail with 'No value for required variable'."
    )


def test_shipped_placeholder_keys_are_rejected_by_their_own_validation():
    """The example's placeholders must match the pattern variables.tf refuses.

    These two live in different files; if either is edited without the other, the
    project either ships a placeholder it happily deploys or a validation that
    rejects its own example.
    """
    blocks = variable_blocks()

    for name in ("public_api_key", "internal_api_key"):
        pattern = re.search(r'regex\("\(\?i\)([^"]+)"', blocks[name])
        assert pattern, f"{name} has no placeholder-rejecting validation"

        value = example_value(name)
        assert value, f"{name} is missing from terraform.tfvars.example"

        assert re.search(pattern.group(1), value, re.I), (
            f"the {name} placeholder in terraform.tfvars.example would pass "
            f"validation and deploy as a real key"
        )


def test_app_js_template_variables_match_what_the_module_supplies():
    """templatefile() fails on a missing variable and ignores a surplus one."""
    app_js = (ROOT / "frontend" / "app.js").read_text()
    module = (ROOT / "terraform" / "modules" / "frontend" / "main.tf").read_text()

    used = set(re.findall(r"\$\{([a-z_]+)\}", app_js))

    call = re.search(r"templatefile\([^,]+,\s*\{(.*?)\}\)", module, re.S)
    assert call, "could not find the templatefile() call in the frontend module"
    supplied = set(re.findall(r"^\s*([a-z_]+)\s*=", call.group(1), re.M))

    assert used == supplied, (
        f"app.js uses {sorted(used)} but the module supplies {sorted(supplied)}"
    )


def test_template_values_are_json_encoded():
    """app.js declares these bare, so Terraform has to emit the quoting.

    Without jsonencode(), a system_prompt containing a double quote renders an
    app.js that throws SyntaxError — the page loads but nothing works at all.
    """
    app_js = (ROOT / "frontend" / "app.js").read_text()
    module = (ROOT / "terraform" / "modules" / "frontend" / "main.tf").read_text()

    for name in ("alb_url", "system_prompt"):
        assert re.search(r"=\s*\$\{%s\};" % name, app_js), (
            f"{name} must be interpolated unquoted in app.js"
        )
        assert re.search(r"^\s*%s\s*=\s*jsonencode\(" % name, module, re.M), (
            f"{name} must be passed through jsonencode() in the frontend module"
        )


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash not available")
def test_deploy_scripts_tfvars_parser_reads_the_example():
    """deploy.sh derives the state bucket name with this function before Terraform
    ever runs, so a parsing slip would create a bucket under the wrong name."""
    function = re.search(r"^tfvar\(\) \{.*?^\}", DEPLOY_SH, re.M | re.S)
    assert function, "could not find the tfvar() function in deploy.sh"

    script = "\n".join([
        "set -euo pipefail",
        'TFVARS="%s"' % (ROOT / "terraform" / "terraform.tfvars.example"),
        function.group(0),
        'echo "$(tfvar project_name FALLBACK)|$(tfvar aws_region FALLBACK)|'
        '$(tfvar not_a_real_setting FALLBACK)"',
    ])

    out = subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, check=True
    ).stdout.strip()

    assert out == "gemma-inference|eu-central-1|FALLBACK", out


def test_both_scripts_support_unattended_runs():
    """The README documents AUTO_APPROVE=1; without it a piped or CI run of these
    scripts dies at `read` with exit 1 and no message at all."""
    for name, source in (("deploy.sh", DEPLOY_SH), ("destroy.sh", DESTROY_SH)):
        assert "AUTO_APPROVE" in source, f"{name} has no unattended mode"
        assert re.search(r"read -r -p", source), (
            f"{name} must use `read -r -p ... || ...` so end-of-input cannot "
            f"abort the script silently under set -e"
        )


# The generated terraform.tfvars.
#
# deploy.sh writes this file when a clean clone has none, which makes it the only
# configuration most people will ever deploy. It is gitignored, so nothing else in
# CI ever sees it — these tests run the shipped branch and check what it produced.

GENERATION_BRANCH = re.search(
    r'^if \[ ! -f "\$TFVARS" \]; then$.*?^fi$', DEPLOY_SH, re.M | re.S
)

requires_bash_and_openssl = pytest.mark.skipif(
    shutil.which("bash") is None or shutil.which("openssl") is None,
    reason="bash and openssl are needed to run the generation branch",
)


def run_generation_branch(target, **environment):
    """Run deploy.sh's tfvars generation branch against `target`, and nothing else.

    Sliced out of the script rather than reimplemented here, so these tests exercise
    the code that actually ships. The environment is built from scratch so an
    ALERT_EMAIL exported in the developer's own shell cannot change the result.
    """
    assert GENERATION_BRANCH, "could not find the tfvars generation branch in deploy.sh"

    script = "\n".join([
        "set -euo pipefail",
        'TFVARS="%s"' % target,
        GENERATION_BRANCH.group(0),
    ])

    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        check=True,
        env={"PATH": os.environ["PATH"], **environment},
    )


def generated_values(target):
    return dict(
        re.findall(r'^\s*([a-z_]+)\s*=\s*"([^"]*)"$', Path(target).read_text(), re.M)
    )


@requires_bash_and_openssl
def test_generated_tfvars_would_be_accepted_by_variables_tf(tmp_path):
    """The clean-clone path: no tfvars, no ALERT_EMAIL, just `./scripts/deploy.sh`.

    `terraform validate` cannot check this — it does not read variable values at
    all, so a tfvars that every validation block rejects still validates clean. The
    conditions are therefore read out of variables.tf and applied here.
    """
    target = tmp_path / "terraform.tfvars"
    run_generation_branch(target)

    assert target.exists(), "deploy.sh did not generate terraform.tfvars"

    # NTFS through Git Bash reports whatever it likes for st_mode, so asserting the
    # mode there fails on a filesystem that cannot express it rather than on a real
    # defect. Probe the filesystem instead of the platform name: under WSL2 or a
    # Linux container the check must still run, and only the probe can tell them
    # apart. chmod is what deploy.sh relies on, so if the probe cannot hold 0600
    # neither can the real file.
    probe = tmp_path / ".mode-probe"
    probe.write_text("")
    probe.chmod(0o600)

    if stat.S_IMODE(probe.stat().st_mode) == 0o600:
        assert stat.S_IMODE(target.stat().st_mode) == 0o600, (
            "terraform.tfvars holds two secrets in plaintext and must not be readable "
            "by other accounts on the machine"
        )
    else:
        print(
            "\n  note: filesystem does not enforce POSIX modes, so the 0600 check on "
            "terraform.tfvars was not applied. On such a filesystem the file is not "
            "protected from other accounts; use WSL2 or Linux/macOS to verify it."
        )

    values = generated_values(target)
    blocks = variable_blocks()

    required = [
        name
        for name, block in blocks.items()
        if not re.search(r"^\s*default\s*=", block, re.M)
    ]
    missing = [name for name in required if name not in values]
    assert not missing, (
        "the generated terraform.tfvars is missing required variable(s): "
        + ", ".join(missing)
        + ". A clean clone would fail with 'No value for required variable'."
    )

    public, internal = values["public_api_key"], values["internal_api_key"]

    assert public != internal, (
        "the two keys are identical, which variables.tf rejects — generate them "
        "with two separate calls to openssl"
    )

    for name, value in (("public_api_key", public), ("internal_api_key", internal)):
        assert len(value) >= 20, f"{name} is {len(value)} characters, minimum is 20"

        placeholder = re.search(r'regex\("\(\?i\)([^"]+)"', blocks[name])
        assert placeholder, f"{name} has no placeholder-rejecting validation"
        assert not re.search(placeholder.group(1), value, re.I), (
            f"the generated {name} matches the placeholder pattern variables.tf "
            f"refuses to deploy"
        )

    assert values["alert_email"] == "", (
        "with ALERT_EMAIL unset the generated alert_email must be empty, which is "
        "the documented opt-out"
    )

    header = target.read_text().splitlines()[0]
    assert "Generated by scripts/deploy.sh" in header, (
        "the file must say where it came from; someone will find it months later"
    )


@requires_bash_and_openssl
def test_generation_never_touches_an_existing_tfvars(tmp_path):
    """Regenerating on every run would rewrite the two SSM parameters and force a
    redeployment of the service each time deploy.sh is invoked."""
    target = tmp_path / "terraform.tfvars"

    run_generation_branch(target)
    before = target.read_bytes()

    result = run_generation_branch(
        target,
        ALERT_EMAIL="someone@example.com",
        AWS_REGION="us-east-1",
        PROJECT_NAME="something-else",
    )

    assert target.read_bytes() == before, (
        "an existing terraform.tfvars was modified; it must be left completely alone"
    )
    assert result.stdout == "", "nothing should be printed when the file already exists"


@requires_bash_and_openssl
def test_environment_overrides_reach_the_generated_file(tmp_path):
    """The four documented overrides. Only these — everything else is a default."""
    target = tmp_path / "terraform.tfvars"

    run_generation_branch(
        target,
        ALERT_EMAIL="ops@example.com",
        AWS_REGION="us-east-1",
        PROJECT_NAME="my-llm",
        INSTANCE_TYPE="g6.2xlarge",
    )

    values = generated_values(target)

    assert values["alert_email"] == "ops@example.com"
    assert values["aws_region"] == "us-east-1"
    assert values["project_name"] == "my-llm"
    assert values["instance_type"] == "g6.2xlarge"


@requires_bash_and_openssl
@pytest.mark.skipif(shutil.which("terraform") is None, reason="terraform not installed")
def test_generated_tfvars_is_valid_hcl_and_stays_fmt_clean(tmp_path):
    """`terraform fmt` parses the file, so it fails on malformed HCL.

    It matters twice over: the generated file lands inside terraform/, where
    check.sh's own `terraform fmt -check -recursive` picks it up. Emitting
    misaligned assignments would break the checks for everyone who has deployed.
    """
    target = tmp_path / "terraform.tfvars"
    run_generation_branch(target, ALERT_EMAIL="ops@example.com")

    result = subprocess.run(
        ["terraform", "fmt", "-check", "-diff", str(target)],
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, (
        "the generated terraform.tfvars is not valid, canonically formatted HCL:\n"
        + result.stdout
        + result.stderr
    )
