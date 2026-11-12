# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""
AWS Lambda function: build the network map used by the cross-AZ Glue job.

Environment variables
  VPC_IDS         comma-separated VPC IDs to include, e.g. vpc-0123,vpc-0456
  PARAMETER_NAME  SSM parameter to write (default /cross-az/subnet-map)

Output (JSON in Parameter Store)
  {"subnets":   {"10.0.1.0/24": {"subnet_id", "subnet_name", "az_id", "vpc_id"}, ...},
   "resources": {"10.0.0.106": "NAT gateway", "10.0.5.10": "Transit Gateway ENI", ...},
   "transit_gateway_ips": ["10.0.5.10", ...]}

Run it after you add or change subnets. Runtime: Python 3.14 (any Python 3.10+ works), timeout 1 minute.
"""
import json
import os

import boto3

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
LABELS = {"nat_gateway": "NAT gateway", "transit_gateway": "Transit Gateway ENI"}


def lambda_handler(event, context):
    vpc_ids = [v.strip() for v in os.environ["VPC_IDS"].split(",") if v.strip()]
    parameter = os.environ.get("PARAMETER_NAME", "/cross-az/subnet-map")
    vpc_filter = [{"Name": "vpc-id", "Values": vpc_ids}]

    # 1. Every subnet: CIDR -> subnet ID, Name tag, AZ ID and VPC
    subnets = {}
    for page in ec2.get_paginator("describe_subnets").paginate(Filters=vpc_filter):
        for s in page["Subnets"]:
            name = next((t["Value"] for t in s.get("Tags", []) if t["Key"] == "Name"), s["SubnetId"])
            subnets[s["CidrBlock"]] = {"subnet_id": s["SubnetId"], "subnet_name": name,
                                       "az_id": s["AvailabilityZoneId"], "vpc_id": s["VpcId"]}

    # 2. Label NAT gateway and Transit Gateway ENIs. Transit Gateway ENIs need special handling
    #    in the Glue job, because their records show the ENI's own IP instead of the real endpoint.
    resources, tgw_ips = {}, []
    eni_filter = vpc_filter + [{"Name": "interface-type", "Values": list(LABELS)}]
    for page in ec2.get_paginator("describe_network_interfaces").paginate(Filters=eni_filter):
        for eni in page["NetworkInterfaces"]:
            ip = eni["PrivateIpAddress"]
            resources[ip] = LABELS[eni["InterfaceType"]]
            if eni["InterfaceType"] == "transit_gateway":
                tgw_ips.append(ip)

    value = {"subnets": subnets, "resources": resources, "transit_gateway_ips": tgw_ips}
    # Intelligent-Tiering switches to the advanced tier (8 KB) only if the value outgrows 4 KB
    ssm.put_parameter(Name=parameter, Value=json.dumps(value), Type="String",
                      Tier="Intelligent-Tiering", Overwrite=True)
    result = {"parameter": parameter, "subnets": len(subnets), "labelled_ips": len(resources),
              "transit_gateway_ips": len(tgw_ips)}
    print(result)
    return result
