-- =====================================================================
--
-- Lab: SQL analytics with DuckDB - Exercises
--
-- =====================================================================

-- Exercise 1: average number of orders per user and average quantity per order
SELECT
  count(*) / count(DISTINCT user_uuid) AS avg_orders_per_user,
  round(avg(quantity), 2) AS avg_quantity_per_order
FROM orders;

-- Exercise 2: first and last order of each user, and number of days between them
SELECT
  u.username,
  min(o.date) AS first_order,
  max(o.date) AS last_order,
  date_diff('day', min(o.date), max(o.date)) AS days_between
FROM orders o
JOIN users u ON o.user_uuid = u.uuid
GROUP BY ALL
ORDER BY days_between DESC;

-- Exercise 3: hour of the day with the highest quantity sold (UTC)
SELECT hour(date) AS hour, sum(quantity) AS quantity
FROM orders
GROUP BY hour
ORDER BY quantity DESC
LIMIT 1;

-- Exercise 4: month-over-month variation of the quantity sold per product, in percent
WITH monthly AS (
  SELECT product, strftime(date, '%Y-%m') AS month, sum(quantity) AS quantity
  FROM orders
  GROUP BY product, month
)
SELECT
  product,
  month,
  quantity,
  lag(quantity) OVER w AS previous_quantity,
  round(100.0 * (quantity - lag(quantity) OVER w) / lag(quantity) OVER w, 1) AS variation_pct
FROM monthly
WINDOW w AS (PARTITION BY product ORDER BY month)
ORDER BY product, month;

-- Exercise 5: users who ordered every product at least once
SELECT u.username, u.name
FROM orders o
JOIN users u ON o.user_uuid = u.uuid
GROUP BY ALL
HAVING count(DISTINCT o.product) = (SELECT count(DISTINCT product) FROM orders)
ORDER BY u.username;


-- =====================================================================
--
--Lab: SQL analytics with DuckDB - Answers to the questions
--
-- =====================================================================


-- =====================================================================
-- S3 configuration
-- =====================================================================

-- Q1. The persistent secret is stored in a file of your home directory.
--     What are the risks, and why are they limited on Onyxia?
--
-- Risks:
--   - The credentials (access key, secret key, session token) are written
--     to disk (~/.duckdb/stored_secrets). Anyone or any process that can
--     read this file can access the S3 bucket.
--   - The file can leak by mistake: committed to Git, copied in a backup,
--     shared with a project folder.
-- Why the risks are limited on Onyxia:
--   - The credentials are temporary: the session token expires, so a leaked
--     secret stops working quickly (hence the ExpiredToken / 403 errors).
--   - They only give access to my own bucket (user-l-minet-ece).
--   - The service runs in my own isolated Kubernetes namespace: nobody else
--     can read my home directory.
--   - The secret is recreated at each service startup.

-- Q2. The secret is visible to any process running as your user.
--     How would you restrict the access to S3 for a Kubernetes Job?
--
--   - Do not reuse my personal credentials: create dedicated credentials
--     for the Job, with the least privilege (for example read bronze/ only).
--   - Store them in a dedicated Kubernetes Secret, as done in the S3 lab
--     (s3-credentials), and mount it only in the pod of this Job, as
--     environment variables or a volume.
--   - Use RBAC (Role, ServiceAccount) so that only this Job can read the
--     Secret.
--   - Prefer short-lived credentials and delete the Secret when the Job is
--     done.


-- =====================================================================
-- Query the bronze layer
-- =====================================================================

-- Q3. The dataset contains 50 users and 2829 orders with unique identifiers.
--     Why does approx_unique return 40 and 3167?
--
--   - approx_unique does not count the distinct values exactly: it ESTIMATES
--     them with the HyperLogLog algorithm.
--   - HyperLogLog is fast and uses very little memory, even on huge
--     datasets, but its result has an error margin.
--   - The exact count is obtained with count(DISTINCT ...), which is slower
--     and uses more memory. Proof:
SELECT
  count(DISTINCT user_uuid) AS exact_users,   -- 50
  count(DISTINCT uuid) AS exact_orders        -- 2829
FROM orders;

-- Q4. The types are inferred from a sample of the file. Which issue may
--     occur with a large file whose first rows are not representative?
--
--   - DuckDB guesses the type of each column from the first rows only.
--   - If a later row contains a value of another type (for example "N/A"
--     in a column detected as an integer), the read fails with a conversion
--     error, or the column gets a wrong type.
--   - Solutions: increase the sample (sample_size option, -1 = whole file)
--     or declare the column types explicitly (types / columns options).
--   - Parquet avoids this issue: the schema is stored in the file.


-- =====================================================================
-- Parquet export
-- =====================================================================
-- My result: the Parquet file weighs about 130 KB against 332 KB for the CSV.
--   uuid       102191 bytes compressed / 113189 uncompressed
--   user_uuid    2125 /   2348
--   date        22667 /  22661
--   quantity     1242 /   1245
--   product      1271 /   1266

