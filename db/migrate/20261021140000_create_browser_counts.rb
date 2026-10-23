# frozen_string_literal: true

# Page loads per day, browser, major version, operating system, kind of
# device, and result of the browser check in index.html. BrowserReportJob
# adds one for each report the check sends. Counts only: no IP address,
# no resident, and no User-Agent string.
#
# major is NULL when the browser's version could not be read. A plain
# unique index treats every NULL as different, so two page loads of such
# a browser would make two rows. The unique index uses COALESCE(major, 0)
# instead, which works on every PostgreSQL version (NULLS NOT DISTINCT
# needs 15). The CHECK keeps a real version above 0, so 0 in the index
# cannot be mistaken for one. BrowserCount.add_one! names the same
# expression in its ON CONFLICT.
#
# Dated after every other migration: nothing that runs in an earlier
# migration reads this table (the data fixes of October 2026, since
# deleted, ran settlement code only).
class CreateBrowserCounts < ActiveRecord::Migration[8.1]
  def change
    create_table :browser_counts do |t|
      t.date :date, null: false
      t.string :browser, null: false
      t.integer :major
      t.string :os, null: false
      t.string :device, null: false
      t.string :result, null: false
      t.integer :count, null: false
      t.timestamps
    end

    add_check_constraint :browser_counts, "device IN ('phone', 'tablet', 'desktop', 'unknown')",
                         name: 'browser_counts_device_is_known'
    add_check_constraint :browser_counts, "result IN ('passed', 'failed', 'error')",
                         name: 'browser_counts_result_is_known'
    add_check_constraint :browser_counts, 'count > 0', name: 'browser_counts_count_is_positive'
    add_check_constraint :browser_counts, 'major IS NULL OR major > 0', name: 'browser_counts_major_is_positive'
    add_check_constraint :browser_counts, 'char_length(browser) BETWEEN 1 AND 60',
                         name: 'browser_counts_browser_length'
    add_check_constraint :browser_counts, 'char_length(os) BETWEEN 1 AND 60', name: 'browser_counts_os_length'

    add_index :browser_counts, 'date, browser, (COALESCE(major, 0)), os, device, result',
              unique: true, name: 'index_browser_counts_on_the_count_key'
  end
end
