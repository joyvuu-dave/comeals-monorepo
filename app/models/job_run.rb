# typed: true
# frozen_string_literal: true

# One row per run of a recurring job: when it started and finished, whether
# it worked, and the error if not. Written by RecurringJob around every
# perform, so "did the balances run last night" is a query. Append-only:
# the job_runs_protect trigger refuses update and delete, the same way
# ledger_check_runs works.
# == Schema Information
#
# Table name: job_runs
#
#  id          :bigint           not null, primary key
#  details     :jsonb            not null
#  error       :text
#  finished_at :datetime         not null
#  name        :string           not null
#  outcome     :string           not null
#  started_at  :datetime         not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_job_runs_on_name_and_finished_at  (name,finished_at)
#
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
    T.must(finished_at) - T.must(started_at)
  end
end
