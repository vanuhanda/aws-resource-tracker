#!/bin/bash
# Author: Varun | Version: v5
# About: AWS resource and cost-waste report, parallel version
# Usage: ./aws-resource-tracker.sh [region] [output_dir]

set -euo pipefail

REGION="${1:-ap-southeast-2}"
OUT_DIR="${2:-$HOME/aws-tracker/reports}"
REPORT="$OUT_DIR/report-$(date +%F_%H%M).txt"
MAX_JOBS=8
export AWS_DEFAULT_REGION="$REGION"
mkdir -p "$OUT_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
N=0

# Prints stdin, or "(none)" if it is empty
show() {
  local out; out=$(cat)
  if [ -z "$out" ] || [ "$out" = "None" ]; then echo "(none)"; else echo "$out"; fi
}

# Runs a check in the background, saving its output to a numbered file so the
# final report keeps the order. Never stops the script on error.
check() {
  N=$((N+1))
  local f="$TMP/$(printf '%03d' "$N")" title="$1"
  shift
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do sleep 0.2; done
  (
    echo; echo "=== $title ==="
    if out=$("$@" 2>&1); then
      printf '%s\n' "$out" | show
    else
      echo "(error or no access: $(echo "$out" | head -1))"
    fi
  ) > "$f" &
}

check_tools() {
  command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }
  aws sts get-caller-identity >/dev/null 2>&1 \
    || { echo "AWS credentials not working" >&2; exit 1; }
}

old_keys_cmd() {
  local cutoff u
  cutoff=$(date -u -d '90 days ago' +%F)
  for u in $(aws iam list-users --query 'Users[].UserName' --output text); do
    aws iam list-access-keys --user-name "$u" \
      --query "AccessKeyMetadata[?CreateDate<='$cutoff'].[UserName,AccessKeyId,CreateDate]" \
      --output text
  done
}

main() {
  echo "AWS Resource Report"
  echo "Date:    $(date)"
  echo "Region:  $REGION"
  echo "Account: $(aws sts get-caller-identity --query Account --output text)"

  check "Free plan credits (type, status, remaining, unit, expiry)" \
    aws freetier get-account-plan-state --region us-east-1 \
    --query '[accountPlanType,accountPlanStatus,accountPlanRemainingCredits.amount,accountPlanRemainingCredits.unit,accountPlanExpirationDate]' --output text

  # --- Core ---
  check "S3 buckets"                          aws s3 ls
  check "EC2 running instances"               aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output text
  check "EC2 stopped instances"               aws ec2 describe-instances --filters Name=instance-state-name,Values=stopped --query 'Reservations[].Instances[].InstanceId' --output text
  check "ALL EBS volumes (id, GiB, state, type)" aws ec2 describe-volumes --query 'Volumes[].[VolumeId,Size,State,VolumeType]' --output text
  check "Unattached EBS volumes (cost waste)" aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]' --output text
  check "Unused Elastic IPs (cost waste)"     aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp' --output text
  check "EBS snapshots (yours, billed)"       aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,VolumeSize]' --output text
  check "AMIs (yours; their snapshots are billed)" aws ec2 describe-images --owners self --query 'Images[].[ImageId,Name]' --output text
  check "Lambda functions"                    aws lambda list-functions --query 'Functions[].FunctionName' --output text
  check "IAM users"                           aws iam list-users --query 'Users[].UserName' --output text
  check "IAM access keys older than 90 days"  old_keys_cmd

  # --- Expensive / sticky services ---
  check "EKS clusters (about \$0.10/h each)"  aws eks list-clusters --query 'clusters' --output text
  check "Load balancers (ALB/NLB)"            aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,Type]' --output text
  check "Classic load balancers"              aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
  check "NAT gateways (hourly cost)"          aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
  check "RDS instances"                       aws rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus]' --output text
  check "RDS clusters (Aurora)"               aws rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text
  check "RDS manual snapshots"                aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
  check "ECR repositories"                    aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
  check "CloudWatch log groups"               aws logs describe-log-groups --query 'logGroups[].logGroupName' --output text
  check "Non-default VPCs"                    aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`false`].VpcId' --output text
  check "CloudFormation stacks"               aws cloudformation describe-stacks --query 'Stacks[].[StackName,StackStatus]' --output text
  check "DynamoDB tables"                     aws dynamodb list-tables --query 'TableNames' --output text
  check "EFS file systems"                    aws efs describe-file-systems --query 'FileSystems[].FileSystemId' --output text
  check "Secrets Manager secrets"             aws secretsmanager list-secrets --query 'SecretList[].Name' --output text
  check "Custom IAM roles (not service-linked)" aws iam list-roles --query 'Roles[?!starts_with(Path, `/aws-service-role/`)].RoleName' --output text

  wait
  cat "$TMP"/*
}

check_tools
main | tee "$REPORT"

# Keep only the last 7 days of reports
find "$OUT_DIR" -name 'report-*.txt' -mtime +7 -delete
