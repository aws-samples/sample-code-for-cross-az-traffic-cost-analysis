-- Custom SQL for the Amazon Quick Sight dataset (direct query). One row per day and IP pair.
SELECT
  date_trunc('day', flow_hour) AS flow_day,
  srcaddr, dstaddr,
  src_subnet_name || COALESCE(' (' || src_resource || ')', '') AS src_subnet_name,
  dst_subnet_name || COALESCE(' (' || dst_resource || ')', '') AS dst_subnet_name,
  src_az_id, dst_az_id, traffic_path,
  SUM(bytes) AS total_bytes,
  SUM(bytes) / POWER(1024, 3) AS total_gb,
  SUM(IF(traffic_path = 'Cross-AZ (same VPC)', bytes, 0)) / POWER(1024, 3) * 0.02 AS cross_az_transfer_usd,
  SUM(IF(traffic_path = 'Inter-VPC (Transit Gateway)', bytes, 0)) / POWER(1024, 3) * 0.02 AS tgw_processing_usd
FROM cross_az_analytics.flows
WHERE traffic_path <> 'External / unmonitored'
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
HAVING SUM(bytes) >= 1048576
