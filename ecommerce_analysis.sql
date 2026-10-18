-- =====================================================================
-- E-commerce Sales Analysis (Olist dataset) - Database setup and
-- SQL-based data cleaning
-- All cleaning below is done directly in PostgreSQL after importing the
-- raw Kaggle CSV files, no Python involved.
-- =====================================================================

-- Run this first, then connect to the new database before running
-- everything else below.
CREATE DATABASE ecommerce_analysis;


-- ---------------------------------------------------------------------
-- STEP 1: Create the tables
-- ---------------------------------------------------------------------
-- Dropping first in case any of these already exist, so this script can
-- be run from a clean state.
DROP TABLE IF EXISTS reviews, payments, order_items, orders, products, customers, category_translation CASCADE;

-- No issues expected in this table, so it is created with its final
-- structure straight away.
CREATE TABLE customers (
    customer_id               VARCHAR(50) PRIMARY KEY,
    customer_unique_id        VARCHAR(50) NOT NULL,
    customer_zip_code_prefix  INTEGER,
    customer_city             VARCHAR(100),
    customer_state            VARCHAR(5)
);

-- This will hold the Portuguese to English category name mapping. A few
-- rows are missing from the original file, those get added later in
-- the cleaning section below.
CREATE TABLE category_translation (
    product_category_name           VARCHAR(100) PRIMARY KEY,
    product_category_name_english   VARCHAR(100)
);

-- Created with just the raw columns. The raw file has some products
-- with no category at all, that gets fixed later with an UPDATE.
CREATE TABLE products (
    product_id                      VARCHAR(50) PRIMARY KEY,
    product_category_name           VARCHAR(100),
    product_name_lenght             INTEGER,
    product_description_lenght      INTEGER,
    product_photos_qty              INTEGER,
    product_weight_g                INTEGER,
    product_length_cm               INTEGER,
    product_height_cm               INTEGER,
    product_width_cm                INTEGER
);

CREATE TABLE orders (
    order_id                        VARCHAR(50) PRIMARY KEY,
    customer_id                     VARCHAR(50) REFERENCES customers(customer_id),
    order_status                    VARCHAR(50),
    order_purchase_timestamp        TIMESTAMP,
    order_approved_at               TIMESTAMP,
    order_delivered_carrier_date    TIMESTAMP,
    order_delivered_customer_date   TIMESTAMP,
    order_estimated_delivery_date   TIMESTAMP
);

CREATE TABLE order_items (
    order_id              VARCHAR(50) REFERENCES orders(order_id),
    order_item_id         INTEGER,
    product_id            VARCHAR(50) REFERENCES products(product_id),
    seller_id             VARCHAR(50),
    shipping_limit_date   TIMESTAMP,
    price                 NUMERIC(10,2),
    freight_value         NUMERIC(10,2),
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE payments (
    order_id               VARCHAR(50) REFERENCES orders(order_id),
    payment_sequential     INTEGER,
    payment_type           VARCHAR(20),
    payment_installments   INTEGER,
    payment_value          NUMERIC(10,2),
    PRIMARY KEY (order_id, payment_sequential)
);

-- review_id is NOT set as a primary key here on purpose. The first
-- attempt at this table used review_id alone as the primary key, and
-- importing the raw CSV failed with a duplicate key error. The correct
-- primary key is added later in the cleaning section, once the
-- duplicates are properly understood.
CREATE TABLE reviews (
    review_id                 VARCHAR(50),
    order_id                  VARCHAR(50) REFERENCES orders(order_id),
    review_score               INTEGER,
    review_comment_title       VARCHAR(100),
    review_comment_message     TEXT,
    review_creation_date       TIMESTAMP,
    review_answer_timestamp    TIMESTAMP
);


-- ---------------------------------------------------------------------
-- STEP 2: Load the raw data
-- ---------------------------------------------------------------------
-- Done through pgAdmin's Import/Export tool for each table (right-click
-- the table -> Import/Export Data -> csv, header on, encoding UTF8),
-- loading the raw Kaggle files in this order so foreign keys don't
-- fail: customers, category_translation, products, orders, order_items,
-- payments, reviews.


