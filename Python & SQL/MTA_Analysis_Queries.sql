/* =====================================================================
   MTA Daily Ridership - SQL analysis (SQL Server / T-SQL)
   DEPI | Professional Data Analysis | Team 1

   Works on the data exported by the Python notebook and already loaded in
   MTA_Ridership: dbo.date_dim, dbo.service_dim, dbo.ridership.
   This file only READS the data (it creates two views, nothing is deleted).
   Run section by section: select the lines and press F5, or run all.
   Notes: total = riders for most services, scheduled trips for Access-A-Ride,
   vehicles for Bridges and Tunnels, so totals are never added across services.
   pct_pre_pandemic = % of a comparable pre-pandemic day (100 = reference).
   ===================================================================== */
USE MTA_Ridership;
GO

/* ---------- 0. DATA CHECKS ----------------------------------------- */
-- 0.1 Row counts (expected: date_dim 1706, service_dim 7, ridership 11942)
SELECT 'date_dim' AS tbl, COUNT(*) AS row_count FROM dbo.date_dim
UNION ALL SELECT 'service_dim', COUNT(*) FROM dbo.service_dim
UNION ALL SELECT 'ridership',   COUNT(*) FROM dbo.ridership;

-- 0.2 Coverage and missing values per service (expected: 1706 days, 0 NULLs)
SELECT s.service_name,
       MIN(r.[date]) AS first_date,
       MAX(r.[date]) AS last_date,
       COUNT(*)      AS days_in_data,
       SUM(CASE WHEN r.total IS NULL OR r.pct_pre_pandemic IS NULL THEN 1 ELSE 0 END) AS null_rows
FROM dbo.ridership r
JOIN dbo.service_dim s ON s.service_id = r.service_id
GROUP BY s.service_id, s.service_name
ORDER BY s.service_id;
GO

/* ---------- 1. VIEWS (reused by the queries and by the dashboard) --- */
CREATE OR ALTER VIEW dbo.vw_ridership_full AS
SELECT r.[date], d.[year], d.[month], d.day_type,
       s.service_id, s.service_name, s.measure_type,
       r.total, r.pct_pre_pandemic
FROM dbo.ridership r
JOIN dbo.date_dim d    ON d.[date] = r.[date]
JOIN dbo.service_dim s ON s.service_id = r.service_id;
GO

CREATE OR ALTER VIEW dbo.vw_monthly_summary AS
SELECT [year], [month], service_id, service_name, measure_type,
       COUNT(*)                                          AS days_in_data,
       AVG(CAST(total AS BIGINT))                        AS avg_daily_total,
       ROUND(AVG(CAST(pct_pre_pandemic AS FLOAT)), 1)    AS avg_pct_pre_pandemic
FROM dbo.vw_ridership_full
GROUP BY [year], [month], service_id, service_name, measure_type;
GO

/* ---------- 2. OVERVIEW -------------------------------------------- */
-- Q1. Latest recovery level per service, ranked
SELECT RANK() OVER (ORDER BY pct_pre_pandemic DESC) AS rank_no,
       service_name, measure_type, total, pct_pre_pandemic
FROM dbo.vw_ridership_full
WHERE [date] = (SELECT MAX([date]) FROM dbo.date_dim)
ORDER BY rank_no;

-- Q2. Average % of pre-pandemic level per service and year (one row per service)
SELECT service_name,
       ROUND(AVG(CASE WHEN [year] = 2020 THEN CAST(pct_pre_pandemic AS FLOAT) END), 1) AS y2020,
       ROUND(AVG(CASE WHEN [year] = 2021 THEN CAST(pct_pre_pandemic AS FLOAT) END), 1) AS y2021,
       ROUND(AVG(CASE WHEN [year] = 2022 THEN CAST(pct_pre_pandemic AS FLOAT) END), 1) AS y2022,
       ROUND(AVG(CASE WHEN [year] = 2023 THEN CAST(pct_pre_pandemic AS FLOAT) END), 1) AS y2023,
       ROUND(AVG(CASE WHEN [year] = 2024 THEN CAST(pct_pre_pandemic AS FLOAT) END), 1) AS y2024
FROM dbo.vw_ridership_full
GROUP BY service_id, service_name
ORDER BY service_id;

/* ---------- 3. TRENDS ---------------------------------------------- */
-- Q3. Monthly trend per service (feeds the trend charts)
SELECT [year], [month], service_name, avg_daily_total, avg_pct_pre_pandemic
FROM dbo.vw_monthly_summary
ORDER BY service_name, [year], [month];

-- Q4. Month-over-month change in average daily total (LAG)
SELECT service_name, [year], [month], avg_daily_total,
       LAG(avg_daily_total) OVER (PARTITION BY service_id ORDER BY [year], [month]) AS prev_month_total,
       ROUND(100.0 * (avg_daily_total - LAG(avg_daily_total) OVER (PARTITION BY service_id ORDER BY [year], [month]))
             / NULLIF(LAG(avg_daily_total) OVER (PARTITION BY service_id ORDER BY [year], [month]), 0), 1) AS mom_change_pct
