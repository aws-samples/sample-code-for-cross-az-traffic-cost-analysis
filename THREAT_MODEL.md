# Threat model

## Status and scope

This threat model covers the non-production sample in this repository. It is prepared for security review and is not an approval or a claim of production readiness. The sample collects VPC Flow Logs in one AWS account and Region, enriches them with network metadata, queries them with Athena, and optionally displays results in Amazon QuickSight.

Out of scope: customer-specific deployments, production hardening, cross-account aggregation, identity federation, custom authentication, regulated workloads, and changes to AWS service implementations.

## Assets and data classification

| Asset | Sensitivity and impact |
|---|---|
| Raw VPC Flow Logs | Operational telemetry containing account, VPC, subnet, instance, interface, IP address, port, action and traffic-volume data. Treat according to the deployer's data-classification policy. |
| Enriched flow data | Adds subnet names, AZ IDs, VPC IDs and resource labels. It can reveal network topology and workload naming. |
| Network map in Parameter Store | Contains subnet CIDRs/names and NAT or Transit Gateway interface addresses. It contains no credentials but discloses topology. |
| Athena results and QuickSight assets | Can reveal communicating IP pairs, traffic volumes, estimated costs and resource labels. |
| IAM roles | Permit collection, enrichment, querying and cleanup. Misuse can expose or delete sample data. |
| Glue script and SQL | Determine attribution and cost calculations. Unauthorized modification can corrupt results or execute with the Glue role. |

The repository contains synthetic private IP addresses and no customer data, credentials, bundled dataset or ML model. A deployment processes data generated in the deployer's account.

## Actors and trust boundaries

- **Deployer/operator:** can create named IAM roles and the sample resources. The operator is trusted to choose the correct account, Region, VPCs and bucket.
- **Dashboard author:** receives access to the QuickSight data source, dataset and dashboard and can view the underlying operational telemetry.
- **AWS services:** VPC Flow Logs delivers to S3; Lambda reads network metadata and writes Parameter Store; Glue reads S3 and Parameter Store and writes enriched data; Athena reads enriched data and writes query results; QuickSight queries Athena.
- **External addresses in flow records:** are untrusted data. The enrichment job treats addresses as data and does not execute their contents.

Trust boundaries exist at IAM role assumption, service-to-S3 bucket-policy statements, operator-supplied CloudFormation parameters, the S3 Glue-script object, Parameter Store, Athena SQL, QuickSight sharing and the destructive cleanup interface.

## Threats, controls and residual risks

| Threat | Existing controls | Residual risk / production action |
|---|---|---|
| Public or insecure access to telemetry | S3 public access is blocked; bucket policy denies non-TLS requests; SSE-S3 and Athena result encryption are enabled. | Consider customer-managed KMS keys, separate access-log storage and stricter data-access roles for production. |
| Confused-deputy writes to S3 | VPC Flow Logs and S3 logging statements restrict source account and source ARN. | Validate organization-specific service-control policies and centralized logging requirements. |
| Excess IAM privilege | Data access is scoped to the sample bucket prefixes and one SSM parameter. EC2 Describe APIs use `Resource: "*"` because they do not support resource-level permissions. | AWS-managed service-role policies remain broader and can change. Review their effective permissions before production use. |
| Glue script tampering | Bucket public access is blocked, TLS is enforced and versioning is enabled. | The Glue job uses a mutable S3 key. Restrict writers and use a controlled release process; consider code signing or immutable artifacts where applicable. |
| Parameter tampering or topology disclosure | The SSM parameter is scoped by IAM and contains no secret. | It is a standard String and reveals topology. Consider SecureString/KMS and separate read/write roles if the data classification requires them. |
| Malformed or adversarial flow-log data | The job accepts only records with `log_status = OK`, parses IP addresses defensively and writes typed output. | VPC Flow Logs are best effort. Missing or late records can affect completeness; results are estimates, not billing records. |
| SQL or CloudFormation parameter injection | Database, view, workgroup and bucket parameters are constrained to expected identifier formats. Deployment requires an already privileged operator. | Do not expose stack parameters to untrusted users. Review generated SQL after any customization. |
| Unauthorized dashboard access or export | QuickSight permissions are granted only to the supplied user ARN; S3 access is prefix-scoped. | Validate the principal and account, restrict sharing/export, and apply retention and audit requirements. |
| Excessive or indefinite retention | Raw logs expire after 30 days, Athena results after 7 days and access logs after 90 days. Cleanup removes sample resources. | Enriched data is retained until deletion. Add a lifecycle rule that matches the organization's retention policy. |
| Accidental deletion or wrong-target cleanup | `DRY_RUN=1` previews targets; destructive execution requires an account/Region/bucket confirmation token; flow-log deletion is restricted to the configured bucket destination. | Cleanup is intentionally destructive and empties versioned objects. Review every dry-run line, use a sandbox, and back up anything that must be retained. |
| Lab network exposure | The lab uses security groups, IMDSv2 and private test instances; only participant and lab CIDRs are allowed for test traffic. | The inherited workshop network has public subnets and permissive NACLs. It is a disposable lab, not a production network. |
| Cost or denial-of-wallet | Lifecycle rules limit some storage; Athena workgroup metrics, encryption and a 10 GiB per-query cutoff are enabled; Glue concurrency is one. | Flow-log delivery, NAT gateways, EC2 and hourly Glue runs incur charges. Monitor cost and tear down promptly. |
| Cross-account or cross-Region name collision | Resource names and Region assumptions are documented; the Glue role includes the Region in the all-in-one stack. | Some IAM names are account-wide. Do not deploy console and stack variants together; inspect existing roles before deployment or cleanup. |

