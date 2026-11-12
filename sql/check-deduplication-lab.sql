-- Lab only (Step 6b): the three iperf3 transfers to server B, each counted once.
-- Expected: 2 observers / 2.012 GiB, 4 observers / 1.006 GiB, 4 observers / 0.503 GiB.
SELECT srcaddr, dstaddr, traffic_path, observers, ROUND(bytes / POWER(1024, 3), 3) AS gib
FROM cross_az_analytics.flows
WHERE dstaddr = '10.1.1.100' AND srcaddr IN ('10.1.3.100', '10.0.3.100', '10.0.1.100');
