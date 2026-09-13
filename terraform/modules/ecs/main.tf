// Look up the latest ECS-optimised GPU AMI
data "aws_ssm_parameter" "ecs_gpu_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/gpu/recommended"
}

locals {
  ecs_gpu_ami_id = jsondecode(data.aws_ssm_parameter.ecs_gpu_ami.value)["image_id"]
}


// SSM SecureString parameters
resource "aws_ssm_parameter" "public_api_key" {
  name        = "/${var.project_name}/public-api-key"
  description = "User-facing API key validated by the proxy (x-api-key header)."
  type        = "SecureString"
  value       = var.public_api_key

  tags = {
    project = var.project_name
  }
}

resource "aws_ssm_parameter" "internal_api_key" {
  name        = "/${var.project_name}/internal-api-key"
  description = "Internal token shared between the proxy and vLLM (Bearer header)."
  type        = "SecureString"
  value       = var.internal_api_key

  tags = {
    project = var.project_name
  }
}

// Role 1: EC2 Instance Role — allows ECS agent to register with cluster
resource "aws_iam_role" "ec2_instance" {
  name = "${var.project_name}-ec2-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ec2-instance-role"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_ecs" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ec2_ecr" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_instance" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance.name
}

// Role 2: ECS Task Execution Role — allows ECS to pull images and write logs
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ecs-task-execution-role"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_task_execution_ssm" {
  name = "${var.project_name}-ecs-task-execution-ssm"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAPIKeyParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameters"]
        Resource = [
          aws_ssm_parameter.public_api_key.arn,
          aws_ssm_parameter.internal_api_key.arn,
        ]
      },
      {
        Sid      = "DecryptSSMSecureStrings"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

// Role 3: ECS Task Role — permissions for the running containers
resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ecs-task-role"
  }
}

resource "aws_iam_policy" "ecs_task_logs" {
  name = "${var.project_name}-ecs-task-logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.vllm.arn}:*",
          "${aws_cloudwatch_log_group.proxy.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_cloudwatch" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task_logs.arn
}

// LAUNCH TEMPLATE
resource "aws_launch_template" "ecs" {
  name          = "${var.project_name}-launch-template"
  image_id      = local.ecs_gpu_ami_id
  instance_type = var.instance_type

  vpc_security_group_ids = [var.ecs_security_group_id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2_instance.arn
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" >> /etc/ecs/ecs.config
    echo "ECS_ENABLE_GPU_SUPPORT=true" >> /etc/ecs/ecs.config
  EOF
  )

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true

      // The root volume holds the unpacked ~18 GB vLLM image, model weights included.
      // Uses the AWS-managed alias/aws/ebs key, so no KMS resource and no extra cost.
      encrypted = true
    }
  }

  monitoring {
    enabled = true
  }

  // Require IMDSv2. The instance profile carries the ECS agent's credentials, so with
  // IMDSv1 still reachable any request-forgery bug on the box can read them with a
  // plain GET. The hop limit is 2 rather than the stricter 1 because the ECS agent
  // reaches the metadata service across a container network hop.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.project_name}-ecs-instance"
    }
  }

  tags = {
    Name = "${var.project_name}-launch-template"
  }
}


// AUTO SCALING GROUP
resource "aws_autoscaling_group" "ecs" {
  name                = "${var.project_name}-asg"
  vpc_zone_identifier = var.private_subnet_ids
  min_size            = 0

  // Deliberately the task ceiling, not the GPU quota: one task requests one whole GPU
  // and a g6.xlarge has one, so the two ceilings are the same number by construction.
  //
  // Known transient: waking from zero can briefly launch two instances for one task.
  // ECS publishes CapacityProviderReservation as a flat 200 whenever the group is empty
  // and a task needs placing — it cannot form a ratio against zero — and 200 is twice
  // target_capacity, so target tracking doubles from nothing. The spare carries no task
  // and ECS drains it once managed termination protection lifts. Clamping max_size to 1
  // would remove the transient at the cost of making scale-out unreachable; on an
  // account whose G-instance quota is 4 vCPU the third instance simply fails to launch.
  max_size         = var.max_capacity
  desired_capacity = 0

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  protect_from_scale_in = true

  // Without this the group publishes no metrics, so nothing in CloudWatch records how
  // many GPU instances exist — the dashboard's HealthyHostCount counts ALB targets, and
  // an instance whose task is still pulling the image is not one. Free, and it is what
  // makes an over-provisioned group visible instead of something to reconstruct from
  // the scaling-activity log after the fact.
  metrics_granularity = "1Minute"
  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
  ]

  tag {
    key                 = "Name"
    value               = "${var.project_name}-ecs-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}


// ECS CLUSTER
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  tags = {
    Name = "${var.project_name}-cluster"
  }
}


