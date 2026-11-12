# Sample code for cross-AZ traffic cost analysis

Companion code for the Builder Center series *Find the IP pairs behind your cross-AZ data transfer bill*: [Part 1](https://builder.aws.com/content/3Lc8mCBJpFGBLhgayNAHoQdKJ9U/find-the-ip-pairs-behind-your-cross-az-data-transfer-bill-part-1-capture-and-enrich-vpc-flow-logs), [Part 2](https://builder.aws.com/content/3LeNKfVjBXZHoQP6pHcwVKYy0Dc/find-the-ip-pairs-behind-your-cross-az-data-transfer-bill-part-2-calculate-cost-with-amazon-athena) and [Part 3](https://builder.aws.com/content/3M0oHwffHzCkS0o2UddGUSxPdvJ/find-the-ip-pairs-behind-your-cross-az-data-transfer-bill-part-3-amazon-quick-sight-dashboard-fixes-and-production-use). The series builds each component in the AWS Management Console and also provides CLI alternatives.

> [!IMPORTANT]
> This is sample code for non-production use. Work with your security and legal teams to meet your organization's security, regulatory, and compliance requirements before deployment. Review and adapt the IAM permissions, network controls, encryption, retention, monitoring, and deletion behavior for your environment.

## Files

| File | Blog step | Purpose |
|---|---|---|
| `lambda/subnet_mapper.py` | 3 | Lambda function that writes the network map (subnet CIDR → subnet, AZ ID, VPC; NAT gateway and Transit Gateway ENI IPs) to Parameter Store |
| `iam/lambda-subnet-mapper-policy.json` | 3 | Inline policy for the Lambda role. Replace `REGION` and `ACCOUNT_ID` |
| `iam/glue-job-policy.json` | 4 | Inline policy for the Glue job role. Replace `BUCKET`, `REGION` and `ACCOUNT_ID` |
| `cross-az-flowlogs-enrichment.py` | 4 | Glue 5.0 (Spark) job: reads new flow log files only (job bookmarks), rewrites Transit Gateway ENI addresses, sums bytes per hour / IP pair / observing ENI, adds subnet, AZ ID, VPC and labels |
| `sql/01-create-flows-view.sql` | 6 | Athena view that counts each flow once (MAX across observers) and classifies it |
| `sql/check-deduplication-lab.sql` | 6 | Lab only: verifies the three test transfers |
| `sql/02-cross-az-cost-by-ip-pair.sql` | 6 | Estimated cross-AZ and Transit Gateway cost per IP pair, last 30 days |
| `sql/03-quicksight-dataset.sql` | 7 | Custom SQL for the Quick Sight dataset |
| `quicksight.yaml` | 7 | CloudFormation: Quick Sight data source with its own scoped IAM role, dataset and dashboard |
| `pre-requisites.yaml` | 0 (lab) | Instance profile with `AmazonSSMManagedInstanceCore` for the lab instances (trimmed from the workshop template) |
| `multi-vpc-create-all-vpcs-and-tgw.yaml` | 0 (lab) | Lab network from the [AWS Networking Immersion Day](https://catalog.workshops.aws/networking/en-US/foundational/advanced-monitoring); security-group rule descriptions added, the unused public server removed |
| `lab-demo-clients.yaml` | 0 (lab) | Two small EC2 instances in the AZ2 private subnets of VPC A and VPC B, to generate cross-AZ traffic |
| `vpc-analytics-stack.yaml` | Going further | Steps 1–4 in one CloudFormation stack, plus an Athena workgroup `cross-az-analytics` with the view and cost query as saved queries |
| `undeploy.sh` | Clean up | Deletes the analytics resources and optional lab stacks. It removes QuickSight only for the CloudFormation variant; console-built assets require manual deletion. `DRY_RUN=1` previews targets and an explicit confirmation token is required |
| `THREAT_MODEL.md` | Security review | Assets, trust boundaries, threats, mitigations and residual risks for this sample |
| `DEPENDENCIES.md` | License review | Runtime and operator dependencies; no third-party code is bundled |
| `SECURITY.md` | Security reporting | How to report a suspected vulnerability without opening a public issue |

## Requirements

- An AWS account and Region where you can create S3, Lambda, IAM, Glue and Athena resources, and a Quick Sight account (Author or Admin user) in the same Region.
- For the CLI alternatives: bash, AWS CLI v2 and `jq` (AWS CloudShell has all three).
- Runtime libraries (`boto3`, AWS Glue libraries and PySpark) are supplied by the managed Lambda and Glue runtimes; this repository does not vendor packages. See [DEPENDENCIES](DEPENDENCIES.md).
- The repository contains no bundled dataset or machine-learning model. It processes VPC Flow Logs generated in the deployer's own AWS account.

Set these variables once, then follow the post:

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET=cross-az-analytics-$ACCOUNT_ID-$AWS_REGION
```

## Flow log format

The Glue job needs these 9 fields: `srcaddr`, `dstaddr`, `pkt-srcaddr`, `pkt-dstaddr`, `interface-id`, `bytes`, `packets`, `start`, `log-status`. Logs must be delivered to S3 as Parquet with Hive-compatible prefixes. The post uses a 23-field format that adds context for troubleshooting.

## Deploy everything with CloudFormation instead

```bash
aws cloudformation deploy --stack-name CrossAzAnalytics --template-file vpc-analytics-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM --parameter-overrides VPCAId=<vpc-a> VPCBId=<vpc-b>
aws s3 cp cross-az-flowlogs-enrichment.py s3://$BUCKET/scripts/
```

After the first job run, execute the saved queries `create-flows-view` and `cross-az-cost-by-ip-pair` in the `cross-az-analytics` workgroup. For the dashboard, deploy `quicksight.yaml` with `AthenaWorkGroupName=cross-az-analytics`. The stack uses the same resource names as the console build (the Glue role is `CrossAzGlueJobRole-<region>`, because IAM names are account-wide), so don't deploy both in one account and Region. In a second Region of the same account, skip `pre-requisites.yaml`: its named instance profile already exists.

## Clean up

```bash
DRY_RUN=1 bash undeploy.sh --lab
# Review every target printed above, then confirm the exact account, Region and bucket:
CONFIRM_DELETE="$ACCOUNT_ID:$AWS_REGION:$BUCKET" bash undeploy.sh --lab
```

The script refuses destructive cleanup without the exact confirmation token. It deletes the IAM role attached to the `cross-az-subnet-mapper` function and the `cross_az_analytics` Glue database by name, so review the `DRY_RUN=1` output first if either could be shared with something else in the account. Console-built Quick Sight assets (dashboard, analysis, dataset, data source) have to be deleted in the Quick Sight console.

## Cost

See the "Cost of the solution" section of the post. In short: flow log delivery is usually the largest item, the hourly Glue job is about $0.03 per run, and the lab network costs about $8/day while it runs.

## Security

The templates pass `cfn-lint` and `checkov`. The analytics bucket blocks public access, enforces TLS, is encrypted (SSE-S3), versioned, and keeps its own server access logs under `access-logs/` for 90 days. The five remaining Checkov skips are documented inline in `vpc-analytics-stack.yaml` (`Metadata → checkov → skip`): Lambda concurrency limit, dead-letter queue, VPC placement and environment-variable encryption for a function that only calls AWS APIs and holds no secrets, and a Glue security configuration where the output bucket is already encrypted. `ec2:Describe*` actions use `Resource: "*"` because they don't support resource-level permissions. The Glue role needs `s3:GetObject` on `scripts/*` to load its own script, `s3:DeleteObject` on `processed/*` for Spark's temporary files, and wildcard `s3:prefix` values to enumerate nested flow-log, script and processed-data keys. The standalone subnet-mapper policy intentionally grants only `ssm:PutParameter`; the CloudFormation custom-resource variant has a different handler and adds `ssm:DeleteParameter` so stack deletion removes its parameter. The QuickSight role retains S3 multipart actions used by Athena query execution, scoped to this sample's query-result prefix ([Athena IAM example](https://docs.aws.amazon.com/athena/latest/ug/udf-iam-access.html)). The lab network is a workshop template with lab simplifications (allow-all network ACLs, public subnets), not a production design. Flow logs contain IP addresses: apply your own retention and access rules to the bucket.

The Glue and QuickSight roles also attach AWS-managed service policies (`AWSGlueServiceRole`, `AWSQuicksightAthenaAccess`) whose catalog permissions are account-wide; the Lambda log group is created by Lambda with no retention limit; enriched data under `processed/` has no expiry; only IPv4 is mapped. These and other accepted trade-offs are listed in the threat model's "Known limitations" section.

See [THREAT_MODEL](THREAT_MODEL.md) for the trust boundaries, abuse cases, controls and residual risks. See [SECURITY](SECURITY.md) to report a suspected vulnerability privately.

## License

This sample repository is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.

## Code of Conduct

This project has adopted the [Amazon Open Source Code of Conduct](CODE_OF_CONDUCT.md).