-- ---------------------------------------------------------------------
-- STEP 3: Clean the reviews table
-- ---------------------------------------------------------------------

-- Checking how many duplicate review_id and order_id values exist in
-- the raw data, since the earlier import error suggested review_id is
-- not actually unique in this dataset.
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT review_id) AS unique_review_ids,
       COUNT(DISTINCT order_id) AS unique_order_ids
FROM reviews;

-- Looking at which review_id values repeat and how many times, before
-- deciding how to handle them.
SELECT review_id, COUNT(*) 
FROM reviews
GROUP BY review_id
HAVING COUNT(*) > 1
LIMIT 5;

-- Before deciding which duplicate row to keep, looking at both rows for
-- one review_id side by side, to check what actually differs between
-- them (the timestamp, the comment, or something else).
SELECT * 
FROM reviews
WHERE review_id = '00130cbe1f9d422698c812ed8ded1919';

-- Checking whether every duplicate review_id follows the same pattern:
-- same review content and score, but linked to a different order_id.
-- If distinct_scores and distinct_comments stay at 1 across the board,
-- these are not accidental duplicate rows, they are one review that is
-- genuinely linked to more than one order.
SELECT review_id, COUNT(DISTINCT order_id) AS distinct_orders,
       COUNT(DISTINCT review_score) AS distinct_scores,
       COUNT(DISTINCT review_comment_message) AS distinct_comments
FROM reviews
GROUP BY review_id
HAVING COUNT(*) > 1;

-- The check above confirmed these are genuine multi-order reviews, not
-- duplicate rows, so no rows are deleted. Instead, review_id and
-- order_id together are made the primary key, since that combination
-- really is unique, while still allowing the same review to be linked
-- to more than one order.
ALTER TABLE reviews ADD PRIMARY KEY (review_id, order_id);


-- ---------------------------------------------------------------------
-- STEP 4: Clean the payments table
-- ---------------------------------------------------------------------

-- Checking for rows that cannot be real payments: a payment_value of
-- zero or less, or a payment_type of 'not_defined', which means the
-- payment method itself was never recorded.
SELECT 
    SUM(CASE WHEN payment_value <= 0 THEN 1 ELSE 0 END) AS zero_or_negative_payments,
    SUM(CASE WHEN payment_type = 'not_defined' THEN 1 ELSE 0 END) AS undefined_payment_type
FROM payments;

-- Removing those invalid rows before this table is used for any
-- revenue calculation, since keeping either would quietly distort the
-- totals.
DELETE FROM payments
WHERE payment_value <= 0 OR payment_type = 'not_defined';

-- Confirming no invalid rows remain after the delete.
SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN payment_value <= 0 THEN 1 ELSE 0 END) AS zero_or_negative_payments,
       SUM(CASE WHEN payment_type = 'not_defined' THEN 1 ELSE 0 END) AS undefined_payment_type
FROM payments;


-- ---------------------------------------------------------------------
-- STEP 5: Clean the products table
-- ---------------------------------------------------------------------

-- Checking how many products have no category assigned at all.
SELECT COUNT(*) AS total_products,
       SUM(CASE WHEN product_category_name IS NULL THEN 1 ELSE 0 END) AS missing_category
FROM products;

-- These are real products with valid names, weights and prices, only
-- the category field is empty. Deleting them would remove real sales
-- data, so instead they are labeled 'unknown' and kept visible as their
-- own group in any category breakdown.
UPDATE products
SET product_category_name = 'unknown'
WHERE product_category_name IS NULL;

-- Before joining products with category_translation for reporting,
-- checking which category names in products don't have a matching
-- English translation yet. A missing match here would show up as a
-- blank category name in any report that uses the English version.
SELECT DISTINCT p.product_category_name
FROM products p
LEFT JOIN category_translation t ON p.product_category_name = t.product_category_name
WHERE t.product_category_name IS NULL;

