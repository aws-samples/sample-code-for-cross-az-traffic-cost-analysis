#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Removes the analytics resources and, with --lab, the disposable lab stacks created by the post.
# It is safe to rerun: missing optional resources are ignored, while failed deletions are reported.
#
#   export AWS_REGION=us-east-1
#   bash undeploy.sh            # analytics pipeline only (Steps 1-7)
#   bash undeploy.sh --lab      # also the three lab stacks from Step 0
#   DRY_RUN=1 bash undeploy.sh  # print what would be deleted, change nothing
#   CONFIRM_DELETE="$ACCOUNT_ID:$AWS_REGION:$BUCKET" bash undeploy.sh --lab
#                              # delete only after reviewing the dry run
#
# Console-built Quick Sight assets (Step 7a-7c) are not deleted here: remove the dashboard,
# analysis, dataset and data source in the Quick Sight console. The CloudFormation variant is.
set -uo pipefail
export AWS_PAGER=""
: "${AWS_REGION:?set AWS_REGION first}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET=${BUCKET:-cross-az-analytics-$ACCOUNT_ID-$AWS_REGION}
LAB=false; [ "${1:-}" = "--lab" ] && LAB=true

CONFIRM_TOKEN="$ACCOUNT_ID:$AWS_REGION:$BUCKET"
if [ -z "${DRY_RUN:-}" ] && [ "${CONFIRM_DELETE:-}" != "$CONFIRM_TOKEN" ]; then
  echo "Refusing destructive cleanup. Run DRY_RUN=1 first, then set:" >&2
  echo "  CONFIRM_DELETE='$CONFIRM_TOKEN'" >&2
  exit 2
fi

log() { echo "[$(date -u +%T)] $*"; }
FAILURES=0
run() {
  if [ -n "${DRY_RUN:-}" ]; then
    echo "  (dry-run) $*"
  elif ! "$@" >/dev/null 2>&1; then
    log "  ERROR: command failed: $*"
    FAILURES=$((FAILURES + 1))
  fi
}
run_optional() {
  if [ -n "${DRY_RUN:-}" ]; then
    echo "  (dry-run) $*"
  elif ! "$@" >/dev/null 2>&1; then
    log "  note: optional cleanup skipped or resource already absent: $*"
  fi
}
stack_exists() { aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1; }
empty_bucket() {   # removes current objects, old versions and delete markers (the stack's bucket is versioned)
  run aws s3 rm "s3://$1" --recursive --quiet
  if [ -n "${DRY_RUN:-}" ]; then
    echo "  (dry-run) purge object versions in s3://$1"
    return
  fi
  while :; do
    # shellcheck disable=SC2016  # JMESPath requires literal backticks around true.
    if ! batch=$(aws s3api list-object-versions --bucket "$1" --max-keys 1000 --output json \
      --query '{Objects: ([Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]), Quiet: `true`}'); then
      log "  ERROR: could not list versions in s3://$1"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
    [ "$(echo "$batch" | jq '.Objects | length')" -gt 0 ] || break
    if ! aws s3api delete-objects --bucket "$1" --delete "$batch" >/dev/null; then
      log "  ERROR: could not delete an object-version batch from s3://$1"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
  done
}
delete_stack() {
  stack_exists "$1" || return 0
  log "delete stack $1"
  run aws cloudformation delete-stack --stack-name "$1"
  if [ -z "${DRY_RUN:-}" ] && ! aws cloudformation wait stack-delete-complete --stack-name "$1"; then
    log "  ERROR: $1 did not delete cleanly; check the stack events"
    FAILURES=$((FAILURES + 1))
  fi
}
delete_role() {   # removes inline + managed policies, then the role
  aws iam get-role --role-name "$1" >/dev/null 2>&1 || return 0
  log "delete role $1"
  for p in $(aws iam list-role-policies --role-name "$1" --query PolicyNames --output text); do
    run aws iam delete-role-policy --role-name "$1" --policy-name "$p"; done
  for a in $(aws iam list-attached-role-policies --role-name "$1" --query 'AttachedPolicies[].PolicyArn' --output text); do
    run aws iam detach-role-policy --role-name "$1" --policy-arn "$a"
    # the Lambda console creates a customer-managed AWSLambdaBasicExecutionRole-<uuid> policy: remove it too
    case "$a" in arn:aws:iam::"$ACCOUNT_ID":policy/service-role/AWSLambdaBasicExecutionRole-*) run aws iam delete-policy --policy-arn "$a";; esac
  done
  run aws iam delete-role --role-name "$1"
}

log "account $ACCOUNT_ID, region $AWS_REGION, bucket $BUCKET${DRY_RUN:+ (DRY RUN)}"

# 1. Flow logs: stop deliveries to this sample's configured bucket first. The Name tag alone
# is not an ownership boundary because another deployment can use the same conventional name.
FL=$(aws ec2 describe-flow-logs --filter Name=tag:Name,Values=cross-az-analytics --output json \
  | jq -r --arg bucket "$BUCKET" \
      '[.FlowLogs[] | select((.LogDestination // "") | contains(":::" + $bucket + "/")) | .FlowLogId] | join(" ")')
