-- Traffic between monitored IPs over the last 30 days, by path, with estimated cost.
-- Rates (us-east-1): cross-AZ $0.01/GB out + $0.01/GB in; Transit Gateway processing $0.02/GB.
-- Traffic that crosses AZs through a Transit Gateway has no cross-AZ data transfer charge.
SELECT
  srcaddr, dstaddr,
  src_subnet_name || COALESCE(' (' || src_resource || ')', '') AS source,
  dst_subnet_name || COALESCE(' (' || dst_resource || ')', '') AS destination,
  src_az_id, dst_az_id, traffic_path,
  ROUND(SUM(bytes) / POWER(1024, 3), 3) AS total_gb,
  ROUND(SUM(IF(traffic_path = 'Cross-AZ (same VPC)', bytes, 0)) / POWER(1024, 3) * 0.02, 4) AS cross_az_transfer_usd,
  ROUND(SUM(IF(traffic_path = 'Inter-VPC (Transit Gateway)', bytes, 0)) / POWER(1024, 3) * 0.02, 4) AS tgw_processing_usd
FROM cross_az_analytics.flows
WHERE traffic_path <> 'External / unmonitored'
  AND flow_hour >= current_timestamp - INTERVAL '30' DAY
GROUP BY 1, 2, 3, 4, 5, 6, 7
HAVING SUM(bytes) >= 1048576   -- hide pairs under 1 MiB
ORDER BY total_gb DESC
LIMIT 25;
