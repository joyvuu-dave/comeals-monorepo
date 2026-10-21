# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: browser_counts
#
#  id         :bigint           not null, primary key
#  browser    :string           not null
#  count      :integer          not null
#  date       :date             not null
#  device     :string           not null
#  major      :integer
#  os         :string           not null
#  result     :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_browser_counts_on_the_count_key  (date, browser, COALESCE(major, 0), os, device, result) UNIQUE
#
# Page loads per day and kind of browser, and whether the browser check
# in index.html passed (app/frontend/browser_check.js). BrowserReportJob
# adds one for each report the check sends, so a page load is counted
# when its report arrives: a browser that runs no script at all, and a
# page restored from the browser's back-and-forward cache, send none.
#
# Counts only: no IP address, no resident, and no User-Agent string. The
# names come from BrowserDescription, which says why there is no OS
# version.
#
# The admin Browsers page reads it (app/admin/browsers.rb).
class BrowserCount < ApplicationRecord
  extend T::Sig

  # The columns that name a row. add_one! adds to the row with these
  # values, or starts one.
  KEY = %i[date browser major os device result].freeze

  DEVICES = %w[phone tablet desktop unknown].freeze
  MAX_NAME = 60

  validates :date, presence: true
  validates :browser, :os, presence: true, length: { maximum: MAX_NAME }
  validates :major, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :device, inclusion: { in: DEVICES }
  validates :result, inclusion: { in: BrowserReport::RESULTS }
  validates :count, numericality: { only_integer: true, greater_than: 0 }

  # Adds one page load, in one statement. The conflict target is the
  # unique index's own expression, COALESCE(major, 0), so a browser with
  # no version adds to one row too (the migration says why).
  #
  # At SERIALIZABLE, two of these on the same row at the same moment end
  # with the second refused (spec/db/browser_counts_spec.rb), so a caller
  # retries: BrowserReportJob runs this in RetryOnConflict.
  sig do
    params(date: Date, browser: String, major: T.nilable(Integer), os: String, device: String,
           result: String).void
  end
  def self.add_one!(date:, browser:, major:, os:, device:, result:) # rubocop:disable Metrics/ParameterLists -- one per key column
    new(date:, browser:, major:, os:, device:, result:, count: 1).validate!
    connection.execute(sanitize_sql_array([<<~SQL.squish, date, browser, major, os, device, result]))
      INSERT INTO browser_counts (date, browser, major, os, device, result, count, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 1, now(), now())
      ON CONFLICT (date, browser, (COALESCE(major, 0)), os, device, result)
      DO UPDATE SET count = browser_counts.count + 1, updated_at = now()
    SQL
  end

  # The page loads of each kind of browser over each month: newest month
  # first, and in a month, most page loads first. Each row has month,
  # browser, major, os, device, result and loads.
  sig { returns(ActiveRecord::Relation) }
  def self.by_month
    month = Arel.sql("date_trunc('month', date)::date")
    select(month.as('month'), :browser, :major, :os, :device, :result, Arel.sql('sum(count)').as('loads'))
      .group(month, :browser, :major, :os, :device, :result)
      .order(Arel.sql('month DESC, loads DESC, browser, major DESC NULLS LAST, os, device, result'))
  end
end