if [ -n "$FL" ]; then
  read -r -a FLOW_LOG_IDS <<< "$FL"
  log "delete flow logs $FL"
  run aws ec2 delete-flow-logs --flow-log-ids "${FLOW_LOG_IDS[@]}"
fi

# 2. Quick Sight (CloudFormation variant)
delete_stack CrossAzAnalyticsQuickSight

# 3. Everything-in-one stack, if that is how you deployed: empty its bucket, then delete it
if stack_exists CrossAzAnalytics; then
  log "empty s3://$BUCKET"; empty_bucket "$BUCKET"
  delete_stack CrossAzAnalytics
  # the stack may already be DELETE_FAILED from an earlier attempt with a non-empty bucket: retry once
  stack_exists CrossAzAnalytics && { empty_bucket "$BUCKET"; delete_stack CrossAzAnalytics; }
else
  # 4. Glue: trigger, job, database (removes the table and the view)
  # IAM roles are account-wide. Only delete them when the Region actually had the resource that used
  # them, otherwise running this in Region B would remove the roles of a deployment in Region A.
  HAD_GLUE_JOB=$(aws glue get-job --job-name cross-az-flowlogs-enrichment --query Job.Name --output text 2>/dev/null || true)
  log "delete Glue trigger, job and database"
  run_optional aws glue stop-trigger --name cross-az-flowlogs-hourly
  run_optional aws glue delete-trigger --name cross-az-flowlogs-hourly
  run_optional aws glue delete-job --job-name cross-az-flowlogs-enrichment
  run_optional aws glue delete-database --name cross_az_analytics

  # 5. Athena saved query
  for id in $(aws athena list-named-queries --work-group primary --query NamedQueryIds --output text); do
    n=$(aws athena get-named-query --named-query-id "$id" --query NamedQuery.Name --output text)
    [ "$n" = cross-az-cost-by-ip-pair ] && { log "delete saved query $n"; run aws athena delete-named-query --named-query-id "$id"; }
  done

  # 6. Lambda, its role, the parameter and the log group
  ROLE_ARN=$(aws lambda get-function-configuration --function-name cross-az-subnet-mapper --query Role --output text 2>/dev/null)
  if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != None ]; then
    log "delete Lambda cross-az-subnet-mapper"
    run aws lambda delete-function --function-name cross-az-subnet-mapper
    delete_role "${ROLE_ARN##*/}"   # console-created role (random suffix) or the CLI's cross-az-subnet-mapper-role
  fi
  run_optional aws ssm delete-parameter --name /cross-az/subnet-map

  # 7. Glue role and S3
  [ -n "$HAD_GLUE_JOB" ] && delete_role CrossAzGlueJobRole
  if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    log "empty and delete s3://$BUCKET"
    empty_bucket "$BUCKET"
    run aws s3api delete-bucket --bucket "$BUCKET"
  fi
  run_optional aws s3 rm "s3://aws-glue-assets-$ACCOUNT_ID-$AWS_REGION/scripts/cross-az-flowlogs-enrichment.py"
fi
# Lambda log group: CloudFormation doesn't own it either, so it survives both paths unless removed here
run_optional aws logs delete-log-group --log-group-name /aws/lambda/cross-az-subnet-mapper

# 8. Lab network (Step 0), in reverse order
if $LAB; then
  for s in CrossAzDemoClients NetworkingWorkshopMultiVPCandTGW NetworkingWorkshopPrerequisites; do delete_stack "$s"; done
fi

log "leftovers:"
echo "  flow logs : $(aws ec2 describe-flow-logs --filter Name=tag:Name,Values=cross-az-analytics --query 'FlowLogs[].FlowLogId' --output text)"
echo "  glue jobs : $(aws glue get-jobs --query "Jobs[?starts_with(Name,'cross-az')].Name" --output text)"
echo "  ssm       : $(aws ssm describe-parameters --query "Parameters[?starts_with(Name,'/cross-az')].Name" --output text)"
echo "  roles     : $(aws iam list-roles --query "Roles[?contains(RoleName,'CrossAz') || starts_with(RoleName,'cross-az')].RoleName" --output text)"
echo "  bucket    : $(aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && echo "$BUCKET still exists" || echo none)"
echo "  log group : $(aws logs describe-log-groups --log-group-name-prefix /aws/lambda/cross-az-subnet-mapper --query 'logGroups[].logGroupName' --output text)"
echo "  stacks    : $(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
                    --query "StackSummaries[?contains(StackName,'CrossAz') || contains(StackName,'NetworkingWorkshop')].StackName" --output text)"
echo "  (roles are account-wide: ones listed here may belong to a deployment in another Region)"
if [ "$FAILURES" -gt 0 ]; then
  log "cleanup completed with $FAILURES failed deletion command(s); review the errors and leftovers above"
  exit 1
fi