-- Q5. Why is the uuid column barely compressed?
--
--   - Compression works by finding repetitions and writing them shorter.
--   - The order identifiers are all unique (2829 distinct values) and
--     random: there is nothing repeated, neither whole values nor patterns.
--   - Dictionary encoding does not help either: the dictionary would have
--     as many entries as rows.

-- Q6. Why is the compressed size of some columns larger than their
--     uncompressed size?
--
--   - The "uncompressed" size is measured AFTER the Parquet encoding
--     (dictionary, binary integers): date and product are already compact.
--   - Snappy cannot shrink them further, but still adds a few bytes of
--     headers, so the result is a few bytes larger
--     (date: 22667 vs 22661, product: 1271 vs 1266).


-- =====================================================================
-- Hive partitioning
-- =====================================================================
-- My result: 6 files, one per product directory (product=bread/, ...).
-- EXPLAIN ANALYZE with WHERE product = 'cookie':
--   Scanning Files: 1/6, 466 rows, 33.7 KiB downloaded, 3 GET requests.

-- Q7. Why is partitioning by uuid a bad idea?
--
--   - uuid is unique: one directory and one file per order, so millions
--     of tiny files on a real dataset (the "small files problem").
--   - On object storage, every object costs at least one HTTP request
--     with latency (and possibly a cost): reading millions of tiny objects
--     is very slow, and listing them is slow too.
--   - Every Parquet file has its own footer: on a tiny file, the metadata
--     weighs more than the data, and there is nothing to compress.
--   - It is useless: queries almost never filter on a single order.
--   - A good partition column has few distinct values and is often used
--     in filters.

-- Q8. Which partition column would you choose for a dataset of orders
--     growing every day?
--
--   - The date, for example per day (day=2026-10-12/) or per month.
--   - New orders are written in a new partition, without rewriting the
--     old ones, and a single day can be reprocessed by replacing only its
--     partition.
--   - Analyses usually filter on a time range: the other partitions are
--     skipped.
--   - Choose the granularity according to the volume: with few orders per
--     day, partition per month to avoid small files.


-- =====================================================================
-- CSV vs. Parquet at scale
-- =====================================================================
-- My dataset: 252,416 orders, dates from 2020 to 2048.
--   orders.csv      29,574,123 bytes (29.6 MB)
--   orders.parquet  11,532,863 bytes (11.5 MB), 2.6x smaller
--
-- Measurements (new DuckDB process, file cache disabled):
--   CSV, sum per product            : whole file (about 28 MiB), 1.16 s
--   Parquet, sum per product        : 203.5 KiB, 4 GET, 0.31 s
--   Parquet, date >= '2100-01-01'   : 16.0 KiB, 1 GET, 0.23 s
--
-- Row groups of the date column:
--   0: 123573 rows, 2020-01-01 -> 2034-02-04
--   1: 124276 rows, 2034-02-04 -> 2048-04-10
--   2:   4567 rows, 2048-04-10 -> 2048-10-17

-- Q9. How many row groups does the file contain, and how many are skipped
--     by the filter date >= '2100-01-01'?
--
--   - My file contains 3 row groups, and all 3 are skipped.
--   - The highest stats_max is 2048-10-17, so no row group can contain a
--     date after 2100.
--   - DuckDB only downloads the footer (1 GET, 16 KiB) and reads no data.
--   - In the lab example (about 1 million orders over more than a
--     century), the last row groups go beyond 2100 and must be read.

-- Q10. The orders are sorted by date. What would happen to the efficiency
--      of the filter if they were shuffled?
--
--   - Every row group would contain dates from the whole period, so all
--     row groups would have the same min/max (about 2020 and 2048).
--   - For a filter inside this period (e.g. date >= '2030-01-01'), no row
--     group could be skipped: the whole column would be read.
--   - Min/max statistics only help when the data is sorted or clustered on
--     the filtered column. That is why data is often sorted by date before
--     being written to Parquet.

-- Q11. Compare the execution time of the CSV and Parquet queries. Which part
--      of the difference is due to the network, which part to the parsing
--      of the CSV file?
--
--   - Network: the CSV query downloads the whole file (about 28 MiB), the
--     Parquet query only the footer and 2 column chunks (203.5 KiB): more
--     than 100x less data.
--   - Parsing: CSV is text. DuckDB must split each line, handle the quotes
--     and convert every value (text -> timestamp, text -> integer).
--     Parquet stores typed binary values: nothing to convert.
--   - To separate the two: run the same query on a local copy of the CSV.
--     The remaining time is the parsing; the difference with 1.16 s is the
--     network.
--   - Here the S3 server is close and fast: on a loaded network, the
--     network part grows and the gap between CSV and Parquet widens.