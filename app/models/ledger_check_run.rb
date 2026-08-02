# frozen_string_literal: true

# One night's record of the ledger check. See LedgerVerification for the
# check itself, and docs/money-path-observability.md for why the record
# exists at all.
class LedgerCheckRun < ApplicationRecord
  # Ransack allowlist for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id started_at finished_at reconciliations_checked mismatch_count error created_at updated_at]
  end

  scope :recent, -> { order(started_at: :desc) }

  validates :started_at, :finished_at, presence: true
  validates :reconciliations_checked, :mismatch_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Append-only. The database trigger in 20260731130000 is the backstop; this
  # is the readable half, and the reason is the same as for a settled
  # balance — a record that can be edited afterwards is not evidence.
  before_update :reject_update
  before_destroy :reject_destroy, prepend: true

  def reject_update
    errors.add(:base, 'A ledger check run records what was true at a point in time and cannot be modified.')
    throw(:abort)
  end

  def reject_destroy
    errors.add(:base, 'A ledger check run records what was true at a point in time and cannot be destroyed.')
    throw(:abort)
  end

  # There are three outcomes, not two. A run that could not finish tells you
  # nothing about the books, which is different from a run that finished and
  # found them right.
  def passed?
    error.nil? && mismatch_count.zero?
  end

  def failed?
    error.nil? && mismatch_count.positive?
  end

  def errored?
    error.present?
  end

  def duration
    finished_at - started_at
  end
end