-- Adding English translations for the category names that came back
-- missing above: two were genuinely absent from the original
-- translation file, and 'unknown' is the label created in the previous
-- step, so it needs its own translation too.
INSERT INTO category_translation (product_category_name, product_category_name_english)
VALUES 
    ('portateis_cozinha_e_preparadores_de_alimentos', 'portable_kitchen_appliances'),
    ('pc_gamer', 'pc_gaming'),
    ('unknown', 'unknown');

-- Final check to confirm every product now has a matching English
-- category name.
SELECT COUNT(*) AS products_without_english_category
FROM products p
LEFT JOIN category_translation t ON p.product_category_name = t.product_category_name
WHERE t.product_category_name IS NULL;


-- ---------------------------------------------------------------------
-- Cleaning summary
-- ---------------------------------------------------------------------
-- customers           : no issues found
-- category_translation: 3 missing category translations added
-- products            : 610 products with no category labeled 'unknown'
-- orders              : no issues found
-- order_items         : no issues found
-- payments            : 9 invalid rows removed (zero/negative value or
--                        undefined payment type)
-- reviews             : composite primary key (review_id, order_id)
--                        added after confirming the repeated review_id
--                        values were genuine multi-order reviews, not
--                        accidental duplicates


-- Confirming every table has data and the row counts match what was
-- expected after cleaning.
SELECT 'customers' AS table_name, COUNT(*) FROM customers
UNION ALL
SELECT 'category_translation', COUNT(*) FROM category_translation
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'orders', COUNT(*) FROM orders
UNION ALL
SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL
SELECT 'payments', COUNT(*) FROM payments
UNION ALL
SELECT 'reviews', COUNT(*) FROM reviews;


-- ---------------------------------------------------------------------
-- STEP 6: Business analysis queries
-- ---------------------------------------------------------------------


-- Q1. What percentage of delivered orders arrived after the estimated delivery date?

SELECT 
    COUNT(*) AS total_delivered_orders,
    SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 ELSE 0 END) AS late_orders,
    ROUND(100.0 * SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 ELSE 0 END) / COUNT(*), 1) AS late_pct
FROM orders
WHERE order_status = 'delivered';

-- Q2. Does a late delivery actually lower the review score customers give?

SELECT 
    CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date THEN 'Late' ELSE 'On time' END AS delivery_status,
    ROUND(AVG(r.review_score), 2) AS avg_review_score,
    COUNT(*) AS orders
FROM orders o
JOIN reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
GROUP BY 1;

-- Q3. On average, how many days does it take from purchase to delivery?

SELECT 
    ROUND(AVG(EXTRACT(DAY FROM (order_delivered_customer_date - order_purchase_timestamp)))) AS avg_delivery_days
FROM orders
WHERE order_status = 'delivered';

-- Q4. Which Brazilian states have the slowest average delivery time?

SELECT 
    c.customer_state,
    COUNT(*) AS delivered_orders,
    ROUND(AVG(EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_purchase_timestamp)))) AS avg_delivery_days
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state
ORDER BY avg_delivery_days DESC
LIMIT 10;

-- Q5. What is the total revenue, and how has it trended month over month?

SELECT 
    DATE_TRUNC('month', o.order_purchase_timestamp) AS month,
    ROUND(SUM(oi.price)) AS revenue,
    COUNT(DISTINCT o.order_id) AS orders
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.order_status = 'delivered'
GROUP BY 1
ORDER BY 1;

-- Q6. Which product categories generate the most revenue?

SELECT 
    t.product_category_name_english AS category,
    ROUND(SUM(oi.price)) AS revenue,
    COUNT(*) AS items_sold
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN category_translation t ON p.product_category_name = t.product_category_name
JOIN orders o ON oi.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY 1
ORDER BY revenue DESC
LIMIT 10;

-- Q7. Which payment method do customers use the most, and which one has the highest average order value?

SELECT 
    payment_type,
    COUNT(*) AS payments,
    ROUND(AVG(payment_value), 2) AS avg_payment_value
