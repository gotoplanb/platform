# bootstrap — Terraform state backend

The chicken-and-egg foundation (platform#1): creates the **S3 state bucket**
(`watch-tfstate-<account-id>`, versioned, SSE-S3, public-access-blocked, TLS-only,
noncurrent-version expiry) + the **DynamoDB lock table** (`watch-tflocks`, on-demand)
that every other stack's remote state depends on.

Standalone module with **local state** (it can't use the S3 backend it's creating).
Apply it **once**, before anything else.

## Apply (one-time)
```bash
export AWS_PROFILE=watch-bootstrap          # the temporary write credential
cd bootstrap
tofu init
tofu apply
```
Outputs the bucket + table names. After this, all stacks use the S3 backend wired in
the root `terragrunt.hcl` (no per-stack backend config needed).

State note: this module's own state stays **local** (`bootstrap/terraform.tfstate`,
gitignored) — fine for a rarely-changing bootstrap. Optionally migrate it into the new
bucket afterward with a `backend "s3"` block + `tofu init -migrate-state`.

Verify (read-only) anytime:
```bash
AWS_PROFILE=watch-ro aws s3 ls | grep watch-tfstate
AWS_PROFILE=watch-ro aws dynamodb describe-table --table-name watch-tflocks --query 'Table.TableStatus'
```
