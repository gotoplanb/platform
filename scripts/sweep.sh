#!/usr/bin/env bash
# Read-only orphan sweep: lists *billable* AWS leftovers in REGION after a teardown.
# Safe with the read-only profile (default watch-ro). Exits 1 if any billable orphan is
# found, 0 if clean — so it can gate a teardown ("destroy && sweep").
#
# Intentionally-kept foundation is NOT flagged: the tf-state bucket (watch-tfstate-*),
# the lock table (watch-tflocks), the shared ECR repo, and the ACM cert (free). Everything
# else in this single-tenant account is fair game to report.
#
# Usage: scripts/sweep.sh        Env: AWS_PROFILE (default watch-ro), AWS_REGION (us-east-1).
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-watch-ro}"
REGION="${AWS_REGION:-us-east-1}"
Q() { aws --region "$REGION" "$@"; }
found=0

# name an expected-to-survive bucket/table so we never flag the foundation
STATE_BUCKET_RE='watch-tfstate-|watch-tflocks'

check() { # check "<label>" "<newline/space-separated ids, empty if clean>"
  local label="$1" ids="$2"
  ids="$(echo "$ids" | tr '\t' ' ' | xargs 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    local n; n=$(echo "$ids" | wc -w | tr -d ' ')
    found=$((found + n))
    printf '  ✗ %-22s %s\n' "$label" "$ids"
  else
    printf '  ✓ %-22s clean\n' "$label"
  fi
}

echo "Orphan sweep — region $REGION, profile $AWS_PROFILE"
aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || { echo "no AWS creds" >&2; exit 2; }
echo

echo "Compute / network (the real cost):"
check "Unassociated EIPs"   "$(Q ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].PublicIp' --output text)"
check "NAT gateways"        "$(Q ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text)"
check "Load balancers"      "$(Q elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text)"
check "Target groups"       "$(Q elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output text)"
check "RDS instances"       "$(Q rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text)"
check "RDS snapshots(man.)" "$(Q rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text)"
check "ElastiCache"         "$(Q elasticache describe-cache-clusters --query 'CacheClusters[].CacheClusterId' --output text 2>/dev/null)"
check "EBS volumes(avail)"  "$(Q ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text)"
check "ENIs(available)"     "$(Q ec2 describe-network-interfaces --filters Name=status,Values=available --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
check "ECS clusters"        "$(Q ecs list-clusters --query 'clusterArns[]' --output text | tr '\t' '\n' | sed 's#.*/##' | tr '\n' ' ')"
check "Non-default VPCs"    "$(Q ec2 describe-vpcs --filters Name=isDefault,Values=false --query 'Vpcs[].VpcId' --output text)"

echo
echo "Serverless / edge (small but real):"
# CloudFront is global; only flag ENABLED distros (a disabled one bills ~nothing and is mid-delete)
check "CloudFront(enabled)" "$(aws cloudfront list-distributions --query 'DistributionList.Items[?Enabled==`true`].Id' --output text 2>/dev/null)"
check "Lambda functions"    "$(Q lambda list-functions --query 'Functions[?starts_with(FunctionName,`watch`)].FunctionName' --output text)"
check "SQS queues"          "$(Q sqs list-queues --queue-name-prefix watch --query 'QueueUrls[]' --output text | tr '\t' '\n' | sed 's#.*/##' | tr '\n' ' ')"
check "Step Functions"      "$(Q stepfunctions list-state-machines --query 'stateMachines[?starts_with(name,`watch`)].name' --output text)"
check "API Gateway(HTTP)"   "$(Q apigatewayv2 get-apis --query 'Items[].Name' --output text)"
check "CW log groups"       "$(Q logs describe-log-groups --query 'logGroups[?starts_with(logGroupName,`/ecs/watch`) || starts_with(logGroupName,`/aws/lambda/watch`)].logGroupName' --output text)"

echo
echo "Buckets (foundation excluded):"
BUCKETS="$(aws s3api list-buckets --query 'Buckets[?starts_with(Name,`watch`)].Name' --output text | tr '\t' '\n' | grep -vE "$STATE_BUCKET_RE" | tr '\n' ' ')"
check "S3 (watch-*, non-state)" "$BUCKETS"

echo
if [ "$found" -gt 0 ]; then
  echo "RESULT: $found billable orphan(s) found — investigate above."
  exit 1
fi
echo "RESULT: clean — no billable orphans. (ECR repo + ACM cert + tf-state intentionally remain.)"