// CAPACITY PROVIDER
resource "aws_ecs_capacity_provider" "main" {
  name = "${var.project_name}-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      maximum_scaling_step_size = 1
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100

      // Without this the field defaults to 0, and ECS re-evaluates capacity the moment
      // after it launches an instance — before that instance has booted, joined the
      // cluster and had its GPU counted. It therefore sees the same unmet demand twice
      // and scales again: an observed cold start went 0 -> 2 instances at 14:26:50 and
      // 2 -> 3 at 14:27:50, 45 seconds later, for a single pending task. A g6.xlarge
      // needs several minutes to register, so hold the next evaluation until then.
      instance_warmup_period = 300
    }
  }

  tags = {
    Name = "${var.project_name}-capacity-provider"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 0
  }
}


// CLOUDWATCH LOG GROUPS
resource "aws_cloudwatch_log_group" "vllm" {
  name              = "/ecs/${var.project_name}/vllm"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-vllm-logs"
  }
}

resource "aws_cloudwatch_log_group" "proxy" {
  name              = "/ecs/${var.project_name}/proxy"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-proxy-logs"
  }
}


// TASK DEFINITION
resource "aws_ecs_task_definition" "main" {
  family                   = var.project_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "vllm"
      image     = "${var.ecr_repository_url}:vllm"
      essential = true

      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]

      // vLLM gets its arguments from the Dockerfile CMD; no command override here.

      resourceRequirements = [
        {
          type  = "GPU"
          value = "1"
        }
      ]

      memory = 14336
      cpu    = 3072

      // API keys come from SSM SecureString — see secrets[] below.
      environment = []

      secrets = [
        {
          name      = "INTERNAL_API_KEY"
          valueFrom = aws_ssm_parameter.internal_api_key.arn
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 5
        startPeriod = 120
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.vllm.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "vllm"
        }
      }
    },
    {
      name      = "proxy"
      image     = "${var.ecr_repository_url}:proxy"
      essential = true

      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]

      memory = 256
      cpu    = 256

      // API keys come from SSM SecureString — see secrets[] below.
      environment = []

      secrets = [
        {
          name      = "PUBLIC_API_KEY"
          valueFrom = aws_ssm_parameter.public_api_key.arn
        },
        {
          name      = "INTERNAL_API_KEY"
          valueFrom = aws_ssm_parameter.internal_api_key.arn
        }
      ]

      dependsOn = [
        {
          containerName = "vllm"
          condition     = "HEALTHY"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.proxy.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "proxy"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-task-definition"
  }
}


// ECS SERVICE
resource "aws_ecs_service" "main" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = 0

  // The task definition pins the mutable :vllm and :proxy tags, so re-pushing an image
  // changes nothing Terraform can see, and updating an SSM secret leaves its ARN — and
  // therefore the task definition — identical too. Either way a warm service would keep
  // serving the old image and the old key.
  //
  // force_new_deployment on its own does not fix that: it only takes effect when
  // Terraform has some other reason to update the resource, and with no diff there is
  // no UpdateService call at all. The trigger below is what actually creates the diff,
  // following HashiCorp's documented pattern for this exact case.
  //
  // The cost is that the ECS service now shows a change in every plan. That is the
  // intended trade: the rollout is a no-op while the service sits at zero tasks, which
  // is the normal idle state, and when it is warm the rollout is the whole point.
  force_new_deployment = true

  triggers = {
    redeployment = plantimestamp()
  }

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 0
  }

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.ecs_security_group_id]
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "proxy"
    container_port   = 80
  }

  health_check_grace_period_seconds = 300

  // A task reserves a whole GPU and a g6.xlarge has exactly one, so two tasks can never
  // share an instance. At 200 percent ECS is allowed to start the replacement task before
  // stopping the old one during a rollout, which it can only do on a SECOND GPU instance —
  // and because force_new_deployment above makes every terraform apply a rollout, a warm
  // service asked the capacity provider for an extra g6.xlarge on every single apply.
  // 100 percent stops the old task first, which is the only order the hardware allows.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [aws_ecs_cluster_capacity_providers.main]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = {
    Name = "${var.project_name}-service"
  }
}


