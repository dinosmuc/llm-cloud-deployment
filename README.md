# Scalable LLM Inference Service on AWS

Self-hosted **Google Gemma 4 (E2B-it)** served with **vLLM** on ECS-on-EC2, behind a CloudFront + ALB edge, with **scale-to-zero** GPU and real-time token streaming to a vanilla HTML/JS chat UI. The whole stack is defined in **Terraform**.

A personal project exploring end-to-end LLM deployment on AWS — the model runs on my own GPU, not a third-party API.

## Architecture

![Architecture](docs/architecture.png)

**Request flow:** browser → CloudFront (static UI from a private S3 bucket via OAC; `/v1/*` → ALB) → WAF → ALB → ECS task. A small **FastAPI proxy** validates the `x-api-key`, then forwards to **vLLM** on localhost with an internal Bearer token; vLLM streams tokens back as Server-Sent Events.

## Highlights

- **Multi-AZ infrastructure** — VPC across 2 AZs; one NAT Gateway per AZ; ALB and Auto Scaling Group span both. See the availability caveat under [Limitations](#limitations).
- **Cost-efficient** — scale-to-zero: 0 GPU when idle, wakes on the first request, returns to 0 after 15 min.
- **Secure** — private subnets (no public IP on the GPU), WAF rate limiting, dual-key auth, secrets in SSM SecureString (KMS) and Hugging Face token via BuildKit secret, private S3 served only via CloudFront OAC.
- **Reproducible** — 100% Terraform, 6 modules, pinned dependencies, one-command deploy into any AWS account.

## Stack

| Layer | Choice |
|---|---|
| IaC | Terraform ≥ 1.10, AWS provider `~> 6.45` (S3 backend, native locking) |
| Compute | ECS-on-EC2 · `g6.xlarge` (NVIDIA L4, BF16) |
| Serving | vLLM v0.20.2 (OpenAI-compatible API) · Gemma 4 E2B-it |
| Proxy | FastAPI sidecar — `x-api-key` auth + SSE pass-through |
| Edge | CloudFront (OAC) + WAFv2 · ALB across 2 AZs |
| Secrets | SSM Parameter Store (SecureString, KMS) |
| Observability | CloudWatch dashboard + alarms · SNS email |
| CI | GitHub Actions — format, validate, unit tests (no AWS access) |

## Prerequisites

**Tools** — these are the versions the project was last built and tested with; the minimums are what it actually requires.

| Tool | Tested | Minimum | Needed for |
|---|---|---|---|
| Terraform | 1.15.6 | 1.10.0 | everything (`use_lockfile` needs ≥ 1.10) |
| AWS CLI | 2.34.0 | 2.x | deploy, state bucket, cache invalidation |
| Docker | 29.5.3 | 23.0 | building the images (needs BuildKit/Buildx) |
| Python | 3.14 (image) / 3.11 (local tests) | 3.11 | proxy + tests |
| Node.js | 24 | 22 | frontend tests only |
| OpenSSL | 3.x | any | generating the API keys on the first deploy |

**AWS account**

- Credentials configured (`aws configure`) with permission to create VPC, ECS, EC2, ALB, CloudFront, S3, ECR, IAM, SSM, WAF and CloudWatch resources.
- GPU quota: **Running On-Demand G and VT instances ≥ 4 vCPU**. This is not granted by default — request it in Service Quotas before deploying, approval can take a day.

**Hugging Face**

`google/gemma-4-E2B-it` requires accepting Google's licence on the model page. Once accepted, create a read token and export it before deploying:

```bash
export HF_TOKEN=hf_...
```

## Deploy

From a clean clone, in any AWS account:

```bash
git clone https://github.com/dinosmuc/llm-cloud-deployment.git
cd llm-cloud-deployment

export HF_TOKEN=hf_...
./scripts/deploy.sh
```

There is no configuration step. `deploy.sh` generates `terraform/terraform.tfvars` on
the first run — two different API keys from `openssl rand -base64 24`, defaults for
everything else — and writes it with mode `600`. It is generated **only when the file
is absent**: the keys live in SSM, so rewriting them on every run would redeploy the
service for no reason.

To pin the values yourself, create the file before deploying and it is left untouched:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # then edit it
```

Or set any of these before the first run — they are read only while generating:

| Variable | Default | |
|---|---|---|
| `ALERT_EMAIL` | *(empty)* | Address for CloudWatch alarm emails. Empty disables the emails; the alarms and the SNS topic are created either way, so an address can be subscribed later. |
| `AWS_REGION` | `eu-central-1` | Region to deploy into. |
| `PROJECT_NAME` | `gemma-inference` | Prefix for every resource name, and for the state bucket. |
| `INSTANCE_TYPE` | `g6.xlarge` | GPU instance type. Gemma 4 attention needs L4-class, not T4. |

```bash
ALERT_EMAIL=you@example.com AWS_REGION=us-east-1 ./scripts/deploy.sh
```

Deleting `terraform.tfvars` makes the next deploy generate fresh keys, which rewrites
the SSM parameters and redeploys the service.

`deploy.sh` prompts twice before it changes anything. To run it unattended — in CI, from
a cron job, or just piped — set `AUTO_APPROVE=1`, which answers both prompts:

```bash
AUTO_APPROVE=1 ./scripts/deploy.sh      # and likewise for ./scripts/destroy.sh
```

`deploy.sh` does everything, in the order that matters:

1. **Preflight** — checks the tools (including `docker buildx`, which the image build requires), credentials, Docker daemon and `HF_TOKEN`, generates `terraform.tfvars` if there is none, and fails early with a clear message if anything is missing. It also warns when the account's GPU vCPU quota is below 4, the most common reason the stack applies cleanly and then never launches an instance.
2. **State backend** — Terraform cannot create its own backend, so the script creates an S3 bucket named `<project_name>-tfstate-<your-account-id>` (versioned, encrypted, public access blocked), writes `terraform/backend.hcl`, and runs `terraform init -backend-config=backend.hcl`. The account ID keeps the globally-unique bucket name collision-free, which is why nothing is hardcoded. Re-runs reuse the existing bucket.
3. **ECR first** — the repository has to exist before images can be pushed, so it is applied on its own with `-target=module.ecr`.
4. **Build and push** — the repository URL is read back with `terraform output -raw ecr_repository_url` and passed to `build_and_push.sh`, so the build can never target a different repo or region than the one ECS reads from. The vLLM image bakes in the model weights and takes 10–15 min the first time.
5. **Apply the rest** — shows a plan, then applies on confirmation.

To run Terraform by hand afterwards, point it at the generated backend config:

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform plan
```

## Use

```bash
cd terraform
terraform output frontend_url
terraform output -raw public_api_key    # -raw is required; the value is marked sensitive
```

Open `frontend_url`, paste the key, and chat.

The **first request after idle** triggers a cold start (~5 min when warm, up to ~15 min on a brand-new deploy) while the GPU launches and vLLM loads the model — the UI shows progress and resends automatically. After that, responses stream sub-second to first token.

## Checks

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r tests/requirements.txt
./scripts/check.sh
```

The virtualenv is not optional on Debian, Ubuntu 23.04+, Fedora and Amazon Linux: their
system Python is marked externally managed, so a bare `pip install` refuses to run.

Runs without AWS credentials, deployment or Docker (a fresh `terraform init` does download providers from the registry):

- `terraform fmt -check` and `terraform validate` (with `-backend=false`)
- shell syntax (`bash -n`) and Python syntax
- **proxy tests** — a missing, wrong or unconfigured `x-api-key` is rejected with 401; a valid one is swapped for the internal Bearer token and the streamed response passes through byte-for-byte
- **frontend test** — an SSE event split across network chunks is reassembled, checked at every possible split point
- **config tests** — the checks a clean clone depends on: `terraform.tfvars.example` declares every variable that has no default, its placeholder keys are the ones `variables.tf` refuses to deploy, `app.js` and the module that renders it agree on the template variables and pass them through `jsonencode`, `deploy.sh`'s own tfvars parser reads the example correctly, and both scripts support `AUTO_APPROVE`. They also run `deploy.sh`'s generation branch for real and check what it wrote: mode `600`, every variable Terraform requires, two different keys that its own validation accepts, valid `fmt`-clean HCL, the four environment overrides, and that a second run leaves an existing file byte-for-byte alone

The same script runs in GitHub Actions on every push and pull request (`.github/workflows/ci.yml`). CI never touches AWS and needs no secrets.

## Teardown

```bash
./scripts/destroy.sh                    # AUTO_APPROVE=1 to skip the prompt
PURGE_STATE=1 ./scripts/destroy.sh      # also delete the Terraform state bucket
```

`destroy.sh` re-creates `backend.hcl` if it is missing, so it works from a fresh clone
too — but it still needs `terraform/terraform.tfvars`, because Terraform requires values
for the variables that have no default before it can build a destroy plan.

It is one command, and it checks its own work:

1. **Destroy, retried once.** If `terraform destroy` fails — typically a timeout while the ECS service drains — the script says so, waits 60 seconds and tries exactly once more. A second failure exits non-zero and leaves the state bucket untouched; fix the cause and run it again. It never retries more than once: a destroy that keeps failing needs a person, not a loop.
2. **Leftover check.** It then asks the Resource Groups Tagging API for anything in the region whose `Name` tag starts with `<project_name>-`, and prints either *nothing left* or the ARNs that survived. Treat it as a smoke test, not a guarantee: resources without a `Name` tag are invisible to it, and global ones such as the CloudFront distribution may not appear in a regional query. ECS task definition revisions are counted separately — Terraform can only deregister them, ECS keeps them as `INACTIVE`, and they cost nothing. If your credentials lack `tag:GetResources`, the result is reported as unknown and the teardown carries on.
3. **State bucket.** Kept by default, and the script prints the command to remove it. `deploy.sh` creates it outside the stack, because a backend cannot create itself, so `terraform destroy` never sees it. It holds the versioned history of the state file, costs next to nothing, and the next deploy reuses it. With `PURGE_STATE=1` the script deletes every object version and delete marker first — the bucket is versioned, so `aws s3 rb --force` alone would fail — and then the bucket itself. Running the script again after a purge is not an error: with no state bucket there is no Terraform state to destroy from, so it skips `terraform destroy` and still runs the leftover check.

## Cost

Idle baseline ≈ **$0.16/hour** (~$118/month), continuous, whether or not anyone uses it:

| Component | Approx. hourly |
|---|---|
| 2 × NAT Gateway | $0.104 |
| ALB | $0.027 |
| Public IPv4 (2 × ALB, 2 × NAT EIP) | $0.020 |
| WAF (web ACL + 2 rules) | $0.010 |

On top of that, ECR storage for the ~18 GB vLLM image is about $1.80/month.

The GPU (~$0.98/hour for `g6.xlarge`) runs only while serving. Tear the stack down between sessions to avoid the idle baseline — that is the single biggest saving.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `VcpuLimitExceeded` / instance never launches | GPU quota not granted. Request **Running On-Demand G and VT instances** ≥ 4 vCPU in Service Quotas. |
| Image build fails downloading the model | `HF_TOKEN` not exported, or Google's licence not accepted on the model page. |
| `denied: Your authorization token has expired` on push | ECR login expires after 12 h. Re-run `./scripts/deploy.sh`, or re-authenticate manually with `aws ecr get-login-password`. |
| No alarm emails | Either `alert_email` is empty, which creates no subscription at all, or the subscription has not been confirmed from the AWS email sent to that address. The alarms themselves fire either way — check them in CloudWatch. |
| UI sits on "Still warming up" | Normal for a cold start. It retries for ~22 min. Beyond that, check the ECS service events and the `/ecs/<project>/vllm` log group. |
| `terraform init` asks for a bucket | You ran it without the backend config. Use `terraform init -backend-config=backend.hcl`, or just run `./scripts/deploy.sh`. |

## Limitations

- **Availability.** The VPC, ALB, NAT Gateways and Auto Scaling Group span two AZs, so the *infrastructure* is multi-AZ. Inference is not: the default configuration runs a single GPU task and scales to zero, so it is unavailable during a cold start and is not active-active. Continuous availability would mean `min_capacity = 1` and paying for an always-on GPU.
- **TLS.** HTTPS terminates at CloudFront. The CloudFront → ALB hop is plain **HTTP** today; end-to-end TLS (ACM certificate + Route 53 custom domain) is future work.
- **The ALB is publicly reachable.** Its security group accepts internet traffic and the HTTP listener forwards by default, so the API can be called directly, bypassing CloudFront. Such a request carries no `X-Forwarded-For` header, and AWS WAF skips a forwarded-IP rule entirely when the header is absent — so it is not rate-limited either. An answer still requires a valid `x-api-key`, but while the service is scaled to zero a direct request can return a 503 and trigger an unauthenticated GPU scale-up. Closing this needs origin verification (a secret header injected by CloudFront and checked by WAF) or API-key validation at the edge; both add moving parts and are left as future work.
- **Rate limiting is best-effort.** AWS WAF aggregates on the *first* address in `X-Forwarded-For`, and CloudFront appends the viewer IP to whatever the client already sent, so a client can influence the aggregation key. The rule raises the cost of casual abuse; it is not a guarantee.
- **Cold start.** Inherent to GPU scale-to-zero — the trade for not paying ~$0.98/hour to idle.
- **Scale ceiling.** A vCPU quota of 4 limits the demo to one `g6.xlarge` at a time, even though `max_capacity` is 3.
- **Single-turn chat.** The UI sends the system prompt plus the current message only; there is no conversation history.
- **The WAF's body rules are counted, not blocked.** Five rules in the AWS Core Rule Set inspect the request body, which for a chat API is the user's own prose — they reject a pasted article (over 8 KB), a question containing `<script>`, a `../` path or a URL with an IPv4 host. They are overridden to `Count`, so they still report to CloudWatch but no longer block. Every other rule in the group, and the rate limit, still block.
- **Scale-out beyond one task is effectively inert.** The target-tracking policy aims at 600 ALB requests per target per minute — 10 requests a second against a single GPU. Streaming inference saturates long before that, so latency alarms fire first and the 1 → N step never triggers. Picking an honest threshold needs load testing this project has not done; the 0 → 1 wake and the N → 0 idle scale-in both work as described.
- **Scale-in is all-or-nothing.** Capacity only ever returns to zero, and only after 15 consecutive minutes of no ALB requests at all. There is no graduated 3 → 2 → 1 step, and a single leftover browser tab polling `/health` is enough to hold the fleet up.
- **Availability zones are chosen by index.** The two subnets take the first two AZs the region reports, without checking that `g6` instances are actually offered there — AZ names map to different physical zones per account. If they are not, `terraform apply` still succeeds and the GPU task simply stays pending. `deploy.sh` warns when the GPU vCPU quota is below 4, which is the more common cause.

## License

MIT — see [LICENSE](LICENSE).
