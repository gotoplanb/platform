"""CodeDeploy ECS BeforeAllowTraffic hook (platform#12, ADR §4.6/§4.9).

Runs the database migration against the GREEN task definition's image BEFORE production
traffic shifts, as a one-off Fargate task. Migrations are the **expand** phase only —
additive and backward-compatible, so the still-live blue tasks keep working (the
**contract** phase is a separate, later release once the new code is fully rolled out and
SLOs are unchanged). If migrate exits non-zero the hook reports Failed and CodeDeploy
auto-rolls back before any traffic moves.

Env (from the pipeline module): CLUSTER, TASK_FAMILY, SUBNETS, SECURITY_GROUPS,
CONTAINER_NAME.
"""
import os
import time

import boto3

ecs = boto3.client("ecs")
codedeploy = boto3.client("codedeploy")


def _run_migrate():
    """Run `manage.py migrate` on the latest (green) task def; return True on exit 0."""
    task = ecs.run_task(
        cluster=os.environ["CLUSTER"],
        taskDefinition=os.environ["TASK_FAMILY"],  # latest ACTIVE = the green revision
        launchType="FARGATE",
        count=1,
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": os.environ["SUBNETS"].split(","),
                "securityGroups": os.environ["SECURITY_GROUPS"].split(","),
                "assignPublicIp": "DISABLED",
            }
        },
        overrides={
            "containerOverrides": [
                {"name": os.environ["CONTAINER_NAME"],
                 "command": ["python", "manage.py", "migrate", "--noinput"]}
            ]
        },
    )
    arn = task["tasks"][0]["taskArn"]

    waiter = ecs.get_waiter("tasks_stopped")
    waiter.wait(cluster=os.environ["CLUSTER"], tasks=[arn],
                WaiterConfig={"Delay": 10, "MaxAttempts": 50})  # up to ~8 min

    desc = ecs.describe_tasks(cluster=os.environ["CLUSTER"], tasks=[arn])["tasks"][0]
    app = next(c for c in desc["containers"] if c["name"] == os.environ["CONTAINER_NAME"])
    return app.get("exitCode") == 0


def handler(event, context=None):
    try:
        ok = _run_migrate()
        status = "Succeeded" if ok else "Failed"
    except Exception:
        status = "Failed"

    codedeploy.put_lifecycle_event_hook_execution_status(
        deploymentId=event["DeploymentId"],
        lifecycleEventHookExecutionId=event["LifecycleEventHookExecutionId"],
        status=status,
    )
    return {"status": status}