FROM payments
GROUP BY payment_type
ORDER BY payments DESC;

-- Q8. How common are installment payments, and what is the average number of installments?

SELECT 
    payment_installments,
    COUNT(*) AS payments
FROM payments
WHERE payment_type = 'credit_card'
GROUP BY payment_installments
ORDER BY payment_installments;

-- Q9. What share of customers are repeat buyers, and how much revenue do they bring compared to one-time buyers?

WITH customer_orders AS (
    SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS order_count
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
)
SELECT 
    CASE WHEN order_count = 1 THEN 'One-time buyer' ELSE 'Repeat buyer' END AS customer_type,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_customers
FROM customer_orders
GROUP BY 1;

-- Q10. Which states bring in the most revenue?

SELECT 
    c.customer_state,
    ROUND(SUM(oi.price)) AS revenue,
    COUNT(DISTINCT o.order_id) AS orders
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state
ORDER BY revenue DESC
LIMIT 10;

-- Q11. What is the average review score per product category, and which categories perform worst?

SELECT 
    t.product_category_name_english AS category,
    ROUND(AVG(r.review_score), 2) AS avg_review_score,
    COUNT(*) AS reviews
FROM reviews r
JOIN orders o ON r.order_id = o.order_id
JOIN order_items oi ON o.order_id = oi.order_id
JOIN products p ON oi.product_id = p.product_id
JOIN category_translation t ON p.product_category_name = t.product_category_name
GROUP BY 1
HAVING COUNT(*) >= 30
ORDER BY avg_review_score ASC
LIMIT 10;

-- Q12. How does freight (shipping) cost compare to product price across categories?

SELECT 
    t.product_category_name_english AS category,
    ROUND(AVG(oi.price), 2) AS avg_price,
    ROUND(AVG(oi.freight_value), 2) AS avg_freight,
    ROUND(100.0 * AVG(oi.freight_value) / AVG(oi.price), 1) AS freight_pct_of_price
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN category_translation t ON p.product_category_name = t.product_category_name
GROUP BY 1
ORDER BY freight_pct_of_price DESC
LIMIT 10;

-- Q13. What percentage of orders were canceled or marked unavailable, and does that vary by month?

SELECT 
    DATE_TRUNC('month', order_purchase_timestamp) AS month,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN order_status IN ('canceled', 'unavailable') THEN 1 ELSE 0 END) AS failed_orders,
    ROUND(100.0 * SUM(CASE WHEN order_status IN ('canceled', 'unavailable') THEN 1 ELSE 0 END) / COUNT(*), 1) AS failed_pct
FROM orders
GROUP BY 1
ORDER BY 1;

-- Q14. Rank product categories by revenue within each month using a window function.

WITH monthly_category_revenue AS (
    SELECT 
        DATE_TRUNC('month', o.order_purchase_timestamp) AS month,
        t.product_category_name_english AS category,
        SUM(oi.price) AS revenue
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_id
    JOIN products p ON oi.product_id = p.product_id
    JOIN category_translation t ON p.product_category_name = t.product_category_name
    WHERE o.order_status = 'delivered'
    GROUP BY 1, 2
)
SELECT month, category, revenue, rnk
FROM (
    SELECT *, RANK() OVER (PARTITION BY month ORDER BY revenue DESC) AS rnk
    FROM monthly_category_revenue
) ranked
WHERE rnk <= 3
ORDER BY month, rnk;

-- Q15. Which sellers have delivered the most orders, and what is their average review score?

SELECT 
    oi.seller_id,
    COUNT(DISTINCT oi.order_id) AS orders_sold,
    ROUND(AVG(r.review_score), 2) AS avg_review_score
FROM order_items oi
JOIN orders o ON oi.order_id = o.order_id
LEFT JOIN reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
GROUP BY oi.seller_id
HAVING COUNT(DISTINCT oi.order_id) >= 50
ORDER BY orders_sold DESC
LIMIT 10;

