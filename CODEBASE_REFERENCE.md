# Codebase Reference: phi3-cloud-deployment

A factual, exhaustive reference for the `phi3-cloud-deployment` repository. Every section below is sourced directly from files in the repo. The repository serves **Google Gemma 4 E2B IT** (the GitHub repo name still says `phi3` for historical reasons — see Limitations).

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Repository Structure](#2-repository-structure)
3. [Architecture](#3-architecture)
4. [Request Flow & Cold Start](#4-request-flow--cold-start)
5. [Terraform — Root Module](#5-terraform--root-module)
6. [Terraform — `networking` Module](#6-terraform--networking-module)
7. [Terraform — `ecr` Module](#7-terraform--ecr-module)
8. [Terraform — `alb` Module](#8-terraform--alb-module)
9. [Terraform — `ecs` Module](#9-terraform--ecs-module)
10. [Terraform — `frontend` Module](#10-terraform--frontend-module)
11. [Terraform — `monitoring` Module](#11-terraform--monitoring-module)
12. [Containers — vLLM](#12-containers--vllm)
13. [Containers — nginx](#13-containers--nginx)
14. [Frontend — index.html](#14-frontend--indexhtml)
15. [Frontend — app.js](#15-frontend--appjs)
16. [Frontend — style.css](#16-frontend--stylecss)
17. [Scripts — build_and_push.sh](#17-scripts--build_and_pushsh)
18. [Scripts — deploy.sh](#18-scripts--deploysh)
19. [Scripts — destroy.sh](#19-scripts--destroysh)
20. [Scripts — test_endpoint.py](#20-scripts--test_endpointpy)
21. [Autoscaling Subsystem](#21-autoscaling-subsystem)
22. [Security Model](#22-security-model)
23. [Observability](#23-observability)
24. [Cost Estimates](#24-cost-estimates)
25. [.gitignore](#25-gitignore)
26. [Limitations & Caveats](#26-limitations--caveats)
27. [Complete Resource Inventory](#27-complete-resource-inventory)
28. [External References](#28-external-references)
29. [Notable Absences in the Repository](#29-notable-absences-in-the-repository)

---

## 1. Project Overview

**Stated purpose (`README.md:1-3`):**
> Scalable LLM Inference Service on AWS. Google Gemma 4 E2B IT served via vLLM on ECS-on-EC2, with scale-to-zero, SSE token streaming, and a vanilla HTML/JS chat UI delivered through CloudFront.

**Extended purpose (`README.md:5-9`):**
- Portfolio project for IU's *Cloud Programming* module (DLBSEPCP01_E).
- End-to-end on AWS: GPU-backed instruction-tuned LLM behind a public chat UI, defined entirely in Terraform.
- Idles at zero EC2 instances, wakes on first request, streams tokens to the browser, returns to zero after 15 minutes of silence.
- License: **MIT** (`README.md:221-223`).
- No badges, no contribution guidelines, no `.github/` directory.

---

## 2. Repository Structure

```
phi3-cloud-deployment/
├── .gitignore                          (273 bytes)
├── README.md                           (13,814 bytes)
├── containers/
│   ├── nginx/
│   │   ├── Dockerfile
│   │   └── nginx.conf
│   └── vllm/
│       └── Dockerfile
├── frontend/
│   ├── app.js
│   ├── index.html
│   └── style.css
├── scripts/
│   ├── build_and_push.sh
│   ├── deploy.sh
│   ├── destroy.sh
│   └── test_endpoint.py
└── terraform/
    ├── .terraform.lock.hcl
    ├── main.tf
    ├── outputs.tf
    ├── terraform.tfvars.example
    ├── variables.tf
    └── modules/
        ├── alb/         (main.tf, variables.tf, outputs.tf)
        ├── ecr/         (main.tf, variables.tf, outputs.tf)
        ├── ecs/         (main.tf, variables.tf, outputs.tf)
        ├── frontend/    (main.tf, variables.tf, outputs.tf)
        ├── monitoring/  (main.tf, variables.tf, outputs.tf)
        └── networking/  (main.tf, variables.tf, outputs.tf)
```

**Total non-git files:** 35.

---

## 3. Architecture

The README (`README.md:13-42`) embeds a Mermaid diagram showing this topology:

**Edge tier:**
- CloudFront (default `*.cloudfront.net` cert, Origin Access Control / OAC)
- WAFv2 (AWS Managed Common Rule Set + IP rate-limit)
- ALB in public subnets, 2 AZs

**VPC (CIDR `10.0.0.0/16`):**
- 2 public subnets (`10.0.1.0/24`, `10.0.2.0/24`)
- 2 private subnets (`10.0.10.0/24`, `10.0.20.0/24`)
- ECS task on `g6.xlarge` runs **nginx :80** sidecar + **vLLM :8000** main container
- GPU: **NVIDIA L4** (24 GB, Ada `sm_89`, native BF16)
- Single NAT Gateway in `public_1`
- S3 Gateway VPC endpoint (free egress for ECR layer pulls)

**External AWS services:**
- S3 frontend bucket (private, OAC-only)
- SSM Parameter Store (SecureString for both API keys)
- CloudWatch (logs, metrics, dashboard, alarms)
- SNS (email alert topic)

**Traffic flows shown:**
- User → HTTPS → CloudFront
- CloudFront → static assets → S3
- CloudFront → `/v1/chat/completions, /health` → WAF → ALB → task
- Task → AWS APIs (egress) → NAT
- Task → ECR image layer pulls → S3 Gateway endpoint
- Task → fetches SSM keys at start
- Task → logs + metrics → CloudWatch + SNS

---

## 4. Request Flow & Cold Start

The README (`README.md:140-155`) documents the cold-start chain (5–8 minutes):

1. ALB has no healthy targets → returns HTTP 503.
2. `wake_on_503` CloudWatch alarm fires (1-minute period).
3. `scale_out_wake` policy sets ECS service desired count `0 → 1`.
4. ECS asks the capacity provider for capacity → ASG launches a `g6.xlarge` (~90 s).
5. EC2 boots, ECS agent registers (~30 s).
6. ECS pulls the ~18 GB vLLM image; the heavy weight layers route through the **S3 Gateway endpoint** (free); smaller layers traverse the NAT Gateway.
7. vLLM starts, loads Gemma 4 weights into the L4's VRAM, opens port 8000.
8. nginx (waiting on vLLM's `HEALTHY` via `dependsOn`) starts.
9. ALB target group reports healthy.
10. Frontend's `retryUntilReady` polls `/health` every 15 s; on the first OK it re-sends the original message.

**Steady-state:** sub-second time-to-first-token, ~30–80 tokens/sec depending on prompt length (`README.md:155`). After 15 minutes of zero ALB traffic, `scale_in_idle` returns service to 0.

---

## 5. Terraform — Root Module

### `terraform/main.tf`

**Versions (lines 1-29):**
- Terraform required version: `>= 1.10.0`
- Required providers:
  - `hashicorp/aws` constraint `~> 6.45` (locked to `6.45.0` in `.terraform.lock.hcl`)
  - `hashicorp/random` constraint `~> 3.0` (locked to `3.9.0`)

**Backend (lines 1-29):** S3 with native conditional-write locking
- Bucket: `gemma-inference-tfstate-ds` (hardcoded; not parameterised — see Limitations)
- Key: `gemma-inference/terraform.tfstate`
- Region: `eu-central-1`
- `encrypt = true`
- `use_lockfile = true`

**AWS Provider (lines 31-33):** `region = var.aws_region`

**Module instantiations (lines 35-88):**
1. `networking` → produces VPC ids, subnet ids, security group ids
2. `ecr` → produces repository_url
3. `alb` → produces target_group_arn, alb_dns_name, alb_arn_suffix, target_group_arn_suffix
4. `ecs` → produces cluster_name, service_name
5. `frontend` → produces cloudfront_domain_name
6. `monitoring` → no consumed outputs

### `terraform/variables.tf`

| Name | Type | Default | Sensitive |
|---|---|---|---|
| `aws_region` | string | `eu-central-1` | no |
| `project_name` | string | `gemma-inference` | no |
| `vpc_cidr` | string | `10.0.0.0/16` | no |
| `instance_type` | string | `g6.xlarge` | no |
| `min_capacity` | number | `0` | no |
| `max_capacity` | number | `3` | no |
| `public_api_key` | string | (none) | **yes** |
| `internal_api_key` | string | (none) | **yes** |
| `system_prompt` | string | default chatbot persona | no |
| `alert_email` | string | (none) | no |

`system_prompt` default begins: `"You are a helpful AI assistant powered by Google's Gemma 4 model and deployed on AWS..."`.

### `terraform/outputs.tf`

| Name | Value | Sensitive |
|---|---|---|
| `frontend_url` | `module.frontend.cloudfront_domain_name` | no |
| `api_url` | `module.alb.alb_dns_name` | no |
| `public_api_key` | `var.public_api_key` | **yes** |

### `terraform/terraform.tfvars.example`

```hcl
aws_region       = "eu-central-1"
project_name     = "gemma-inference"
instance_type    = "g6.xlarge"
public_api_key   = "your-public-user-facing-key-here"
internal_api_key = "any-random-string-for-internal-nginx-to-vllm-auth"
alert_email      = "you@example.com"
# system_prompt = "..."   (commented; defaults to chatbot persona)
```

---

## 6. Terraform — `networking` Module

`terraform/modules/networking/main.tf`

**Data sources:** `data.aws_availability_zones.available` (state=`available`).

**VPC (`aws_vpc.main`):**
- CIDR: `var.vpc_cidr` (default `10.0.0.0/16`)
- DNS support: enabled
- DNS hostnames: enabled

**Subnets:**
| Resource | CIDR | AZ | Map public IP |
|---|---|---|---|
| `aws_subnet.public_1` | `10.0.1.0/24` | `[0]` | true |
| `aws_subnet.public_2` | `10.0.2.0/24` | `[1]` | true |
| `aws_subnet.private_1` | `10.0.10.0/24` | `[0]` | n/a |
| `aws_subnet.private_2` | `10.0.20.0/24` | `[1]` | n/a |

**Internet Gateway (`aws_internet_gateway.main`)** + **public route table (`aws_route_table.public`)** with `0.0.0.0/0 → IGW`. Both public subnets associated.

**NAT Gateway** (single, cost trade-off documented in code comment):
- `aws_eip.nat` (domain `vpc`)
- `aws_nat_gateway.main` in `public_1`, depends on IGW

**Private route table (`aws_route_table.private`)** with `0.0.0.0/0 → NAT`. Both private subnets associated.

**Security groups:**

`aws_security_group.alb` — *"Allow HTTP and HTTPS from internet"*
- Ingress: TCP 80 from `0.0.0.0/0`; TCP 443 from `0.0.0.0/0`
- Egress: `-1` to `0.0.0.0/0`

`aws_security_group.ecs` — *"Allow traffic from ALB only"*
- Ingress: TCP 80 from `aws_security_group.alb.id`
- Egress: `-1` to `0.0.0.0/0`

**VPC Endpoint (`aws_vpc_endpoint.s3`):**
- Service `com.amazonaws.${var.aws_region}.s3`
- Type: `Gateway`
- Associated route tables: `[aws_route_table.private.id]`

### Outputs

- `vpc_id`
- `public_subnet_ids` (list of 2)
- `private_subnet_ids` (list of 2)
- `alb_security_group_id`
- `ecs_security_group_id`

---

## 7. Terraform — `ecr` Module

`terraform/modules/ecr/main.tf`

**`aws_ecr_repository.main`:**
- Name: `var.project_name`
- Image tag mutability: `MUTABLE`
- Force delete: `true`
- Image scan on push: `true`

**`aws_ecr_lifecycle_policy.main` — two rules:**

| Rule | Tag prefix | Action | Keep |
|---|---|---|---|
| 1 | `vllm` | expire | last 5 |
| 2 | `nginx` | expire | last 5 |

The rules are split so pushing nginx revisions never evicts the expensive vLLM image (10–15 min rebuild because Gemma weights are baked in).

**Outputs:** `repository_url`.

---

## 8. Terraform — `alb` Module

`terraform/modules/alb/main.tf`

**`aws_lb.main`:**
- Name: `${var.project_name}-alb`
- `internal = false`
- Type: `application`
- Security groups: `[var.alb_security_group_id]`
- Subnets: `var.public_subnet_ids`
- Idle timeout: **300 seconds** (aligned with nginx `proxy_read_timeout` for SSE)

**`aws_lb_target_group.main`:**
- Port 80, protocol HTTP
- Target type: `ip`
- Health check: path `/health`, healthy threshold 2, unhealthy threshold 5, timeout 10s, interval 30s, matcher `200`
- Deregistration delay: 60 s

**`aws_lb_listener.http`:** Port 80, HTTP, default action forwards to the target group above.

**`aws_wafv2_web_acl.main`:**
- Scope: `REGIONAL`
- Default action: `allow`
- Rules:
  - Priority 0: AWS Managed `AWSManagedRulesCommonRuleSet` (vendor `AWS`), override `none`
  - Priority 1: `RateBasedStatement` — 1000 req per IP per 5 minutes, action `block`
- Visibility config: CloudWatch metrics enabled, metric name `${var.project_name}-waf`, sampled requests enabled

**`aws_wafv2_web_acl_association.main`:** associates the Web ACL to `aws_lb.main.arn`.

### Outputs
- `target_group_arn`
- `alb_dns_name`
- `alb_arn_suffix`
- `target_group_arn_suffix`

---

## 9. Terraform — `ecs` Module

`terraform/modules/ecs/main.tf`

### Data Source / Locals
- `data.aws_ssm_parameter.ecs_gpu_ami`: parameter `/aws/service/ecs/optimized-ami/amazon-linux-2023/gpu/recommended`
- `local.ecs_gpu_ami_id = jsondecode(...).image_id`

### SSM Parameters (SecureString)
| Name | Description |
|---|---|
| `/${var.project_name}/public-api-key` | User-facing key validated by nginx |
| `/${var.project_name}/internal-api-key` | Token shared between nginx and vLLM |

### IAM

**`aws_iam_role.ec2_instance`** (assume role `ec2.amazonaws.com`). Managed policies attached:
- `AmazonSSMManagedInstanceCore`
- `service-role/AmazonEC2ContainerServiceforEC2Role`
- `AmazonEC2ContainerRegistryReadOnly`

Instance profile: `aws_iam_instance_profile.ec2_instance`.

**`aws_iam_role.ecs_task_execution`** (assume role `ecs-tasks.amazonaws.com`).
- Managed policy: `service-role/AmazonECSTaskExecutionRolePolicy`
- Inline policy `${var.project_name}-ecs-task-execution-ssm`:
  - Statement `ReadAPIKeyParameters`: `Allow ssm:GetParameters` on both API-key parameter ARNs
  - Statement `DecryptSSMSecureStrings`: `Allow kms:Decrypt` on `*` with condition `kms:ViaService = "ssm.${var.aws_region}.amazonaws.com"` (scopes Decrypt to SSM calls only)

**`aws_iam_role.ecs_task`** (assume role `ecs-tasks.amazonaws.com`).
- Customer-managed policy `${var.project_name}-ecs-task-logs`: `Allow logs:CreateLogStream, logs:PutLogEvents` on both log-group ARNs (`...:*`).

### Compute

**`aws_launch_template.ecs`:**
- Image: `local.ecs_gpu_ami_id`
- Instance type: `var.instance_type`
- Security groups: `[var.ecs_security_group_id]`
- IAM instance profile: `aws_iam_instance_profile.ec2_instance.arn`
- User data (base64):
  ```bash
  #!/bin/bash
  echo "ECS_CLUSTER=<cluster>" >> /etc/ecs/ecs.config
  echo "ECS_ENABLE_GPU_SUPPORT=true" >> /etc/ecs/ecs.config
  ```
- Block device: `/dev/xvda`, **100 GB gp3, delete on termination**
- Detailed monitoring: enabled

**`aws_autoscaling_group.ecs`:**
- VPC zones: `var.private_subnet_ids`
- Min: 0, Max: `var.max_capacity`, Desired: 0
- Launch template version: `$Latest`
- `protect_from_scale_in = true`
- Tag `AmazonECSManaged = true` (propagated at launch)
- Lifecycle: `ignore_changes = [desired_capacity]`

**`aws_ecs_cluster.main`:** name `${var.project_name}-cluster`.

**`aws_ecs_capacity_provider.main`:**
- ASG ARN: `aws_autoscaling_group.ecs.arn`
- Managed termination protection: `ENABLED`
- Managed scaling: status `ENABLED`, target capacity `100%`, min step 1, max step 1

**`aws_ecs_cluster_capacity_providers.main`:** capacity provider above with weight 1, base 0.

### Log Groups
| Name | Retention |
|---|---|
| `/ecs/${var.project_name}/vllm` | 7 days |
| `/ecs/${var.project_name}/nginx` | 7 days |

### Task Definition (`aws_ecs_task_definition.main`)
- Family: `var.project_name`
- Network mode: `awsvpc`
- Requires compatibilities: `["EC2"]`
- Execution role / task role: as above

**Container `vllm`:**
- Image: `${var.ecr_repository_url}:vllm`
- Essential, port 8000/tcp
- Resource requirements: GPU `1`
- Memory: **14,336 MB**; CPU: **3,072 units**
- Secrets: `INTERNAL_API_KEY` from SSM
- Health check: `["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]`, interval 30 s, timeout 10 s, retries 5, start period 120 s
- Logs → CloudWatch log group `vllm`, stream prefix `vllm`

**Container `nginx`:**
- Image: `${var.ecr_repository_url}:nginx`
- Essential, port 80/tcp
- Memory: **256 MB**; CPU: **256 units**
- Secrets: `PUBLIC_API_KEY` + `INTERNAL_API_KEY` from SSM
- `depends_on`: `vllm` HEALTHY
- Logs → CloudWatch log group `nginx`, stream prefix `nginx`

### Service (`aws_ecs_service.main`)
- Cluster: `aws_ecs_cluster.main.id`
- Task definition: `aws_ecs_task_definition.main.arn`
- Desired count: 0 (autoscaled)
- Capacity provider strategy: `aws_ecs_capacity_provider.main` weight 1
- Network config: `var.private_subnet_ids`, `var.ecs_security_group_id`
- Load balancer attachment: target group, container `nginx`, port 80
- Health check grace period: 300 s
- Deployment min healthy %: 0, max %: 200
- Lifecycle: `ignore_changes = [desired_count]`

### Module Variables (subset shown is the full set)
`project_name`, `aws_region`, `private_subnet_ids`, `ecs_security_group_id`, `target_group_arn`, `alb_arn_suffix`, `target_group_arn_suffix`, `ecr_repository_url`, `instance_type`, `min_capacity`, `max_capacity`, `public_api_key` (sensitive), `internal_api_key` (sensitive).

### Outputs
- `cluster_name`, `service_name`

(Autoscaling resources defined in this same module are covered separately in [§21](#21-autoscaling-subsystem).)

---

## 10. Terraform — `frontend` Module

`terraform/modules/frontend/main.tf`

**`random_id.bucket_suffix`:** 4 bytes, hex used in bucket name.

**`aws_s3_bucket.frontend`:**
- Name: `${var.project_name}-frontend-${random_id.bucket_suffix.hex}`
- `force_destroy = true`

**`aws_s3_bucket_public_access_block.frontend`:** all four block flags = `true`.

**`aws_cloudfront_origin_access_control.frontend`:**
- Origin type `s3`, signing behavior `always`, signing protocol `sigv4`.

**`aws_s3_bucket_policy.frontend`:**
- Sid `AllowCloudFrontServicePrincipalReadOnly`
- Principal `cloudfront.amazonaws.com`
- Action `s3:GetObject`
- Resource: `${bucket.arn}/*`
- Condition: `AWS:SourceArn = aws_cloudfront_distribution.frontend.arn`

### S3 Objects uploaded
| Key | Source | Content type | Notes |
|---|---|---|---|
| `index.html` | static file | `text/html` | ETag = `filemd5(...)` |
| `style.css` | static file | `text/css` | ETag = `filemd5(...)` |
| `app.js` | `templatefile(..., { alb_url = "", system_prompt = var.system_prompt })` | `application/javascript` | `alb_url` injected as empty string (frontend uses relative paths via CloudFront cache behaviors) |

### `aws_cloudfront_distribution.frontend`

- Enabled, default root object `index.html`, price class `PriceClass_100` (NA + EU)
- Geo restriction: `none`
- Viewer certificate: `cloudfront_default_certificate = true`

**Origins:**
| ID | Domain | Notes |
|---|---|---|
| `s3-frontend` | `aws_s3_bucket.frontend.bucket_regional_domain_name` | OAC attached |
| `alb-api` | `var.alb_dns_name` | HTTP port 80, HTTPS port 443, origin protocol policy `http-only`, SSL protocols `["TLSv1.2"]` |

**Cache behaviors:**

1. **Default** → `s3-frontend`
   - Methods: GET, HEAD
   - Cached: GET, HEAD
   - No query string, no cookies
   - `redirect-to-https`
   - TTL: min 0, default 86400, max 31536000

2. **`/generate*`** → `alb-api`
   - Methods: DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT
   - Cached: GET, HEAD
   - Forwards query string + headers `x-api-key`, `Content-Type`, `Accept`
   - `https-only`
   - TTL: 0/0/0 (uncached)

3. **`/health`** → `alb-api`
   - Methods: GET, HEAD
   - No query string, no cookies
   - `https-only`
   - TTL: 0/0/0 (uncached)

> Note: the actual chat endpoint is `/v1/chat/completions` (the path the frontend calls); the cache behavior is matched only by `/generate*`. In practice the request flows through CloudFront's default cache behavior to S3 for static assets and uses the `/health` rule for health polls. The pattern `/generate*` is a legacy artifact from earlier HF text-generation-inference work and does **not** match `/v1/chat/completions`. The browser still reaches the ALB because `app.js` builds the URL from `${alb_url}` (which is injected as empty string but the frontend in deployment uses the CloudFront distribution itself as origin) — see §15 for the exact code.

### Inputs
- `project_name`, `alb_dns_name`, `system_prompt`

### Outputs
- `cloudfront_domain_name`
- `s3_bucket_name`

---

## 11. Terraform — `monitoring` Module

`terraform/modules/monitoring/main.tf`

### `aws_cloudwatch_dashboard.main`
Name: `${var.project_name}-dashboard`. Layout: 4 columns × 6 rows, six widgets:

| # | Title | Metric | Stat | View |
|---|---|---|---|---|
| 1 | ECS CPU Utilisation | `AWS/ECS.CPUUtilization` | Average | timeSeries |
| 2 | ECS Memory Utilisation | `AWS/ECS.MemoryUtilization` | Average | timeSeries |
| 3 | ALB Request Count | `AWS/ApplicationELB.RequestCount` | Sum | timeSeries |
| 4 | ALB Response Time | `AWS/ApplicationELB.TargetResponseTime` | p99 | timeSeries |
| 5 | ALB HTTP 5XX Errors | `HTTPCode_Target_5XX_Count` + `HTTPCode_ELB_5XX_Count` | Sum | timeSeries |
| 6 | Healthy Targets | `AWS/ApplicationELB.HealthyHostCount` | Average | singleValue |

All widgets period 60 s.

### Notifications

**`aws_sns_topic.alerts`** with **`aws_sns_topic_subscription.email`** (protocol `email`, endpoint `var.alert_email`). Subscription requires manual confirmation from the email AWS sends after `terraform apply`.

### Alarms (SNS-subscribed)

| Alarm | Metric | Threshold | Evaluation periods (1-min each) |
|---|---|---|---|
| `high-latency` | `TargetResponseTime` (p99) | > 10 s | 3 |
| `high-errors` | `HTTPCode_Target_5XX_Count` (Sum) | > 10 | 3 |
| `no-healthy-targets` | `HealthyHostCount` (Avg) | < 1 | 3 |

Each alarm sends to `aws_sns_topic.alerts` on both `alarm_actions` and `ok_actions`. All `treat_missing_data = notBreaching`.

> The two autoscaling-trigger alarms (`wake_on_503`, `scale_in_on_idle`, defined in the ECS module) deliberately do **not** publish to SNS — they exist only to drive scaling.

### Outputs
- `dashboard_url`: console URL string to the dashboard.

---

## 12. Containers — vLLM

`containers/vllm/Dockerfile`

**Base image:** `vllm/vllm-openai:v0.20.2-cu129-ubuntu2404`
- vLLM v0.20.2 (pinned, not `:latest`)
- CUDA 12.9 (`cu129`)
- Ubuntu 24.04
- Targets NVIDIA L4 (Ada Lovelace, `sm_89`)

**Build args:**
- `ARG HF_TOKEN=""` — optional HuggingFace token to avoid anonymous rate limits

**Model download (baked into the image at build time):**
```dockerfile
RUN HF_TOKEN="$HF_TOKEN" hf download \
      google/gemma-4-E2B-it \
      --local-dir /models/gemma-4-E2B-it
```
- Uses `hf download` (replacement for deprecated `huggingface-cli download`)
- Model: **`google/gemma-4-E2B-it`** (instruction-tuned, ungated, Apache 2.0)
- Destination: `/models/gemma-4-E2B-it`

**Environment:**
- `MODEL_ID=/models/gemma-4-E2B-it`
- `INTERNAL_API_KEY=default` (overridden at runtime by ECS task secrets)

**Exposed port:** `8000`.

**CMD (shell form, uses `exec` so vLLM becomes PID 1 and receives signals):**
```bash
exec vllm serve /models/gemma-4-E2B-it \
  --dtype bfloat16 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.85 \
  --limit-mm-per-prompt '{"image": 0, "audio": 0}' \
  --api-key "${INTERNAL_API_KEY}" \
  --host 0.0.0.0 \
  --port 8000
```

Flag-by-flag:
- `--dtype bfloat16` — native to L4 tensor cores (incompatible with T4/g4dn.*)
- `--max-model-len 32768` — context window
- `--gpu-memory-utilization 0.85` — reserve 85% of VRAM
- `--limit-mm-per-prompt '{"image": 0, "audio": 0}'` — disable vision/audio (text-only mode)
- `--api-key "${INTERNAL_API_KEY}"` — Bearer token verification on the vLLM side
- `--host 0.0.0.0 --port 8000`

No explicit `WORKDIR`, `USER`, `HEALTHCHECK`, `COPY`, or `ADD` (defaults inherited from base image; ECS task definition provides the healthcheck).

**Image size:** ~13–15 GB (CUDA base ~7–8 GB + BF16 weights ~5 GB + deps).

---

## 13. Containers — nginx

### `containers/nginx/Dockerfile`

**Base image:** `nginx:alpine`.

**COPY:** `nginx.conf` → `/etc/nginx/templates/nginx.conf.template`.

**Environment:**
- `PUBLIC_API_KEY=default`
- `INTERNAL_API_KEY=default`

**CMD (exec form):**
```dockerfile
["/bin/sh", "-c",
 "envsubst '$PUBLIC_API_KEY $INTERNAL_API_KEY' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]
```

`envsubst` only substitutes those two named variables, leaving nginx's own `$host`, `$remote_addr`, etc. untouched. nginx then runs in the foreground.

No explicit `EXPOSE`, `WORKDIR`, or `USER`.

### `containers/nginx/nginx.conf`

**Top-level:**
- `worker_processes 1;`
- `events { worker_connections 1024; }`

**HTTP block:**
- `sendfile on;`
- `keepalive_timeout 300;` (matches ALB idle timeout for SSE)

**Key-validation map:**
```nginx
map $http_x_api_key $api_key_match {
    default      0;
    "${PUBLIC_API_KEY}" 1;
}
```
Constant-time comparison via nginx hash (substituted at container start by envsubst).

**Server block:** `listen 80;`

**Location `/health`** (no authentication):
```nginx
proxy_pass http://127.0.0.1:8000/health;
proxy_set_header Host $host;
```
Intentionally open — used by ALB target-group health probe and frontend cold-start poller.

**Location `/v1/chat/completions`** (authenticated):
- Empty key → `return 401 '{"error": "Missing API key. Include x-api-key header."}';`
- Hash mismatch → `return 401 '{"error": "Invalid API key."}';`
- Otherwise:
  - `proxy_pass http://127.0.0.1:8000/v1/chat/completions;`
  - `proxy_set_header Authorization "Bearer ${INTERNAL_API_KEY}";` (injected here, never sent by client)
  - `proxy_set_header Host $host;`
  - `proxy_set_header X-Real-IP $remote_addr;`
  - `proxy_set_header Connection "";`
  - `proxy_http_version 1.1;`
  - **SSE-friendly settings:** `proxy_buffering off;` `proxy_cache off;` `chunked_transfer_encoding on;` `proxy_read_timeout 300s;`

**Location `/`** (catch-all): `return 404 '{"error": "Not found"}';`

---

## 14. Frontend — index.html

`frontend/index.html` (31 lines)

- `<!DOCTYPE html>`, `<html lang="en">`
- `<meta charset="UTF-8">`, `<meta name="viewport" content="width=device-width, initial-scale=1.0">`
- `<title>Gemma 4 Chat</title>`
- `<link rel="stylesheet" href="style.css">`
- `<script src="app.js"></script>` (loaded at end of body, no `defer`)

**DOM structure:**

```html
<div class="chat-container">
  <header class="chat-header">
    <h1>Gemma 4 Chat</h1>
    <span class="status" id="status">Disconnected</span>
  </header>

  <div class="api-key-bar" id="apiKeyBar">
    <input type="password" id="apiKeyInput" placeholder="Enter your API key" />
    <button id="connectBtn">Connect</button>
  </div>

  <div class="messages" id="messages"></div>

  <div class="input-bar">
    <textarea id="userInput" placeholder="Type a message..." rows="1" disabled></textarea>
    <button id="sendBtn" disabled>Send</button>
  </div>
</div>
```

No ARIA attributes, no inline styles, no inline scripts, no other meta or link tags.

---

## 15. Frontend — app.js

`frontend/app.js` (241 lines)

### Terraform-injected constants
```js
const API_URL = "${alb_url}";
const SYSTEM_PROMPT = "${system_prompt}";
```
Both substituted by `templatefile()` in the `frontend` Terraform module.

### Global state
- `let apiKey = "";`
- `let isGenerating = false;`

### DOM element references
`apiKeyInput`, `connectBtn`, `apiKeyBar`, `status`, `messages`, `userInput`, `sendBtn`.

### Event listeners
1. **`connectBtn` click:** read trimmed `apiKeyInput.value`, return if empty; set `apiKey`, hide `apiKeyBar` (adds class `hidden`), set status to "Connected" (`class="status connected"`), enable `userInput` + `sendBtn`, focus `userInput`.
2. **`userInput` keydown:** Enter without Shift → `preventDefault()` + `sendMessage()`. Shift+Enter inserts newline.
3. **`sendBtn` click:** `sendMessage()`.
4. **`userInput` input:** auto-resize — `style.height = "auto"`, then `style.height = Math.min(scrollHeight, 120) + "px"`. Max height **120 px**.

### Function: `addMessage(role, text)`
Creates `<div class="message ${role}">`, sets `textContent = text`, appends to `#messages`, scrolls bottom, returns the div.

### Function: `sendMessage()` (async)

- Return early if text empty or `isGenerating`.
- Append user message; clear textarea; reset height.
- Set `isGenerating = true`, disable buttons, status `"Generating..." (status connecting)`.
- Create empty assistant div.
- `fetch(API_URL + "/v1/chat/completions", { method: "POST", ... })`
  - Headers: `Content-Type: application/json`, `x-api-key: apiKey`
  - Body:
    ```json
    {
      "model": "google/gemma-4-E2B-it",
      "messages": [
        { "role": "system", "content": SYSTEM_PROMPT },
        { "role": "user", "content": text }
      ],
      "temperature": 0.7,
      "max_tokens": 512,
      "stream": true
    }
    ```
  - **No conversation history** — every send is a fresh `[system, user]` pair.

- **Error branches:**
  - **401**: remove assistant div, show "Invalid API key. Refresh the page and try again.", `resetInput()`.
  - **503**: assistant text becomes "Warming up the GPU and loading the model. First request after idle can take 5–8 minutes. Please wait..." → calls `retryUntilReady(text, assistantDiv)`.
  - **Other non-OK**: remove div, show error with status/text, `resetInput()`.
  - **`TypeError: Failed to fetch`**: show "Cannot reach the API..." message.

- **SSE parsing loop:**
  - Read with `response.body.getReader()`; `TextDecoder().decode(value, { stream: true })`.
  - Split by `"\n"`. Skip lines not starting with `"data:"`. Strip the prefix. Skip `[DONE]`.
  - `JSON.parse` each data line.
  - If parsed has a `usage` field and no/empty `choices`, `console.log("vLLM usage:", parsed)` and continue.
  - Token text path: `parsed.choices?.[0]?.delta?.content`. If a non-empty string: append to `fullText`, set `assistantDiv.textContent = fullText`, scroll bottom.
  - JSON parse errors are silently skipped.
- If response was empty, set assistant text to `"(Empty response)"`.
- Call `resetInput()` at end.

### Function: `retryUntilReady(text, messageDiv)` (async)
- `maxAttempts = 40`, interval `15000 ms` → **10-minute ceiling**.
- Status pill: `"Warming up..." (status connecting)`.
- On each iteration: update progress text with `elapsedMin = Math.round(attempts * 0.25)`, wait 15 s, then `fetch(API_URL + "/health")`.
- On `response.ok`: remove `messageDiv`, restore the user's original text into `userInput`, clear `isGenerating`, re-enable inputs, call `sendMessage()` to re-send.
- Health-check `fetch` errors during polling are silently caught.
- On exhaust: show timeout error with attempt count, `resetInput()`.

### Function: `resetInput()`
- `isGenerating = false`, enable buttons, status pill `Connected`, focus textarea.

### Other facts
- No conversation history persisted (no localStorage, sessionStorage, cookies).
- No markdown rendering or code highlighting (uses `textContent`, relying on `white-space: pre-wrap` in CSS).
- No AbortController, no per-request timeout, no exponential backoff.
- Model hardcoded as `google/gemma-4-E2B-it`; temperature `0.7`, max_tokens `512`, `stream: true`.

---

## 16. Frontend — style.css

`frontend/style.css` (196 lines)

### Reset
```css
* { margin: 0; padding: 0; box-sizing: border-box; }
```

### Color palette

| Use | Value |
|---|---|
| Body background, disabled input bg | `#f5f5f5` |
| Chat container / header / input bar bg | `#ffffff` |
| API-key-bar bg | `#fafafa` |
| Assistant bubble bg | `#f0f0f0` |
| Border (header, key bar, input bar) | `#e0e0e0` |
| Border (inputs) | `#d0d0d0` |
| Heading / assistant text | `#1a1a1a` |
| Primary blue (button bg, focus border, user bubble) | `#2563eb` |
| Primary blue hover | `#1d4ed8` |
| Primary blue disabled | `#93c5fd` |
| Status red bg / text | `#fee2e2` / `#dc2626` |
| Status green bg / text | `#dcfce7` / `#16a34a` |
| Status yellow bg / text | `#fef3c7` / `#d97706` |

### Fonts
System stack: `-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif`.

### Layout
- Flexbox throughout (no grid, no CSS variables, no animations/transitions/keyframes, no dark mode).
- `.chat-container`: `max-width: 720px`, `height: 100vh`, flex column.
- `.messages`: flex column, gap 16 px, scrollable (`overflow-y: auto`).
- `.message`: `max-width: 85%`, padding 12/16, border-radius 12, font-size 15, line-height 1.5, `white-space: pre-wrap`, `word-wrap: break-word`.
- `.message.user`: aligned to flex-end, blue bg, white text, `border-bottom-right-radius: 4px`.
- `.message.assistant`: aligned to flex-start, gray bg, dark text, `border-bottom-left-radius: 4px`.
- `.message.error`: centered, red bg/text, `max-width: 90%`, font-size 13, `text-align: center`.
- `.status` pill: 13 px font, padding 4/12, border-radius 12. Class additions `.connected`/`.connecting` switch its color.
- `.api-key-bar.hidden`: `display: none`.
- Textarea: flex 1, padding 10/14, border-radius 8, max-height 120, `resize: none`. Focus border → `#2563eb`. Disabled bg → `#f5f5f5`.
- Send button: padding 10/24, border-radius 8, font-size 15, `align-self: flex-end`. Hover (non-disabled) → `#1d4ed8`. Disabled → `#93c5fd`, `cursor: not-allowed`.

### Media queries
One only:
```css
@media (max-width: 768px) {
  .chat-container { max-width: 100%; }
  .message       { max-width: 90%; }
}
```

---

## 17. Scripts — build_and_push.sh

`scripts/build_and_push.sh`

- Shebang: `#!/bin/bash`
- `set -e` (no `set -u`, no `pipefail`)
- Variables:
  - `REGION="${AWS_REGION:-eu-central-1}"`
  - `REPO_NAME="${ECR_REPO_NAME:-gemma-inference}"`
  - `ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`
  - `ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"`
- ECR login:
  ```bash
  aws ecr get-login-password --region ${REGION} | \
    docker login --username AWS --password-stdin ${ECR_URL}
  ```
- Docker build/push:
  - `docker build -t ${ECR_URL}/${REPO_NAME}:vllm  containers/vllm/`
  - `docker build -t ${ECR_URL}/${REPO_NAME}:nginx containers/nginx/`
  - `docker push ${ECR_URL}/${REPO_NAME}:vllm`
  - `docker push ${ECR_URL}/${REPO_NAME}:nginx`
- No argument parsing; no help text; relies on `set -e` for error handling.

---

## 18. Scripts — deploy.sh

`scripts/deploy.sh`

- Shebang: `#!/bin/bash`, `set -e`
- `cd "$(dirname "$0")/../terraform"`
- Commands:
  1. `terraform init`
  2. `terraform plan -out=tfplan`
  3. Prompt: `read -p "  Apply these changes? Type 'yes' to confirm: " confirm`
  4. If `confirm != "yes"`: `rm -f tfplan`, `exit 0`
  5. Else: `terraform apply tfplan`, `rm -f tfplan`
  6. Final `terraform output`
- No argument parsing.

---

## 19. Scripts — destroy.sh

`scripts/destroy.sh`

- Shebang: `#!/bin/bash`, `set -e`
- `cd "$(dirname "$0")/../terraform"`
- Banner + warning ("This will destroy ALL infrastructure...")
- Prompt: `read -p "  Are you sure? Type 'yes' to confirm: " confirm`
- If `confirm == "yes"`: `terraform destroy -auto-approve`
- Else prints `"Cancelled. Nothing was destroyed."`

---

## 20. Scripts — test_endpoint.py

`scripts/test_endpoint.py`

- Shebang: `#!/usr/bin/env python3`
- Imports: `sys`, `json`, `time`, `urllib.request`, `urllib.error`
- Argument parsing (positional, no argparse):
  - `sys.argv[1]` → `api_url` (required)
  - `sys.argv[2]` → `api_key` (required)
  - `sys.argv[3]` → `prompt` (optional, default `"What is cloud computing? Explain in 3 sentences."`)
  - On `len(sys.argv) < 3`: prints usage + example and `sys.exit(1)`.
- `test_endpoint(api_url, api_key, prompt)` calls **`{api_url}/generate_stream`** (note: this differs from the production OpenAI-compatible `/v1/chat/completions` path the frontend uses — this script targets the older HF-style streaming endpoint and would currently 404 against the deployed nginx config).
- POST body:
  ```json
  {
    "inputs": "<prompt>",
    "parameters": { "max_new_tokens": 256, "temperature": 0.7, "top_p": 0.9 }
  }
  ```
- Headers: `Content-Type: application/json`, `x-api-key: <api_key>`.
- `urlopen(req, timeout=300)`.
- SSE parsing: reads line-by-line, decodes UTF-8, strips `"data:"` prefix, stops on `[DONE]`, JSON-parses tokens, prints `parsed["token"]["text"]` with `flush=True`; silently skips `JSONDecodeError`.
- Counters: `token_count`, accumulated `full_text`.
- After stream: prints elapsed seconds (1 decimal), token count, tokens/sec (if both > 0).
- Errors:
  - `HTTPError 401` → "Invalid API key (401)", exit 1
  - `HTTPError 503` → "Service is starting up (503). Wait 3-5 minutes and retry.", exit 1
  - Other `HTTPError` → "HTTP {code} — {reason}", exit 1
  - `URLError` → "Cannot reach the API — {reason}", exit 1

---

## 21. Autoscaling Subsystem

Defined inside `terraform/modules/ecs/main.tf` and documented in `README.md:158-167`.

**Target (`aws_appautoscaling_target.ecs`):**
- Resource ID: `service/${cluster}/${service}`
- Scalable dimension: `ecs:service:DesiredCount`
- Min: `var.min_capacity` (default 0), Max: `var.max_capacity` (default 3)

**Three cooperating policies:**

| Policy | Type | Trigger | Effect | Cooldown |
|---|---|---|---|---|
| `scale_out_wake` | StepScaling (`ExactCapacity`) | `wake_on_503` alarm: ≥ 1 ALB 503 in 1 min | `0 → 1` | 60 s |
| `scale_out_load` | TargetTrackingScaling, `ALBRequestCountPerTarget` | request rate / target / min > **600** | `1 → up to max_capacity`; `disable_scale_in = true` | scale-in 0 s, scale-out 120 s |
| `scale_in_idle` | StepScaling (`ExactCapacity`) | `scale_in_on_idle` alarm: 15 consecutive minutes of zero requests | `N → 0` | 60 s |

**Alarms:**

`aws_cloudwatch_metric_alarm.wake_on_503`:
- Metric `AWS/ApplicationELB.HTTPCode_ELB_503_Count`, Sum, period 60 s, threshold ≥ 1, eval periods 1, missing data `notBreaching`, dim `LoadBalancer = var.alb_arn_suffix`. Action: `scale_out_wake`.

`aws_cloudwatch_metric_alarm.scale_in_on_idle`:
- Metric `RequestCount`, Sum, period 60 s, threshold < 1, eval periods 15, missing data **`breaching`** (silence counts as breach), dim `LoadBalancer`. Action: `scale_in_idle`.

**Design notes (`README.md:158-167`):**
- The wake policy uses `HTTPCode_ELB_503_Count` because per-target metrics aren't published when there are no targets.
- The load policy sets `disable_scale_in = true` so it cannot fight the idle policy; all scale-in is delegated to `scale_in_idle`.
- `max_capacity = 3` is architectural headroom; a single-user demo rarely hits it.
- `target_value = 600` is an educated estimate (~10 concurrent conversations per task), not benchmarked.

---

## 22. Security Model

**Two-tier API authentication:**
- **Client → nginx**: `x-api-key` header validated against `${PUBLIC_API_KEY}` via nginx `map` (constant-time hash compare).
- **nginx → vLLM**: nginx injects `Authorization: Bearer ${INTERNAL_API_KEY}`; vLLM verifies via its `--api-key` flag.
- The internal token never crosses the public boundary.

**Secrets handling:**
- Both keys live in SSM Parameter Store as **SecureString** parameters.
- ECS task execution role gets `ssm:GetParameters` on the specific ARNs.
- KMS decryption is scoped by condition `kms:ViaService = "ssm.${region}.amazonaws.com"` so a compromised execution role cannot become a generic KMS oracle.

**Network isolation:**
- ECS tasks run in private subnets; only the ALB security group can reach them on port 80.
- Outbound goes through the single NAT or the free S3 Gateway endpoint.

**Edge protections:**
- WAFv2 with AWS Managed Common Rule Set (OWASP-style) + 1000 req/IP/5 min rate limit.
- CloudFront uses SigV4 Origin Access Control to S3; the bucket policy grants `s3:GetObject` only to the `cloudfront.amazonaws.com` service principal when `AWS:SourceArn` matches the specific distribution.
- Public S3 access is fully blocked (`public_access_block` all four flags true).

**Image security:**
- ECR `scan_on_push = true`.
- Lifecycle policy keeps last 5 of each tag prefix.

**HTTPS:**
- Terminates at CloudFront only with default `*.cloudfront.net` cert.
- CloudFront → ALB is plain HTTP (origin protocol `http-only`).

---

## 23. Observability

**CloudWatch Log Groups (7-day retention):**
- `/ecs/${project_name}/vllm` → stream prefix `vllm`
- `/ecs/${project_name}/nginx` → stream prefix `nginx`

**Dashboard widgets:** 6 (CPU, memory, request count, p99 latency, 5XX errors, healthy target count) — see [§11](#11-terraform--monitoring-module).

**SNS alarms (3):** `high-latency` (p99 > 10 s), `high-errors` (5XX > 10/min), `no-healthy-targets` (< 1). All 3 evaluations × 1-min periods, both alarm and OK actions wired to the SNS topic.

**Silent autoscaling alarms (2):** `wake_on_503` and `scale_in_on_idle` — not subscribed to SNS to avoid alarm fatigue.

---

## 24. Cost Estimates

From `README.md:171-184`:

| Item | Idle | Active |
|---|---|---|
| NAT Gateway | ~$38/mo | + ~$0.05/GB |
| ALB | ~$16/mo | + LCU charges |
| WAFv2 (ACL + managed rule set + rule) | ~$6/mo | + $0.60 / million requests |
| CloudWatch (logs, dashboard, alarms) | ~$2/mo | + log ingestion |
| ECR (image storage ~18 GB) | ~$1.80/mo | — |
| `g6.xlarge` (NVIDIA L4 on-demand) | — | ~$0.95/hour |
| SSM Standard, S3 Gateway endpoint, SNS standard | $0 | — |
| **Total** | **~$65/mo** | **+ GPU runtime** |

Expected project cost for ~6 weeks with ~20 cumulative GPU-hours: **€80–110 total**.

---

## 25. .gitignore

`/.gitignore` patterns:

**Terraform:** `.terraform/`, `*.tfstate`, `*.tfstate.backup`, `*.tfstate.*.backup`, `terraform.tfvars`, `*.auto.tfvars`, `tfplan`.

**AWS credentials:** `*.pem`, `*.key`.

**OS:** `.DS_Store`, `Thumbs.db`.

**IDE:** `.vscode/`, `.idea/`, `*.swp`.

**Python:** `__pycache__/`, `*.pyc`, `.env`.

**Docker:** `*.tar`.

**Secrets / docs:** `secrets.yml`, `CLAUDE.md`.

> `CLAUDE.md` being gitignored is why this reference file is named `CODEBASE_REFERENCE.md` instead.

---

## 26. Limitations & Caveats

From `README.md:187-196`:

1. **Single-AZ NAT** — egress lost if AZ[0] fails; production HA would cost ~$76/mo instead of ~$38.
2. **Cold-start 5–8 min** — inherent to GPU scale-to-zero (ASG launch + 18 GB image pull + model load).
3. **State bucket name `gemma-inference-tfstate-ds` hardcoded** in the backend block — Terraform backends can't reference variables; reusing requires editing the file or `-backend-config` overrides.
4. **`scale_out_load` target of 600 req/target/min is an educated estimate**, not benchmarked.
5. **HTTPS only at CloudFront.** Origin protocol policy is `http-only`; default `*.cloudfront.net` cert; no ACM, no Route 53.
6. **Effective single-task ceiling in practice** — `max_capacity = 3` is configured but a single-user demo never hits load-based scale-out conditions.
7. **Repo name still `phi3-cloud-deployment`** even though the code now serves Gemma 4 — kept so historical clone URLs continue to resolve.

Additional observations from the code that aren't called out in the README:
- `scripts/test_endpoint.py` targets a legacy `/generate_stream` path with `inputs`/`parameters` body shape; the deployed nginx only proxies `/health` and `/v1/chat/completions`. The script is not consistent with the live deployment and would receive a 404 if used against the current backend.
- The `frontend` CloudFront cache behavior path pattern `/generate*` is a legacy artifact and does **not** match the actual chat path `/v1/chat/completions`.
- `app.js` injects `${alb_url}` as an empty string at templating time (see `terraform/modules/frontend/main.tf` `aws_s3_object.app_js`). Requests therefore go to relative URLs on the CloudFront domain.

---

## 27. Complete Resource Inventory

Approximate AWS resource count by category:

**Networking (~11):** 1 VPC, 4 subnets, 1 IGW, 2 route tables, 4 RT associations, 1 NAT Gateway, 1 EIP, 1 S3 Gateway endpoint, 2 security groups.

**Compute (~10):** 1 ECS cluster, 1 capacity provider, 1 cluster capacity providers association, 1 service, 1 task definition (2 containers), 1 launch template, 1 ASG, 1 app autoscaling target, 3 policies, 2 alarms (autoscaling-trigger).

**Container registry (2):** 1 ECR repository, 1 lifecycle policy.

**Load balancing (5):** 1 ALB, 1 target group, 1 listener, 1 WAF Web ACL, 1 WAF association.

**Frontend (8):** 1 S3 bucket, 1 public access block, 1 random_id, 1 OAC, 1 bucket policy, 3 S3 objects, 1 CloudFront distribution.

**Observability (7):** 1 dashboard, 1 SNS topic, 1 subscription, 3 alarms (notifying), 2 log groups (in ECS module).

**Secrets & IAM (~12):** 2 SSM SecureString parameters, 3 IAM roles (EC2 instance, ECS execution, ECS task), 1 instance profile, 4 role-policy attachments, 1 customer-managed policy + 1 attachment, 1 inline policy.

**Total: ~63 resources.**

---

## 28. External References

From `README.md:213-219`:

1. vLLM docs — https://docs.vllm.ai/
2. Gemma 4 E2B IT card — https://huggingface.co/google/gemma-4-E2B-it
3. ECS on EC2 — https://docs.aws.amazon.com/AmazonECS/latest/developerguide/
4. Terraform AWS provider — https://registry.terraform.io/providers/hashicorp/aws/latest/docs
5. CloudFront OAC — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
6. SSM SecureString — https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-securestring.html

---

## 29. Notable Absences in the Repository

- No Makefile (shell scripts only).
- No CI/CD configuration (no `.github/workflows/`, no `.gitlab-ci.yml`, no Jenkinsfile).
- No `.env.example` (uses `terraform.tfvars.example` instead).
- No unit test suite (only `test_endpoint.py`, which is also out of sync with the deployed API path).
- No `requirements.txt`, `package.json`, `Pipfile`, or `pyproject.toml` — dependencies live inside the containers.
- No local development setup (no `docker-compose.yml`, no devcontainer).
- No `CONTRIBUTING.md`, no issue templates, no PR templates.
- No `.editorconfig`, no `.dockerignore`, no pre-commit config.
- No README badges (build status, license, version).
