"""CodeDeploy ECS lifecycle hook (BeforeAllowTraffic / AfterAllowTraffic), platform#10.

BeforeAllowTraffic is where the expand->contract migration runs + a smoke check against
the green task set BEFORE production traffic shifts (ADR §4.6 / #12); AfterAllowTraffic is
a post-shift confirmation. This placeholder reports Succeeded so blue/green deploys
complete end to end; the real migration + smoke logic (VPC + RDS access) is wired with the
expand->contract runbook (#12). It must report status or CodeDeploy stalls then times out.
"""
import boto3


def handler(event, context=None):
    deployment_id = event["DeploymentId"]
    hook_execution_id = event["LifecycleEventHookExecutionId"]

    # TODO(#12): run `manage.py migrate` (expand phase) + smoke the green task set here,
    # reporting Failed on error so CodeDeploy auto-rolls back. Placeholder = pass.
    status = "Succeeded"

    boto3.client("codedeploy").put_lifecycle_event_hook_execution_status(
        deploymentId=deployment_id,
        lifecycleEventHookExecutionId=hook_execution_id,
        status=status,
    )
    return {"status": status}
