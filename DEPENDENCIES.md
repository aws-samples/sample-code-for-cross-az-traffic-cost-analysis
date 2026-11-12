# Dependencies and third-party content

This repository does not vendor third-party libraries, binaries, datasets, model weights, images or package-manager artifacts.

## Runtime dependencies

| Dependency | How it is supplied | Purpose |
|---|---|---|
| Python standard library | AWS Lambda Python 3.14 and AWS Glue 5.0 runtimes | JSON, environment, IP-address and argument handling |
| Boto3 | AWS Lambda and AWS Glue managed runtimes | AWS API calls |
| AWS Glue libraries and PySpark | AWS Glue 5.0 managed runtime | Read, transform and write Parquet data |
| `cfnresponse` | AWS CloudFormation inline Lambda runtime helper | Report custom-resource completion |

These packages are not installed or redistributed by this repository. Runtime-provided versions can change with AWS managed runtime updates.

## Operator tools

- Bash
- AWS CLI v2
- `jq` for versioned S3 cleanup and CLI output
- `iperf3`, installed only on disposable lab instances to generate synthetic traffic

Validation tools used by maintainers include cfn-lint, Checkov, detect-secrets, ShellCheck, Repolinter, Holmes and ProtoShield. They are not runtime dependencies or redistributed with the sample.

## AWS-authored source provenance

`multi-vpc-create-all-vpcs-and-tgw.yaml` and `pre-requisites.yaml` are adapted from the AWS Networking Immersion Day workshop referenced in the README. Their source and modifications must be disclosed in the internal content/IP review. They are AWS-authored material rather than third-party code. Do not add a third-party license file unless the license reviewer determines one is required.

## Data and models

The repository contains no bundled dataset and no machine-learning model. Test IP addresses are synthetic private addresses. A deployment processes VPC Flow Logs generated in the deployer's own AWS account; those logs and their enriched output are operational telemetry, not redistributed sample data.
