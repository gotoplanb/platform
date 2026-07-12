# member-access — hub-assumable role for a member account

**When you need this (existing-org topology, platform#50):** accounts *created* by an AWS
Organization get `OrganizationAccountAccessRole` automatically — if that's you, skip this
module entirely. Accounts *invited* into an org, or vended by a landing zone with different
conventions, may have **no role the hub account can assume**. This mints one.

Like [`../bootstrap`](../bootstrap), it's standalone with **local state**, applied **once per
member account with that member's own credentials** — chicken-and-egg: the hub can't assume
in until this role exists.

## Apply (once per member)

```bash
export AWS_PROFILE=<member-account-admin>   # the MEMBER's credentials, not the hub's
cd member-access
tofu init
tofu apply -var hub_account_id=<your hub/management account id>
```

For the second member, keep the local state files separate with a workspace per member
(verified pattern):

```bash
tofu workspace new nonprod && tofu apply -var hub_account_id=…   # with nonprod's creds
tofu workspace new prod    && tofu apply -var hub_account_id=…   # with prod's creds
```

Then fill `WATCH_NONPROD_ACCOUNT_ID` / `WATCH_PROD_ACCOUNT_ID` in `.env` and everything
else works exactly like the org-created topology. Verify with `make topology-check`.

## Role name

The default name matches the `OrganizationAccountAccessRole` convention so the root
terragrunt needs no override. If your org reserves that name (Control Tower shops often do),
mint a custom one and point the repo at it:

```bash
tofu apply -var hub_account_id=… -var role_name=PlatformDeploy
# then, in .env:
WATCH_MEMBER_ROLE_NAME=PlatformDeploy
```

`WATCH_MEMBER_ROLE_NAME` is honored by the root terragrunt (provider assume-role) **and** the
lifecycle scripts' raw-CLI steps (`scripts/lib/xacct.sh`).

## Trust & scope

Trust is the account-root principal of the hub (`arn:aws:iam::<hub>:root`) — the same shape
`OrganizationAccountAccessRole` uses: any hub identity whose own IAM policy allows
`sts:AssumeRole` on this ARN. The attached policy defaults to `AdministratorAccess` because
this **is** the apply path; scope it down with `-var policy_arn=…` if your org requires, but
every stack this repo applies must fit whatever you attach.
