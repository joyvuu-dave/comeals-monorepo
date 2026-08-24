# frozen_string_literal: true

# One row per run of a recurring job: when it started and finished, whether
# it worked, and the error if not. Written by RecurringJob around every
# perform, so "did the balances run last night" is a query. Append-only:
# the job_runs_protect trigger refuses update and delete, the same way
# ledger_check_runs works.
class JobRun < ApplicationRecord
  OUTCOMES = %w[ok failed].freeze

  validates :name, :started_at, :finished_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :succeeded, -> { where(outcome: 'ok') }

  def self.ransackable_attributes(_auth_object = nil)
    %w[id name started_at finished_at outcome created_at]
  end

  # When this job last finished without error, or nil if it never has.
  def self.last_success_at(name)
    succeeded.where(name: name).maximum(:finished_at)
  end

  def duration
    finished_at - started_at
  end
end