FROM dbo.vw_monthly_summary
ORDER BY service_name, [year], [month];

-- Q5. Year-over-year change for the same month (LAG 12 months)
SELECT service_name, [year], [month], avg_daily_total,
       LAG(avg_daily_total, 12) OVER (PARTITION BY service_id ORDER BY [year], [month]) AS same_month_last_year,
       ROUND(100.0 * (avg_daily_total - LAG(avg_daily_total, 12) OVER (PARTITION BY service_id ORDER BY [year], [month]))
             / NULLIF(LAG(avg_daily_total, 12) OVER (PARTITION BY service_id ORDER BY [year], [month]), 0), 1) AS yoy_change_pct
FROM dbo.vw_monthly_summary
ORDER BY service_name, [year], [month];

-- Q6. Best and worst month per service by % of pre-pandemic level
-- (the first months of 2020 are near 100% because the pandemic had just started)
WITH m AS (
    SELECT service_name, [year], [month], avg_pct_pre_pandemic,
           ROW_NUMBER() OVER (PARTITION BY service_id ORDER BY avg_pct_pre_pandemic DESC, [year], [month]) AS rn_best,
           ROW_NUMBER() OVER (PARTITION BY service_id ORDER BY avg_pct_pre_pandemic ASC,  [year], [month]) AS rn_worst
    FROM dbo.vw_monthly_summary
)
SELECT service_name, 'Best month' AS kind, [year], [month], avg_pct_pre_pandemic FROM m WHERE rn_best = 1
UNION ALL
SELECT service_name, 'Worst month', [year], [month], avg_pct_pre_pandemic FROM m WHERE rn_worst = 1
ORDER BY service_name, kind;

-- Q7. First month AFTER each service's lowest point that reached the threshold
DECLARE @threshold FLOAT = 70;      -- change to 50, 60, 80 ...
WITH ym AS (
    SELECT service_id, [year] * 100 + [month] AS ym, avg_pct_pre_pandemic AS pct
    FROM dbo.vw_monthly_summary
),
low AS (
    SELECT service_id, ym AS low_ym,
           ROW_NUMBER() OVER (PARTITION BY service_id ORDER BY pct ASC, ym) AS rn
    FROM ym
),
hit AS (
    SELECT y.service_id, y.ym, y.pct,
           ROW_NUMBER() OVER (PARTITION BY y.service_id ORDER BY y.ym) AS rn
    FROM ym y
    JOIN low l ON l.service_id = y.service_id AND l.rn = 1 AND y.ym > l.low_ym
    WHERE y.pct >= @threshold
)
SELECT s.service_name, @threshold AS threshold_pct,
       h.ym AS first_month_reached_yyyymm, h.pct AS avg_pct_that_month   -- NULL = never reached
FROM dbo.service_dim s
LEFT JOIN hit h ON h.service_id = s.service_id AND h.rn = 1
ORDER BY s.service_id;
GO

/* ---------- 4. DAY TYPE (weekday vs weekend) ----------------------- */
-- Q8. Average daily total and % of pre-pandemic level by day type
SELECT service_name, day_type,
       AVG(CAST(total AS BIGINT)) AS avg_daily_total,
       ROUND(AVG(CAST(pct_pre_pandemic AS FLOAT)), 1) AS avg_pct_pre_pandemic
FROM dbo.vw_ridership_full
GROUP BY service_id, service_name, day_type
ORDER BY service_id, day_type;

-- Q9. Subways: weekend-to-weekday ratio per year
WITH t AS (
    SELECT [year],
           AVG(CASE WHEN day_type = 'Weekday' THEN CAST(total AS BIGINT) END) AS weekday_avg,
           AVG(CASE WHEN day_type <> 'Weekday' THEN CAST(total AS BIGINT) END) AS weekend_avg
    FROM dbo.vw_ridership_full
    WHERE service_name = N'Subways'
    GROUP BY [year]
)
SELECT [year], weekday_avg, weekend_avg,
       ROUND(1.0 * weekend_avg / NULLIF(weekday_avg, 0), 2) AS weekend_to_weekday_ratio
FROM t
ORDER BY [year];

/* ---------- 5. DATA QUALITY (supports the cleaning log) ------------- */
-- Q10. Zero values (kept as reported; confirm in the data dictionary)
SELECT service_name, [date], day_type, total, pct_pre_pandemic
FROM dbo.vw_ridership_full
WHERE total = 0 OR pct_pre_pandemic = 0
ORDER BY service_name, [date];

-- Q11. Large week-over-week changes (same weekday, change above 100%)
WITH w AS (
    SELECT service_id, service_name, [date], total,
           LAG(total, 7) OVER (PARTITION BY service_id ORDER BY [date]) AS total_prev_week
    FROM dbo.vw_ridership_full
)
SELECT service_name, COUNT(*) AS days_with_change_over_100pct
FROM w
WHERE total_prev_week > 0
  AND ABS(1.0 * (total - total_prev_week)) / total_prev_week > 1
GROUP BY service_id, service_name
ORDER BY service_id;
