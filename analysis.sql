-- =========================================================
-- E-commerce Product & Customer Analytics
-- Dataset: GA4 Public E-commerce Sample
-- Tool: BigQuery SQL
-- =========================================================


-- 1. Data Exploration
-- Explore dataset size and the distribution of event types

-- Basic dataset overview
SELECT
  COUNT(*) AS event_count,
  COUNT(DISTINCT user_pseudo_id) AS user_count,
  COUNT(DISTINCT event_date) AS day_count
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`;

-- Event distribution
SELECT
  event_name,
  COUNT(*) AS event_count
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
GROUP BY
  event_name
ORDER BY
  event_count DESC;


-- 2. Core KPIs
-- Calculate Purchases, Revenue, Average Order Value, and session-level Purchase Conversion Rate

-- Purchases, Revenue, and Average Order Value
SELECT
  COUNTIF(event_name = 'purchase') AS purchases,
  SUM(ecommerce.purchase_revenue) AS revenue,
  SAFE_DIVIDE(
    SUM(ecommerce.purchase_revenue),
    COUNTIF(event_name = 'purchase')
  ) AS average_order_value
FROM
  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`;

-- Session-level Purchase Conversion Rate
WITH events AS (
  SELECT
    CONCAT(
      user_pseudo_id,
      '_',
      CAST(
        (
          SELECT value.int_value
          FROM UNNEST(event_params)
          WHERE key = 'ga_session_id'
        ) AS STRING
      )
    ) AS session_id,
    event_name
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

sessions AS (
  SELECT
    session_id,
    COUNTIF(event_name = 'purchase') > 0 AS purchased
  FROM
    events
  WHERE
    session_id IS NOT NULL
  GROUP BY
    session_id
)

SELECT
  COUNT(*) AS total_sessions,
  COUNTIF(purchased) AS purchasing_sessions,
  SAFE_DIVIDE(
    COUNTIF(purchased),
    COUNT(*)
  ) AS purchase_conversion_rate
FROM
  sessions;


-- 3. Conversion Funnel Analysis
-- Build an ordered purchase funnel using the first occurrence of each event within a session
-- Measure stage Conversion Rates from View Item to Purchase

-- Ordered funnel using the first occurrence of each event
WITH events AS (
  SELECT
    CONCAT(
      user_pseudo_id,
      '_',
      CAST(
        (
          SELECT value.int_value
          FROM UNNEST(event_params)
          WHERE key = 'ga_session_id'
        ) AS STRING
      )
    ) AS session_id,
    event_name,
    event_timestamp
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

session_funnel AS (
  SELECT
    session_id,
    MIN(CASE WHEN event_name = 'view_item'
      THEN event_timestamp END) AS view_time,
    MIN(CASE WHEN event_name = 'add_to_cart'
      THEN event_timestamp END) AS cart_time,
    MIN(CASE WHEN event_name = 'begin_checkout'
      THEN event_timestamp END) AS checkout_time,
    MIN(CASE WHEN event_name = 'purchase'
      THEN event_timestamp END) AS purchase_time
  FROM
    events
  WHERE
    session_id IS NOT NULL
  GROUP BY
    session_id
),

funnel_counts AS (
  SELECT
    COUNTIF(view_time IS NOT NULL) AS viewed_sessions,

    COUNTIF(
      view_time IS NOT NULL
      AND cart_time > view_time
    ) AS cart_after_view_sessions,

    COUNTIF(
      view_time IS NOT NULL
      AND cart_time > view_time
      AND checkout_time > cart_time
    ) AS checkout_after_cart_sessions,

    COUNTIF(
      view_time IS NOT NULL
      AND cart_time > view_time
      AND checkout_time > cart_time
      AND purchase_time > checkout_time
    ) AS purchase_after_checkout_sessions
  FROM
    session_funnel
)

SELECT
  viewed_sessions,
  cart_after_view_sessions,
  checkout_after_cart_sessions,
  purchase_after_checkout_sessions,

  SAFE_DIVIDE(
    cart_after_view_sessions,
    viewed_sessions
  ) AS view_to_cart_rate,

  SAFE_DIVIDE(
    checkout_after_cart_sessions,
    cart_after_view_sessions
  ) AS cart_to_checkout_rate,

  SAFE_DIVIDE(
    purchase_after_checkout_sessions,
    checkout_after_cart_sessions
  ) AS checkout_to_purchase_rate,

  SAFE_DIVIDE(
    purchase_after_checkout_sessions,
    viewed_sessions
  ) AS overall_funnel_conversion_rate

FROM
  funnel_counts;


-- 4. Cohort Retention Analysis
-- Calculate exact-day D1, D7, and D30 Retention by first activity date
-- Return NULL when a cohort does not have a complete observation window

WITH user_activity AS (
  SELECT
    user_pseudo_id,
    PARSE_DATE('%Y%m%d', event_date) AS activity_date
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    user_pseudo_id IS NOT NULL
  GROUP BY
    user_pseudo_id,
    activity_date
),

first_visit AS (
  SELECT
    user_pseudo_id,
    MIN(activity_date) AS cohort_date
  FROM
    user_activity
  GROUP BY
    user_pseudo_id
),

retention AS (
  SELECT
    a.user_pseudo_id,
    f.cohort_date,
    DATE_DIFF(
      a.activity_date,
      f.cohort_date,
      DAY
    ) AS day_number
  FROM
    user_activity a
  JOIN
    first_visit f
  ON
    a.user_pseudo_id = f.user_pseudo_id
),

dataset_end AS (
  SELECT
    MAX(activity_date) AS last_date
  FROM
    user_activity
)

SELECT
  cohort_date,
  COUNT(DISTINCT user_pseudo_id) AS cohort_size,

  COUNT(DISTINCT IF(
    day_number = 1,
    user_pseudo_id,
    NULL
  )) AS d1_users,

  COUNT(DISTINCT IF(
    day_number = 7,
    user_pseudo_id,
    NULL
  )) AS d7_users,

  COUNT(DISTINCT IF(
    day_number = 30,
    user_pseudo_id,
    NULL
  )) AS d30_users,

  CASE
    WHEN DATE_ADD(cohort_date, INTERVAL 1 DAY) <= last_date
    THEN SAFE_DIVIDE(
      COUNT(DISTINCT IF(day_number = 1, user_pseudo_id, NULL)),
      COUNT(DISTINCT user_pseudo_id)
    )
    ELSE NULL
  END AS d1_retention,

  CASE
    WHEN DATE_ADD(cohort_date, INTERVAL 7 DAY) <= last_date
    THEN SAFE_DIVIDE(
      COUNT(DISTINCT IF(day_number = 7, user_pseudo_id, NULL)),
      COUNT(DISTINCT user_pseudo_id)
    )
    ELSE NULL
  END AS d7_retention,

  CASE
    WHEN DATE_ADD(cohort_date, INTERVAL 30 DAY) <= last_date
    THEN SAFE_DIVIDE(
      COUNT(DISTINCT IF(day_number = 30, user_pseudo_id, NULL)),
      COUNT(DISTINCT user_pseudo_id)
    )
    ELSE NULL
  END AS d30_retention

FROM
  retention

CROSS JOIN
  dataset_end

GROUP BY
  cohort_date,
  last_date

ORDER BY
  cohort_date;


-- 5. Customer Segmentation

-- Purchase behavior segmentation
-- Segment users into Non-purchasers, One-time Buyers, and Repeat Buyers
WITH user_purchases AS (
  SELECT
    user_pseudo_id,
    COUNTIF(event_name = 'purchase') AS purchase_count
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    user_pseudo_id IS NOT NULL
  GROUP BY
    user_pseudo_id
),

segments AS (
  SELECT
    user_pseudo_id,
    purchase_count,
    CASE
      WHEN purchase_count = 0 THEN 'Non-purchaser'
      WHEN purchase_count = 1 THEN 'One-time Buyer'
      ELSE 'Repeat Buyer'
    END AS customer_segment
  FROM
    user_purchases
)

SELECT
  customer_segment,
  COUNT(*) AS users
FROM
  segments
GROUP BY
  customer_segment
ORDER BY
  users DESC;

-- Repeat Purchase Rate
-- Calculate Repeat Purchase Rate among all buyers
WITH user_purchases AS (
  SELECT
    user_pseudo_id,
    COUNTIF(event_name = 'purchase') AS purchase_count
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    user_pseudo_id IS NOT NULL
  GROUP BY
    user_pseudo_id
),

segments AS (
  SELECT
    user_pseudo_id,
    purchase_count,
    CASE
      WHEN purchase_count = 0 THEN 'Non-purchaser'
      WHEN purchase_count = 1 THEN 'One-time Buyer'
      ELSE 'Repeat Buyer'
    END AS customer_segment
  FROM
    user_purchases
)

SELECT
  COUNTIF(customer_segment != 'Non-purchaser') AS buyers,
  COUNTIF(customer_segment = 'Repeat Buyer') AS repeat_buyers,
  SAFE_DIVIDE(
    COUNTIF(customer_segment = 'Repeat Buyer'),
    COUNTIF(customer_segment != 'Non-purchaser')
  ) AS repeat_purchase_rate
FROM
  segments;

-- Customer value segmentation
-- Segment purchasing users into Low-, Mid-, and High-value groups using revenue tertiles
WITH customer_metrics AS (
  SELECT
    user_pseudo_id,
    SUM(ecommerce.purchase_revenue) AS total_revenue
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    user_pseudo_id IS NOT NULL
    AND event_name = 'purchase'
  GROUP BY
    user_pseudo_id
),

ranked_customers AS (
  SELECT
    user_pseudo_id,
    total_revenue,
    NTILE(3) OVER (
      ORDER BY total_revenue
    ) AS revenue_group
  FROM
    customer_metrics
)

SELECT
  CASE
    WHEN revenue_group = 1 THEN 'Low-value'
    WHEN revenue_group = 2 THEN 'Mid-value'
    WHEN revenue_group = 3 THEN 'High-value'
  END AS customer_segment,

  COUNT(*) AS customers,
  AVG(total_revenue) AS avg_customer_revenue,
  SUM(total_revenue) AS total_revenue

FROM
  ranked_customers

GROUP BY
  revenue_group

ORDER BY
  revenue_group;


-- 6. Churn / Inactivity Analysis
-- Classify users as Active or Inactive using a 30-day inactivity proxy
-- This is a behavioral proxy rather than a true churn label

-- 30-day inactivity proxy
WITH user_activity AS (
  SELECT
    user_pseudo_id,
    MAX(PARSE_DATE('%Y%m%d', event_date)) AS last_activity_date
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    user_pseudo_id IS NOT NULL
  GROUP BY
    user_pseudo_id
),

dataset_end AS (
  SELECT
    MAX(PARSE_DATE('%Y%m%d', event_date)) AS last_date
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

user_status AS (
  SELECT
    u.user_pseudo_id,
    u.last_activity_date,

    DATE_DIFF(
      d.last_date,
      u.last_activity_date,
      DAY
    ) AS days_since_last_activity,

    CASE
      WHEN DATE_DIFF(
        d.last_date,
        u.last_activity_date,
        DAY
      ) > 30
      THEN 'Inactive'
      ELSE 'Active'
    END AS activity_status

  FROM
    user_activity u

  CROSS JOIN
    dataset_end d
)

SELECT
  activity_status,
  COUNT(*) AS users
FROM
  user_status
GROUP BY
  activity_status;

-- Active vs Inactive user comparison
-- Compare purchase behavior and revenue between Active and Inactive users
WITH user_metrics AS (
  SELECT
    user_pseudo_id,
    MAX(PARSE_DATE('%Y%m%d', event_date)) AS last_activity_date,
    COUNTIF(event_name = 'purchase') AS purchase_count,

    SUM(
      CASE
        WHEN event_name = 'purchase'
        THEN ecommerce.purchase_revenue
        ELSE 0
      END
    ) AS user_revenue

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

  WHERE
    user_pseudo_id IS NOT NULL

  GROUP BY
    user_pseudo_id
),

dataset_end AS (
  SELECT
    MAX(PARSE_DATE('%Y%m%d', event_date)) AS last_date
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

user_status AS (
  SELECT
    u.user_pseudo_id,
    u.purchase_count,
    u.user_revenue,

    CASE
      WHEN DATE_DIFF(
        d.last_date,
        u.last_activity_date,
        DAY
      ) > 30
      THEN 'Inactive'
      ELSE 'Active'
    END AS activity_status

  FROM
    user_metrics u

  CROSS JOIN
    dataset_end d
)

SELECT
  activity_status,
  COUNT(*) AS users,

  COUNTIF(purchase_count > 0) AS buyers,

  SAFE_DIVIDE(
    COUNTIF(purchase_count > 0),
    COUNT(*)
  ) AS purchase_rate,

  COUNTIF(purchase_count >= 2) AS repeat_buyers,

  SAFE_DIVIDE(
    COUNTIF(purchase_count >= 2),
    COUNTIF(purchase_count > 0)
  ) AS repeat_purchase_rate,

  SUM(user_revenue) AS revenue,
  AVG(user_revenue) AS avg_revenue_per_user

FROM
  user_status

GROUP BY
  activity_status;


-- 7. Monthly Revenue Trend
-- Analyze monthly Revenue and Month-over-Month Growth using LAG()

WITH monthly_revenue AS (
  SELECT
    DATE_TRUNC(
      PARSE_DATE('%Y%m%d', event_date),
      MONTH
    ) AS month,

    COUNTIF(event_name = 'purchase') AS purchases,

    SUM(
      CASE
        WHEN event_name = 'purchase'
        THEN ecommerce.purchase_revenue
        ELSE 0
      END
    ) AS revenue

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

  GROUP BY
    month
),

revenue_with_previous_month AS (
  SELECT
    month,
    purchases,
    revenue,

    LAG(revenue) OVER (
      ORDER BY
        month
    ) AS previous_month_revenue

  FROM
    monthly_revenue
)

SELECT
  month,
  purchases,
  revenue,
  previous_month_revenue,

  SAFE_DIVIDE(
    revenue - previous_month_revenue,
    previous_month_revenue
  ) AS mom_revenue_growth

FROM
  revenue_with_previous_month

ORDER BY
  month;