## Scanner exceptions and accepted sample trade-offs

The main template documents Checkov skips for Lambda reserved concurrency, dead-letter queue, VPC placement, environment-variable encryption and a Glue security configuration. The Lambda calls AWS APIs and holds no secret; the output bucket is encrypted. The lab template intentionally retains public subnets, permissive NACLs and small instances to match the disposable workshop topology. These are review items, not production recommendations.

Glue requires `s3:DeleteObject` on the processed prefix for Spark temporary-file commit behavior. The custom-resource Lambda requires `ssm:DeleteParameter` to remove its parameter during stack deletion. AWS-managed policies support the managed services and should be replaced or permission-bound where production requirements demand tighter control.

## Known limitations recorded at security review

These items were noted during the Public Content Security Review (November 2026) and accepted for the sample. Address them before any production adaptation.

- **Glue Data Catalog scope.** The Glue role attaches `AWSGlueServiceRole`, which allows `glue:*` on all catalog resources. The job only touches the `cross_az_analytics` database, but the policy does not enforce that. Production: replace the managed policy with statements limited to the catalog, database and table ARNs of `cross_az_analytics` plus the CloudWatch Logs and S3 permissions the job needs.
- **QuickSight catalog visibility.** The QuickSight data-source role attaches `AWSQuicksightAthenaAccess`, which covers Athena and Glue catalog metadata on `Resource: "*"`. S3 data access is prefix-scoped, but metadata of other databases is readable. Production: scope the Glue catalog actions to `cross_az_analytics`.
- **Server access logs in the same bucket.** The analytics bucket writes its access logs to its own `access-logs/` prefix. This keeps the sample to one bucket but means anyone who can read the bucket can read its audit trail. Production: log to a separate, restricted bucket.
- **Enriched data retention.** Raw logs expire after 30 days and Athena results after 7, but `processed/` has no lifecycle rule. Production: add one that matches your retention policy.
- **Lambda log retention.** The `/aws/lambda/cross-az-subnet-mapper` log group is created implicitly by Lambda with no retention limit. Production: define the log group explicitly with a retention period.
- **Custom-resource error detail.** On failure the stack's custom resource returns the exception text to CloudFormation, so it appears in stack events. Production: return a generic message and keep detail in the function log.
- **Cleanup of shared resources.** `undeploy.sh` deletes the IAM role attached to the `cross-az-subnet-mapper` function and the `cross_az_analytics` Glue database by name. If either is shared with other workloads, it will be removed. Always review the `DRY_RUN=1` output before a destructive run.
- **Dashboard CSV export** is enabled so analysts can act on IP pairs. Restrict it if IP-pair data must not leave QuickSight.
- **IPv6.** Only IPv4 CIDRs and primary ENI addresses are mapped; IPv6 flows are classified as external/unmonitored.
- **Lab template.** Allow-all NACLs, public-IP auto-assignment, previous-generation instances without explicit EBS encryption, and a KMS endpoint on the default security group with no endpoint policy are inherited from the disposable workshop network.
- **Code structure.** The subnet-mapper code exists both inline in `vpc-analytics-stack.yaml` (custom-resource handler) and as `lambda/subnet_mapper.py` (console/CLI handler); the two must be kept in step by hand. The repository has no unit tests or CI and tags few resources.

## Validation and review

The sample has been exercised end to end in a separate Region, including traffic generation, enrichment, deduplication, cost queries and teardown. Local evidence includes cfn-lint, Checkov, secret scanning, Python compilation, JSON validation, Holmes and ProtoShield reports. Formal PCSR review, internal-repository scanner evidence and Guardian acceptance remain external release gates.

Review this threat model whenever IAM permissions, data fields, retention, sharing, executable artifacts or cleanup targets change.
