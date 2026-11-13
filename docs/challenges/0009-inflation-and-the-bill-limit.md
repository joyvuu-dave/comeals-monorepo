---
id: 9
title: Inflation and the limit on one bill
area: money
status: open
opened: 2026-11-07
reviewed: 2026-11-13
watches:
  - app/models/bill.rb
---

# Inflation and the limit on one bill

## The challenge

The app keeps working when prices rise for decades.

## The case that breaks it

At 3% inflation a year, prices are about 10 times higher after 80 years. A dinner for 40 people that costs $300 today would cost about $3,000 then, and a big holiday dinner could pass $9,999.99. The cook cannot enter the cost, and the dinner cannot be settled as it happened.

## Where we stand

- One bill is capped at $9,999.99 by the model (`app/models/bill.rb`) and by its DECIMAL(12,8) column, which holds 4 digits before the point.
- Sums (charges, balances) are DECIMAL(16,8), so they hold up to about $99,999,999.
- The community cost cap has the same $9,999.99 limit (`app/models/community.rb`).

## Options

1. Widen the input columns when needed. A migration from DECIMAL(12,8) to DECIMAL(16,8) is cheap, and the code has one constant to change.
2. Store money as whole units of 10^-8 dollars in `bigint` columns (also wanted by challenge 3). That holds about $92 billion, enough for any dinner for a very long time.
3. Make the limit a community setting, so an admin can raise it without a deploy.

## History

- 2026-11-07: Opened.
