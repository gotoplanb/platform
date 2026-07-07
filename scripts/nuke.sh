#!/usr/bin/env bash
# Force-clean ALL billable watch-* resources in a member account (#45). This is the reviewed,
# dependency-ordered consolidation of the one-off cleanup scripts that were hand-written during the
# 2026-07-07 partial-apply mess — kept in-tree so the next "teardown left orphans" incident is a
# single audited command instead of improvised AWS-CLI under pressure.
#
# WHEN to use: teardown/doctor reports orphans that `terragrunt destroy` can't remove (partial applies
# with no state, or state-vs-reality drift). NORMAL teardown is scripts/teardown.sh — use THAT first.
# This bypasses terraform entirely and deletes by name/prefix, so state is left stale afterwards
# (a following create.sh reconciles, or teardown clears the now-empty stacks).
#
# PERSIST — never touched (by construction: these classes are not enumerated below):
#   • tf-state backend  : watch-tfstate-*  bucket + watch-tflocks  DynamoDB table
#   • ECR repo          : watch  (+ :bootstrap image)          — foundation, slow/expensive to rebuild
#   • ACM certificates  : *.<domain>                            — free, slow to revalidate
#   • IAM roles         : watch-ci-*, watch-prod-deploy         — cross-account pipeline identities
#   • org/account/github: budgets, OIDC providers, repo config  — foundation
# Everything else with a watch prefix/tag (ECS, RDS, ElastiCache, ALB/TG, NAT, EIP, Lambda, SQS,
# AppConfig, SSM params, KMS aliases, VPC + deps) is deleted.
#
# Usage:
#   scripts/nuke.sh nonprod          # staging + foundation share the nonprod account
#   scripts/nuke.sh prod
#   scripts/nuke.sh both
#   scripts/nuke.sh prod -y          # skip the typed-confirmation (automation)
# Env: AWS_PROFILE (default watch-bootstrap — needs AssumeRole into members), AWS_REGION.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
. "$ROOT/scripts/lib/xacct.sh"
. "$ROOT/scripts/lib/preflight.sh"

TARGET="${1:-}"; [ $# -gt 0 ] && shift
ASSUME_YES=0
for a in "$@"; do case "$a" in -y|--yes) ASSUME_YES=1 ;; *) echo "unknown flag: $a" >&2; exit 2 ;; esac; done

case "$TARGET" in
  nonprod|staging) PAIRS=("nonprod:$(xacct_account_for staging)") ;;
  prod)            PAIRS=("prod:$(xacct_account_for prod)") ;;
  both)            PAIRS=("nonprod:$(xacct_account_for staging)" "prod:$(xacct_account_for prod)") ;;
  *) echo "usage: nuke.sh [nonprod|prod|both] [-y]" >&2; exit 2 ;;
esac

# Fail-fast: bad identity / missing member ids means we'd assume nothing and "succeed" as a no-op, OR
# (worse) run destructive calls in the wrong account. Preflight before we touch anything.
preflight nuke

q() { aws "$@" 2>/dev/null; }

