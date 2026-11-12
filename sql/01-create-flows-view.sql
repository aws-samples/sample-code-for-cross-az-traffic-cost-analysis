-- Deduplicating view: one row per hour, source IP and destination IP, classified by path.
-- Each ENI on the path (client, Transit Gateway ENIs, NAT gateway, server) logs the same traffic.
-- Sum per observing ENI, then take the MAX across observers: no double counting, and a flow still
-- counts if one observer skipped records or delivered them late.
CREATE OR REPLACE VIEW cross_az_analytics.flows AS
SELECT
  year, month, day, flow_hour, srcaddr, dstaddr,
  src_subnet_name, src_az_id, src_vpc_id, src_resource,
  dst_subnet_name, dst_az_id, dst_vpc_id, dst_resource,
  CASE
    WHEN src_vpc_id IS NULL OR dst_vpc_id IS NULL THEN 'External / unmonitored'
    WHEN src_vpc_id <> dst_vpc_id THEN 'Inter-VPC (Transit Gateway)'   -- change if you use VPC peering
    WHEN src_az_id <> dst_az_id   THEN 'Cross-AZ (same VPC)'
    ELSE 'Same AZ'
  END AS traffic_path,
  MAX(bytes) AS bytes,
  COUNT(*)   AS observers
FROM (
  SELECT year, month, day, flow_hour, srcaddr, dstaddr, interface_id,
         src_subnet_name, src_az_id, src_vpc_id, src_resource,
         dst_subnet_name, dst_az_id, dst_vpc_id, dst_resource,
         SUM(bytes) AS bytes
  FROM cross_az_analytics.flow_logs_enriched
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
)
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
