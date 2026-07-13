# Async job queue + worker (ADR-025). The SQS queue drains two kinds of work — Session Check
# (ADR-022) and outbound webhook delivery (ADR-023) — via `manage.py run_sqs_worker` running the
# SAME image as the app (build-once/promote-by-digest), a different command. All gated on
# enable_worker so prod (default false) is untouched: no queue, no worker, no new IAM.

# ---- Queue + DLQ (mirrors the intake pattern) -------------------------------

resource "aws_sqs_queue" "jobs_dlq" {
  count                     = var.enable_worker ? 1 : 0
  name                      = "${var.name}-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
  tags                      = merge(var.tags, { Name = "${var.name}-jobs-dlq" })
}

resource "aws_sqs_queue" "jobs" {
  count                      = var.enable_worker ? 1 : 0
  name                       = "${var.name}-jobs"
  visibility_timeout_seconds = 90     # >= the worker's per-job budget (WORKER_VISIBILITY_SECONDS)
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq[0].arn
    maxReceiveCount     = 5
  })
  tags = merge(var.tags, { Name = "${var.name}-jobs" })
}

# ---- IAM: split least-privilege (app produces, worker consumes) --------------

# App task role: SendMessage only (enqueue on write).
resource "aws_iam_role_policy" "task_sqs_send" {
  count = var.enable_worker ? 1 : 0
  name  = "${var.name}-sqs-send"
  role  = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.jobs[0].arn
    }]
  })
}

# Worker task role: receive/delete/attrs to drain, plus SendMessage (a completed check emits
# check.completed, which itself enqueues a delivery — ADR-023). Reads flags via AppConfig.
resource "aws_iam_role" "worker_task" {
  count                = var.enable_worker ? 1 : 0
  name                 = "${var.name}-worker-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "worker_appconfig" {
  count      = var.enable_worker ? 1 : 0
  role       = aws_iam_role.worker_task[0].name
  policy_arn = var.appconfig_read_policy_arn
}

resource "aws_iam_role_policy" "worker_sqs" {
  count = var.enable_worker ? 1 : 0
  name  = "${var.name}-sqs-consume"
  role  = aws_iam_role.worker_task[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:SendMessage",
      ]
      Resource = aws_sqs_queue.jobs[0].arn
    }]
  })
}

# ---- Worker task definition + service (no ALB, ECS rolling) ------------------

locals {
  # Same three containers as the app, but the app container runs the worker command and needs no
  # ingress port. merge-a-lookup (not a ?: — whose branches would be inconsistent object types):
  # the app container merges in the command+empty ports; the sidecars merge an empty map (no-op).
  worker_overrides = {
    (local.container_name) = { command = ["python", "manage.py", "run_sqs_worker"], portMappings = [] }
  }
  worker_container_definitions = [
    for c in local.container_definitions : merge(c, lookup(local.worker_overrides, c.name, {}))
  ]
}

resource "aws_ecs_task_definition" "worker" {
  count                    = var.enable_worker ? 1 : 0
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.worker_task[0].arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode(local.worker_container_definitions)
  tags                  = merge(var.tags, { Name = "${var.name}-worker" })
}

resource "aws_ecs_service" "worker" {
  count           = var.enable_worker ? 1 : 0
  name            = "${var.name}-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker[0].arn
  desired_count   = var.worker_desired_count
  launch_type     = "FARGATE"

  # Long-poller, not behind an LB — plain ECS rolling deploys (no CodeDeploy, no target group).
  network_configuration {
    subnets          = local.service_subnets
    security_groups  = [var.app_sg_id]
    assign_public_ip = local.assign_public_ip
  }

  tags = merge(var.tags, { Name = "${var.name}-worker" })
}
