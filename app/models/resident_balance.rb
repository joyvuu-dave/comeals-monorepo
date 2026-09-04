# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: resident_balances
#
#  id          :bigint           not null, primary key
#  amount      :decimal(16, 8)   default(0.0), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_resident_balances_on_resident_id  (resident_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (resident_id => residents.id)
#
# A resident's running balance across the unreconciled meals, refreshed daily
# by billing:recalculate. A cache, never the source of truth — it can be
# rebuilt from bills and attendance at any time.
#
# SIGN CONVENTION — `amount` is signed the way MealLedger signs everything
# (see its "Signs" section):
#
#   positive  =>  the community owes this resident money  ("is owed")
#   negative  =>  this resident owes the community money   ("owes")
#
# Never show this sign to a person. Screens render balances through
# BalanceDisplayHelper#balance_tag, which turns the sign into those words.
class ResidentBalance < ApplicationRecord
  belongs_to :resident

  validates :amount, numericality: true
  validates :resident_id, uniqueness: true
end
