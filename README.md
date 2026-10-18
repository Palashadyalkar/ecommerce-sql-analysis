# E-commerce Sales Analysis with SQL (Olist, Brazil)

This is a SQL project built on the Olist Brazilian e-commerce dataset, a real marketplace dataset with close to 100,000 orders. I set up the database, cleaned the raw data, and wrote 15 business questions covering delivery performance, revenue, payments, customers, and product categories, all in PostgreSQL.

## Tools used
PostgreSQL, pgAdmin, SQL

## The problem

Olist connects small Brazilian sellers to a single marketplace. The raw data they publish is scattered across multiple tables and has real-world quality issues baked in. Before any business question can be trusted, the data needs a proper relational structure and a cleanup pass. This project answers two kinds of questions: is the data reliable enough to analyse, and once it is, what is actually going on with delivery, revenue, payments, and customer behaviour.

## Files in this repository

| File | What it is |
|---|---|
| `ecommerce_analysis.sql` | Database setup, all cleaning steps, and all 15 business questions with their queries |
| `data/` | The raw Olist CSV files used as the source |

## About the dataset

Seven raw files were used, joined into seven PostgreSQL tables:

| Table | What it holds |
|---|---|
| customers | One row per customer per order, with location |
| orders | Order status and the full timeline (purchase, approval, carrier handoff, delivery, estimated delivery) |
| order_items | Line items in each order: product, seller, price, freight |
| products | Product details and category (in Portuguese) |
| category_translation | Portuguese to English category name mapping |
| payments | Payment type, installments, and value per order |
| reviews | Customer review score and comment per order |

Row counts after cleaning: customers 99,441, orders 99,441, order_items 112,650, products 32,951, category_translation 74, payments 103,877, reviews 99,224.

## Data cleaning

All cleaning was done directly in SQL, after loading the raw CSVs into PostgreSQL (no Python was used for this project). The full set of checks and fixes is in `ecommerce_analysis.sql`.

- **Reviews had duplicate review_id values that looked like a data entry problem at first.** Importing the raw file into a table with review_id as the primary key failed outright, since 814 review_id values appeared more than once. Instead of deleting the extra rows, I checked what the duplicates actually looked like: same score, same comment, same timestamps, only the order_id was different. That meant these were not accidental duplicates, they were one review genuinely linked to more than one order. So I made review_id and order_id together the primary key, which kept every real relationship intact instead of silently losing data.
- **Payments had 9 invalid rows.** Some had a payment_value of zero or less, and a few had payment_type set to 'not_defined', meaning the payment method itself was never recorded. Both would have distorted any revenue or payment-method analysis, so these rows were removed.
- **610 products had no category at all.** Rather than deleting real products with valid names, weights, and prices just because the category field was empty, I labeled them 'unknown' so they still show up, as their own group, in any category-level report.
- **The category translation table was missing 3 Portuguese-to-English mappings**, including the 'unknown' label I created above. I added these manually so every product joins cleanly to its English category name, with zero products falling through the join.
- **Orders, order_items, and customers had no data quality issues** beyond needing their date columns cast to proper timestamps.

## How to run this project

1. Run the `CREATE DATABASE` and `CREATE TABLE` statements at the top of `ecommerce_analysis.sql`.
2. Import each raw CSV into its matching table through pgAdmin's Import/Export tool (format csv, header on, encoding UTF8), in this order so foreign keys don't fail: customers, category_translation, products, orders, order_items, payments, reviews.
3. Run the cleaning section of the script.
4. Run the 15 business questions in the script, in any order.

## What the 15 questions cover

Delivery performance, revenue and its monthly trend, top-performing product categories and states, payment behaviour, repeat vs one-time customers, review scores by category, freight cost relative to product price, order cancellations over time, and top sellers.

## SQL concepts used

Multi-table JOINs across all 7 tables, CTEs, window functions (RANK, SUM OVER), CASE WHEN for bucketing, date arithmetic with EXTRACT, DATE_TRUNC for monthly trends, GROUP BY with HAVING, and NULL-safe LEFT JOINs to check referential coverage.

Example, ranking the top 3 product categories by revenue inside every month:

```sql
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
```

## Key findings

**Delivery**
- 8.1% of delivered orders (7,826 out of 96,478) arrived after the estimated delivery date.
- Late deliveries hurt review scores badly: on-time orders average a 4.29 review score, late orders drop to 2.57.
- The average time from purchase to delivery is 12 days.
- Delivery is far slower in Brazil's remote northern states: Roraima (29 days) and Amapá (27 days) take more than double the delivery time of the fastest states, which matches their distance from the main logistics hubs in the south.

**Revenue and categories**
- Revenue grew consistently from early 2017 through mid-2018, in step with order volume, which points to growth coming from acquiring new customers rather than from existing customers spending more (see Customers below).
- Health & beauty, watches & gifts, and bed, bath & table are the top three categories by revenue. Watches & gifts stands out: it sells far fewer items than bed, bath & table (5,859 vs 10,953) but earns almost as much revenue, meaning its items are priced much higher on average.
- The same handful of categories (bed, bath & table, health & beauty, watches & gifts, computers & accessories) repeatedly show up in the monthly top 3, so revenue concentration is consistent over time, not a one-off spike.

**Customers**
- Only 3% of customers (2,801 of 93,358) are repeat buyers. 97% place exactly one order and never come back. This is the single biggest growth risk in the dataset: the business is acquiring customers, not retaining them.

**Payments**
- Credit card is the dominant payment method (76,795 payments, about 74% of all payments), followed by boleto, a common Brazilian bank-slip payment method (19,784).
- Installment counts of 8 and 10 are noticeably more common than the counts just above or below them, which likely reflects "interest-free installments" promotions that steer customers toward specific round numbers rather than organic preference.

**Product and shipping economics**
- Freight cost eats heavily into cheaper, bulkier categories. In the home_comfort_2 category, average freight is 54% of the average product price, and in flowers it is 44%. For a customer, that can make the shipping cost nearly as expensive as the item itself.
- Diapers & hygiene has both the lowest average review score (3.26) of any category with a meaningful sample size, and one of the highest freight-to-price ratios (36.6%), which is worth investigating together.

## Limitations

- "Revenue" here is the sum of item prices on delivered orders; it does not account for refunds, cancellations after delivery, or returns, since the dataset does not track those separately.
- The first and last few months in the dataset (September 2016, and September-October 2018) have only a handful of orders each, so cancellation percentages for those months are not reliable and reflect the dataset's start/end boundary rather than a real business trend.
- Seller-level analysis only includes sellers with at least 50 delivered orders, to avoid ranking by noise from very small sellers.

## About me

Palash, data analyst. Skills: SQL, Power BI, Excel, basic Python.
LinkedIn: https://linkedin.com/in/palashadyalkar