/*
 Scale-from-zero autoscaling — three cooperating policies

   - scale_out_wake  (step):          0 → 1 on first ALB 503 (no targets)
   - scale_out_load  (target track):  1 → N as ALB request rate per target rises
   - scale_in_idle   (step):          N → 0 after 15 min of ALB silence

*/

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

// Scale OUT: ALB emits HTTPCode_ELB_503_Count when it has no healthy targets.
resource "aws_appautoscaling_policy" "scale_out_wake" {
  name               = "${var.project_name}-scale-out-wake"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension

  step_scaling_policy_configuration {
    // ChangeInCapacity, not ExactCapacity: this policy must be a floor, never an
    // absolute. A 503 is also what an overloaded or health-flapping fleet emits, and
    // "set capacity to exactly 1" would answer that by stopping every task but one —
    // scaling in during a spike. +1 can only add, and max_capacity still caps it.
    adjustment_type = "ChangeInCapacity"
    cooldown        = 60

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

// A 503 alone is not the signal this policy wants. The service emits 503s for the
// whole cold start, and the browser's own /health poll (every 15 s, so four requests
// a minute) keeps producing them for the ~18 minutes the model takes to load. Each
// time the alarm re-entered ALARM it added another task: an observed cold start went
// to desired_count 2 for one user sending one message, and the second task pulled the
// ~18 GB image onto a second GPU instance that was never needed.
//
// The condition the policy actually means is "there is no capacity at all", which is
// a 503 AND no healthy target. HealthyHostCount cannot be used on its own: the ALB
// publishes nothing for it while the target group is empty — verified over a real
// 22-minute zero-target window, where the metric had a single datapoint, at the
// moment the first task registered. That is the same missing-metric trap that made
// CPU target tracking unusable here. FILL(m2,0) supplies the zero the ALB does not,
// and FILL(m1,0) does the same for the 503 count, which is only reported when nonzero.
//
// Replayed against the incident above, this expression reads 1 from 16:21 to 16:40
// and 0 from 16:41, the minute the first task became healthy — so the 16:43 scale-out
// that created the second task would not have fired.
resource "aws_cloudwatch_metric_alarm" "wake_on_503" {
  alarm_name          = "${var.project_name}-wake-on-503"
  alarm_description   = "No healthy target and the ALB is answering 503: the service is at zero and cannot serve."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    expression  = "IF(FILL(m2,0) < 1, 1, 0) * IF(FILL(m1,0) >= 1, 1, 0)"
    label       = "no-capacity-at-all"
    return_data = true
  }

  metric_query {
    id          = "m1"
    return_data = false

    metric {
      metric_name = "HTTPCode_ELB_503_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  metric_query {
    id          = "m2"
    return_data = false

    metric {
      metric_name = "HealthyHostCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Maximum"

      dimensions = {
        TargetGroup  = var.target_group_arn_suffix
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  alarm_actions = [aws_appautoscaling_policy.scale_out_wake.arn]
}

// Scale OUT (load): target-tracking on ALB request rate; scales 1 → N as concurrency rises.
resource "aws_appautoscaling_policy" "scale_out_load" {
  name               = "${var.project_name}-scale-out-load"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 600
    scale_in_cooldown  = 0
    scale_out_cooldown = 120
    disable_scale_in   = true

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${var.target_group_arn_suffix}"
    }
  }
}

// Scale IN: 15 consecutive minutes of zero ALB requests returns to 0 tasks.
resource "aws_appautoscaling_policy" "scale_in_idle" {
  name               = "${var.project_name}-scale-in-idle"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type = "ExactCapacity"
    cooldown        = 60

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_in_on_idle" {
  alarm_name          = "${var.project_name}-scale-in-on-idle"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 15
  metric_name         = "RequestCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_appautoscaling_policy.scale_in_idle.arn]
}