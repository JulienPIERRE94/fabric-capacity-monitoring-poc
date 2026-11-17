SELECT
    id % 10 AS bucket,
    COUNT(*) AS row_count,
    SUM(id) AS sum_id
FROM range(100000)
GROUP BY id % 10
ORDER BY bucket;