# nuke_account <label> — destructive; assumes creds for the account are ALREADY exported (subshell).
# Order matters: services -> load balancers/lambda -> stateful (cache/RDS) -> wait -> subnet groups ->
# EIP -> config (kms/ssm/appconfig/sqs) -> VPC last (after its ENIs drain). Idempotent: gone == no-op.
nuke_account() {
  local label="$1"
  echo "==================== NUKE $label ($(aws sts get-caller-identity --query Account --output text)) ===================="

  # 1. ECS services (scale to 0 + force-delete) then clusters
  for cl in $(q ecs list-clusters --query 'clusterArns' --output text | tr '\t' '\n' | grep -i watch); do
    for s in $(q ecs list-services --cluster "$cl" --query 'serviceArns' --output text | tr '\t' '\n'); do
      q ecs update-service --cluster "$cl" --service "$s" --desired-count 0 >/dev/null
      q ecs delete-service --cluster "$cl" --service "$s" --force >/dev/null && echo "  ecs svc: ${s##*/}"
    done
    q ecs delete-cluster --cluster "$cl" >/dev/null && echo "  ecs cluster: ${cl##*/}"
  done
  # 2. ALBs + target groups
  for lb in $(q elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName,`watch`)].LoadBalancerArn' --output text | tr '\t' '\n'); do
    q elbv2 delete-load-balancer --load-balancer-arn "$lb" >/dev/null && echo "  alb: ${lb##*/}"; done
  for tg in $(q elbv2 describe-target-groups --query 'TargetGroups[?contains(TargetGroupName,`watch`)].TargetGroupArn' --output text | tr '\t' '\n'); do
    q elbv2 delete-target-group --target-group-arn "$tg" >/dev/null; done
  # 3. Lambda
  for fn in $(q lambda list-functions --query 'Functions[?contains(FunctionName,`watch`)].FunctionName' --output text | tr '\t' '\n'); do
    q lambda delete-function --function-name "$fn" >/dev/null && echo "  lambda: $fn"; done
  # 4. ElastiCache (replication groups + standalone)
  for rg in $(q elasticache describe-replication-groups --query 'ReplicationGroups[?contains(ReplicationGroupId,`watch`)].ReplicationGroupId' --output text | tr '\t' '\n'); do
    q elasticache delete-replication-group --replication-group-id "$rg" --no-retain-primary-cluster >/dev/null && echo "  cache RG: $rg"; done
  for cc in $(q elasticache describe-cache-clusters --query 'CacheClusters[?contains(CacheClusterId,`watch`)].CacheClusterId' --output text | tr '\t' '\n'); do
    q elasticache delete-cache-cluster --cache-cluster-id "$cc" >/dev/null && echo "  cache: $cc"; done
  # 5. RDS (clear deletion protection first)
  for db in $(q rds describe-db-instances --query 'DBInstances[?contains(DBInstanceIdentifier,`watch`)].DBInstanceIdentifier' --output text | tr '\t' '\n'); do
    q rds modify-db-instance --db-instance-identifier "$db" --no-deletion-protection --apply-immediately >/dev/null
    q rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups >/dev/null && echo "  rds: $db"; done
  # 6. NAT gateways
  for nat in $(q ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text | tr '\t' '\n'); do
    q ec2 delete-nat-gateway --nat-gateway-id "$nat" >/dev/null && echo "  nat: $nat"; done
  # 7. wait for RDS/cache/NAT to drain (they pin subnet groups + hold ENIs in the VPC)
  echo "  waiting for RDS/cache/NAT deletion..."
  for _ in $(seq 1 90); do
    left="$(q rds describe-db-instances --query 'DBInstances[?contains(DBInstanceIdentifier,`watch`)].DBInstanceIdentifier' --output text)$(q elasticache describe-cache-clusters --query 'CacheClusters[?contains(CacheClusterId,`watch`)].CacheClusterId' --output text)$(q ec2 describe-nat-gateways --filter Name=state,Values=available,pending,deleting --query 'NatGateways[].NatGatewayId' --output text)"
    [ -z "$left" ] && { echo "  RDS/cache/NAT gone"; break; }; sleep 10; done
  # 8. subnet groups (now unpinned)
  for sg in $(q rds describe-db-subnet-groups --query 'DBSubnetGroups[?contains(DBSubnetGroupName,`watch`)].DBSubnetGroupName' --output text | tr '\t' '\n'); do
    q rds delete-db-subnet-group --db-subnet-group-name "$sg" >/dev/null && echo "  rds subnetgrp: $sg"; done
  for sg in $(q elasticache describe-cache-subnet-groups --query 'CacheSubnetGroups[?contains(CacheSubnetGroupName,`watch`)].CacheSubnetGroupName' --output text | tr '\t' '\n'); do
    q elasticache delete-cache-subnet-group --cache-subnet-group-name "$sg" >/dev/null && echo "  cache subnetgrp: $sg"; done
  # 9. release dangling EIPs
  for al in $(q ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].AllocationId' --output text | tr '\t' '\n'); do q ec2 release-address --allocation-id "$al" >/dev/null; done
  # 10-13. KMS aliases / SSM params / AppConfig / SQS (config-plane; recreated by apply)
  for al in $(q kms list-aliases --query 'Aliases[?contains(AliasName,`watch`)].AliasName' --output text | tr '\t' '\n'); do q kms delete-alias --alias-name "$al" >/dev/null && echo "  kms alias: $al"; done
  for p in $(q ssm describe-parameters --query 'Parameters[].Name' --output text | tr '\t' '\n' | grep watch); do q ssm delete-parameter --name "$p" >/dev/null; done; echo "  ssm params cleared"
  for app in $(q appconfig list-applications --query 'Items[?contains(Name,`watch`)].Id' --output text | tr '\t' '\n'); do
    for e in $(q appconfig list-environments --application-id "$app" --query 'Items[].Id' --output text | tr '\t' '\n'); do q appconfig delete-environment --application-id "$app" --environment-id "$e" >/dev/null; done
    for pr in $(q appconfig list-configuration-profiles --application-id "$app" --query 'Items[].Id' --output text | tr '\t' '\n'); do
      for v in $(q appconfig list-hosted-configuration-versions --application-id "$app" --configuration-profile-id "$pr" --query 'Items[].VersionNumber' --output text | tr '\t' '\n'); do q appconfig delete-hosted-configuration-version --application-id "$app" --configuration-profile-id "$pr" --version-number "$v" >/dev/null; done
      q appconfig delete-configuration-profile --application-id "$app" --configuration-profile-id "$pr" >/dev/null; done
    q appconfig delete-application --application-id "$app" >/dev/null && echo "  appconfig: $app"; done
  for u in $(q sqs list-queues --queue-name-prefix watch --query 'QueueUrls' --output text | tr '\t' '\n'); do q sqs delete-queue --queue-url "$u" >/dev/null; done; echo "  sqs cleared"
  # 14. VPCs last — drain ENIs, then delete deps (endpoints, SGs, subnets, RTs, IGW) then the VPC.
  for vpc in $(q ec2 describe-vpcs --filters Name=tag:Name,Values='watch-*' --query 'Vpcs[].VpcId' --output text | tr '\t' '\n'); do
    echo "  VPC $vpc: waiting for ENIs to release..."
    for _ in $(seq 1 60); do
      n=$(q ec2 describe-network-interfaces --filters Name=vpc-id,Values="$vpc" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text | wc -w)
      [ "$n" -eq 0 ] && break
      for eni in $(q ec2 describe-network-interfaces --filters Name=vpc-id,Values="$vpc" Name=status,Values=available --query 'NetworkInterfaces[].NetworkInterfaceId' --output text | tr '\t' '\n'); do q ec2 delete-network-interface --network-interface-id "$eni" >/dev/null; done
      sleep 10; done
    eps=$(q ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$vpc" --query 'VpcEndpoints[].VpcEndpointId' --output text | tr '\t' ' ')
    [ -n "$eps" ] && q ec2 delete-vpc-endpoints --vpc-endpoint-ids $eps >/dev/null
    for s in $(q ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text | tr '\t' '\n'); do
      q ec2 revoke-security-group-ingress --group-id "$s" --ip-permissions "$(q ec2 describe-security-groups --group-ids "$s" --query 'SecurityGroups[0].IpPermissions' --output json)" >/dev/null
      q ec2 revoke-security-group-egress  --group-id "$s" --ip-permissions "$(q ec2 describe-security-groups --group-ids "$s" --query 'SecurityGroups[0].IpPermissionsEgress' --output json)" >/dev/null
    done
    for s in $(q ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text | tr '\t' '\n'); do q ec2 delete-security-group --group-id "$s" >/dev/null; done
    for sn in $(q ec2 describe-subnets --filters Name=vpc-id,Values="$vpc" --query 'Subnets[].SubnetId' --output text | tr '\t' '\n'); do q ec2 delete-subnet --subnet-id "$sn" >/dev/null; done
    for rt in $(q ec2 describe-route-tables --filters Name=vpc-id,Values="$vpc" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text | tr '\t' '\n'); do q ec2 delete-route-table --route-table-id "$rt" >/dev/null; done
    for igw in $(q ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$vpc" --query 'InternetGateways[].InternetGatewayId' --output text | tr '\t' '\n'); do q ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" >/dev/null; q ec2 delete-internet-gateway --internet-gateway-id "$igw" >/dev/null; done
    q ec2 delete-vpc --vpc-id "$vpc" >/dev/null && echo "  VPC deleted: $vpc" || echo "  VPC $vpc: delete FAILED (deps remain — re-run)"
  done
  echo "== NUKE $label done =="
}

echo "Profile : $AWS_PROFILE"
echo "Region  : $REGION"
echo "Targets : $(for p in "${PAIRS[@]}"; do printf '%s(%s) ' "${p%%:*}" "${p#*:}"; done)"
echo "PERSIST : tf-state, ECR repo+:bootstrap, ACM certs, watch-ci-*/watch-prod-deploy IAM, org/account/github"
echo "DELETES : ECS, RDS, ElastiCache, ALB/TG, NAT, EIP, Lambda, SQS, AppConfig, SSM(watch*), KMS aliases, VPC+deps"

for pair in "${PAIRS[@]}"; do
  acct="${pair#*:}"
  [ -n "$acct" ] || { echo "FATAL   : ${pair%%:*} account id is empty — source .env" >&2; exit 1; }
done

if [ "$ASSUME_YES" != 1 ]; then
  echo
  read -r -p "Type the target ('$TARGET') to CONFIRM irreversible deletion: " ans
  [ "$ans" = "$TARGET" ] || { echo "aborted (got '$ans')"; exit 1; }
fi

for pair in "${PAIRS[@]}"; do
  label="${pair%%:*}"; acct="${pair#*:}"
  ( xacct_assume "$acct" >/dev/null 2>&1 || { echo "FATAL: could not assume into $label ($acct)" >&2; exit 1; }
    nuke_account "$label" ) || echo "  ! $label nuke returned nonzero — re-run to converge"
done

echo "==================== SUMMARY ===================="
echo "nuke complete. Terraform state now references deleted resources (ghosts) — the next"
echo "scripts/create.sh reconciles by recreating; a scripts/teardown.sh clears the empty stacks."
echo "Verify with: scripts/doctor.sh"
