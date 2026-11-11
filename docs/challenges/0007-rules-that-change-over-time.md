---
id: 7
title: Pricing rules that change over time
area: money
status: open
opened: 2026-11-07
reviewed: 2026-11-11
watches:
  - app/models/community.rb
  - app/models/meal_resident.rb
---

# Pricing rules that change over time

## The challenge

When the community changes a pricing rule, each dinner keeps the rule that was in force on its own date.

## The case that breaks it

1. The community raises the age for full price from 12 to 13, starting March 1.
2. An admin changes the setting on February 20.
3. On February 21, a parent signs up their 12-year-old for a February 25 dinner. The child is charged half price, by the new rule, though that dinner is before March 1.

## Where we stand

- The price ages are two community settings, `free_below_age` and `full_price_age`, with no date (`Community#multiplier_for_age` in `app/models/community.rb`).
- A sign-up copies its price into `meal_residents.multiplier` when it is made (`MealResident#set_multiplier` in `app/models/meal_resident.rb`). So a change never reaches a sign-up already made, and settled dinners cannot change.
- The cost cap is copied to each meal when the meal is created (`Meal#set_cap`), so the same holds for the cap.
- The gap: a sign-up made after a change, for a dinner dated before the change, uses the new rule.

## Options

1. **Rules with a start date.** A table of price rules, each with the date it starts. A sign-up uses the rule in force on the dinner's date. Changing a rule means adding a row, never editing one.
2. **Refuse the change while unsettled dinners are dated after it would apply.** Simpler, but it blocks the admin.
3. Leave it, and tell admins to change a rule only on the day it starts.

## History

- 2026-11-07: Opened.
