# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""
AWS Glue job: normalize and enrich VPC Flow Logs for cross-AZ traffic analysis.

Input : VPC Flow Logs in Parquet (custom format incl. pkt-srcaddr, pkt-dstaddr) under <flow_logs_path>
Lookup: SSM parameter {"subnets": {cidr: {subnet_id, subnet_name, az_id, vpc_id}},
                       "resources": {ip: label}, "transit_gateway_ips": [ip, ...]}
Output: <output_path>/year=YYYY/month=MM/day=DD/ (Parquet, Snappy), one row per
        (flow hour, source IP, destination IP, observing ENI), registered in the Glue Data Catalog.

Design notes
- Every ENI on a path logs the same traffic (client, Transit Gateway attachment ENIs, NAT gateway, server).
  Flow logs are best effort, and an observer can skip records (log-status SKIPDATA) or deliver them late.
  So this job does NOT pick one observer. It keeps per-observer byte counts, and the Athena view `flows`
  takes the MAX across observers for each (hour, source, destination). That removes duplicates and still
  counts a flow if one observer missed it.
- Transit Gateway attachment ENIs report their own IP in srcaddr/dstaddr. For those records the original
  endpoints come from pkt-srcaddr/pkt-dstaddr.
- Job bookmarks make each run incremental. Late files simply add more observer rows; the view merges them.
- Partitions come from the flow start time, not from the job run time.
"""
import ipaddress
import json
import sys

import boto3
from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import StringType, StructField, StructType

args = getResolvedOptions(
    sys.argv,
    # flow_logs_path: S3 prefix that contains AWSLogs/..., e.g. s3://my-bucket/flow-logs/AWSLogs/
    # output_path:    where enriched Parquet is written, e.g. s3://my-bucket/processed/flow_logs_enriched/
    ["JOB_NAME", "flow_logs_path", "output_path", "database_name", "table_name", "ssm_parameter_name"],
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
logger = glue_context.get_logger()
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

# ---------------------------------------------------------------------------
# 1. Network map from Parameter Store
# ---------------------------------------------------------------------------
network_map = json.loads(boto3.client("ssm").get_parameter(Name=args["ssm_parameter_name"])["Parameter"]["Value"])
networks = sorted(
    ((ipaddress.ip_network(cidr), info) for cidr, info in network_map["subnets"].items()),
    key=lambda item: item[0].prefixlen,
    reverse=True,  # most specific CIDR first
)
resources = network_map.get("resources", {})
tgw_ips = network_map.get("transit_gateway_ips", [])
logger.info(f"Loaded {len(networks)} subnets, {len(tgw_ips)} Transit Gateway ENI IPs, {len(resources)} labels")

lookup_schema = StructType(
    [StructField(n, StringType()) for n in ("subnet_id", "subnet_name", "az_id", "vpc_id", "resource")]
)


@F.udf(returnType=lookup_schema)
def lookup(ip):
    """Subnet, AZ ID, VPC and optional resource label for an IP, or None if outside the monitored VPCs."""
    if not ip or ip == "-":
        return None
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return None
    for network, info in networks:
        if addr.version == network.version and addr in network:
            return (info["subnet_id"], info["subnet_name"], info["az_id"], info["vpc_id"], resources.get(ip))
    return None


# ---------------------------------------------------------------------------
# 2. Read only new flow log objects (job bookmark on transformation_ctx)
# ---------------------------------------------------------------------------
raw = glue_context.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={"paths": [args["flow_logs_path"]], "recurse": True},
    format="parquet",
    transformation_ctx="raw_flow_logs",
)
df = raw.toDF()

if df.rdd.isEmpty():
    logger.info("No new flow log objects since the last run; nothing to do.")
else:
    # -----------------------------------------------------------------------
    # 3. Normalize endpoints and aggregate bytes per observer per hour
    # -----------------------------------------------------------------------
    tgw = F.array(*[F.lit(ip) for ip in tgw_ips]) if tgw_ips else F.array().cast("array<string>")
    observed = (
        df.filter(F.col("log_status") == "OK")
        .withColumn(
            "src_ip",
            F.when(F.array_contains(tgw, F.col("srcaddr")), F.col("pkt_srcaddr")).otherwise(F.col("srcaddr")),
        )
        .withColumn(
            "dst_ip",
            F.when(F.array_contains(tgw, F.col("dstaddr")), F.col("pkt_dstaddr")).otherwise(F.col("dstaddr")),
        )
        .withColumn("flow_hour", F.date_trunc("hour", F.to_timestamp(F.from_unixtime(F.col("start")))))
        .groupBy("flow_hour", "src_ip", "dst_ip", "interface_id")
        .agg(
            F.sum(F.col("bytes").cast("bigint")).alias("bytes"),
            F.sum(F.col("packets").cast("bigint")).alias("packets"),
            F.count(F.lit(1)).alias("records"),
        )
    )

    # -----------------------------------------------------------------------
    # 4. Enrich source and destination (after aggregation: far fewer lookups)
    # -----------------------------------------------------------------------
    enriched = (
        observed.withColumn("src", lookup(F.col("src_ip")))
        .withColumn("dst", lookup(F.col("dst_ip")))
        .select(
            "flow_hour",
            F.col("src_ip").alias("srcaddr"),
            F.col("dst_ip").alias("dstaddr"),
            "interface_id",
            "bytes",
            "packets",
            "records",
            *[F.col(f"src.{c}").alias(f"src_{c}") for c in ("subnet_id", "subnet_name", "az_id", "vpc_id", "resource")],
            *[F.col(f"dst.{c}").alias(f"dst_{c}") for c in ("subnet_id", "subnet_name", "az_id", "vpc_id", "resource")],
        )
        .withColumn("year", F.date_format("flow_hour", "yyyy"))
        .withColumn("month", F.date_format("flow_hour", "MM"))
        .withColumn("day", F.date_format("flow_hour", "dd"))
    )

    # -----------------------------------------------------------------------
    # 5. Append to S3 and create/update the Data Catalog table + partitions
    # -----------------------------------------------------------------------
    sink = glue_context.getSink(
        connection_type="s3",
        path=args["output_path"],
        enableUpdateCatalog=True,
        updateBehavior="UPDATE_IN_DATABASE",
        partitionKeys=["year", "month", "day"],
        transformation_ctx="enriched_sink",
    )
    sink.setFormat("glueparquet", compression="snappy")
    sink.setCatalogInfo(catalogDatabase=args["database_name"], catalogTableName=args["table_name"])
    sink.writeFrame(DynamicFrame.fromDF(enriched, glue_context, "enriched"))
    logger.info("Enriched flow logs written.")

job.commit()
