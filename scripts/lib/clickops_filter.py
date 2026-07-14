#!/usr/bin/env python3
"""Decide which CloudTrail write events were click-ops (ADR-046).

Reads `aws cloudtrail lookup-events` JSON on stdin, prints one markdown table row per
suspect event. Silent when everything was terragrunt or an AWS service.

The allowlist is the whole design, and it is only honest because of ADR-044: since
`watch-provisioner` replaced bootstrap-admin as the identity OpenTofu runs as, "changed
outside terragrunt" has a crisp definition — any write not made by the provisioner, the
pipeline's deploy roles, or an AWS service acting on its own. Before the fence, humans and
robots were the same identity (admin) and no filter could have told them apart.

Two things are deliberately NOT suppressed:

  * a write made with the ADMIN bootstrap credential. That is click-ops even when it is us —
    especially when it is us. It is the credential the whole estate is trying to stop needing.
  * a CONSOLE-originated write by an otherwise-allowed identity (`sessionCredentialFromConsole`).
    If somebody federates into the provisioner and starts clicking, the identity looks perfect
    and the change is still invisible to the repo.
"""
import json
import os
import re
import sys

PROJECT = os.environ.get("PROJECT", "watch")
LABEL = os.environ.get("LABEL", "?")

# Roles the ESTATE ITSELF minted: watch-provisioner (OpenTofu), gha-* (CI), and every runtime role
# terraform created for the workload — watch-build, watch-dast, watch-staging-exec,
# watch-staging-deploy-hook, watch-*-lambda… They write to AWS constantly (CreateLogStream, RunTask)
# and every one of them is declared in the repo and fenced by the ADR-044 boundary. Flagging them
# would drown the signal, and a report nobody reads is a report that does not exist.
#
# What is NOT here is the point: an IAM user, root, OrganizationAccountAccessRole, an SSO role — the
# HUMAN paths into this account. Those, plus any console session, are click-ops by definition.
ALLOWED = re.compile(
    r"^({p}-[a-z0-9-]+|gha-[a-z-]+|AWSServiceRole.*)$".format(p=re.escape(PROJECT))
)

# The admin roles a hub identity can assume into a member. Terragrunt CAN run through these (it did,
# before ADR-044, and still does for the one bootstrap apply that mints the provisioner) — so they
# are not "a human clicked", but they ARE "this write did not go through the fenced role", which is
# the thing we are trying to stop needing. Reported with their own reason.
ADMIN_ROLES = {"OrganizationAccountAccessRole", "AWSControlTowerExecution", "PlatformDeploy"}

# Events an AWS service raises on our behalf during a normal deploy — not a human.
SERVICE_INVOKED = re.compile(r"\.amazonaws\.com$|^AWS Internal$")


def suspect(event):
    """Return (who, why) if this write was not terragrunt/AWS, else None."""
    ui = event.get("userIdentity", {})
    itype = ui.get("type", "")

    # An AWS service acting on its own (ECS scaling a task, etc). Not a human.
    invoked_by = ui.get("invokedBy")
    if itype == "AWSService" or (invoked_by and SERVICE_INVOKED.search(invoked_by)):
        return None

    session = ui.get("sessionContext", {})
    issuer = session.get("sessionIssuer", {}).get("userName")
    who = issuer or ui.get("userName") or ui.get("arn", "?")

    # The console is worth flagging even for an allowed identity: the repo still cannot see it.
    from_console = str(event.get("sessionCredentialFromConsole", "")).lower() == "true"

    # A terragrunt run through an ADMIN role rather than the provisioner. Still not click-ops in
    # spirit — but it is the exact thing ADR-044 exists to retire, and it is invisible unless
    # someone says so. Distinguished from a stray human click, because the fix is different: this
    # one means "you ran make live with the wrong WATCH_MEMBER_ROLE_NAME".
    if issuer in ADMIN_ROLES:
        return who, "ADMIN role — a terragrunt run that bypassed the provisioner"
    if itype == "Root":
        return who, "root credential"
    if itype == "IAMUser":
        return who, "IAM user (long-lived key)"
    if issuer and ALLOWED.match(issuer):
        return (who, "CONSOLE session") if from_console else None
    return who, "console" if from_console else "not a terragrunt identity"


def main():
    try:
        events = json.load(sys.stdin).get("Events", [])
    except (json.JSONDecodeError, ValueError):
        return

    rows = []
    for ev in events:
        try:
            detail = json.loads(ev["CloudTrailEvent"])
        except (KeyError, json.JSONDecodeError):
            continue
        hit = suspect(detail)
        if not hit:
            continue
        who, why = hit
        resources = ", ".join(
            f"{r.get('ResourceType','').split('::')[-1]} {r.get('ResourceName','')}".strip()
            for r in (ev.get("Resources") or [])[:2]
        )
        rows.append(
            "| {when} | {acct} | `{who}` ({why}) | `{action}` | {res} |".format(
                when=detail.get("eventTime", "?"),
                acct=LABEL,
                who=who,
                why=why,
                action=ev.get("EventName", "?"),
                res=resources or "—",
            )
        )

    # Newest first, and cap it: a report nobody reads is a report that does not exist.
    for row in rows[:40]:
        print(row)
    if len(rows) > 40:
        print(f"| … | {LABEL} | | _{len(rows) - 40} more suppressed_ | |")


if __name__ == "__main__":
    main()
