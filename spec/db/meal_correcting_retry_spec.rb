# frozen_string_literal: true

require 'rails_helper'

# Two admins correct the same settled dinner at the same moment (ADR 0011
# rule 6). The first correction holds the dinner's lock while it saves.
# The second waits at its FOR UPDATE on the dinner until the first
# commits. Its transaction began before that commit, and the first
# correction changed the dinner's row (a write to a dinner's rows updates
# it, through the trigger of 20261016120000), so PostgreSQL refuses the
# second's lock as a conflict. RetryOnConflict runs the second again, and
# it works from the dinner as the first correction left it.
RSpec.describe 'a correction while another correction of the same dinner is saved' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater') }
  let(:other) { create(:resident, community: community, unit: unit, name: 'Other') }

  # A $30 dinner with one cook and one eater, settled.
  let!(:meal) do
    create(:meal, community: community, date: latest).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
      settle!(cutoff: latest)
    end
  end

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # Waits until another session is blocked on a lock while running a
  # statement that contains `sql_fragment`.
  def wait_for_blocked_session(observer, sql_fragment)
    200.times do
      blocked = observer.exec_params(
        'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
        "AND pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE $1",
        ["%#{sql_fragment}%"]
      ).getvalue(0, 0).to_i.positive?
      return true if blocked

      sleep 0.02
    end
    false
  end

  def on_a_thread(&)
    Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection(&)
    end
  end

  # The first correction, $30 to $20. It stops after its edit, with the
  # dinner's lock held, until `release` is given a value.
  def first_correction(edited, release)
    on_a_thread do
      MealCorrecting.save!(Meal.find(meal.id), by: admin, reason: 'Typed $30 for $20') do |edits|
        edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
        edited << true
        release.pop
      end
    end
  end

  # Runs the second correction (or its preview) while the first holds the
  # lock, lets the first commit, and gives back what the second returned.
  def second_while_the_first_saves
    observer = open_session
    edited = Queue.new
    go = Queue.new
    first = first_correction(edited, go)
    edited.pop
    second = on_a_thread { yield Meal.find(meal.id) }
    expect(wait_for_blocked_session(observer, 'FOR UPDATE')).to be(true)
    go << true
    first.value
    second.value
  ensure
    go&.push(true)
    observer&.close
  end

  before do
    # Made before the threads start, on this thread's connection.
    [admin, other]
    allow(Rails.error).to receive(:report).and_call_original
  end

  # The second correction's first try was refused, and its second try
  # worked.
  def expect_one_retry
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(ActiveRecord::SerializationFailure), hash_including(handled: true)).once
  end

  # After the first correction the dinner costs $20. Other joins the
  # eater, so each is charged $10, not $15.
  it 'saves the second correction from the dinner as the first left it' do
    correction = second_while_the_first_saves do |dinner|
      MealCorrecting.save!(dinner, by: admin, reason: 'Other ate too') { |edits| edits.add_eater(other) }
    end

    expect(correction.lines.pluck(:resident_id, :amount).to_h)
      .to eq(eater.id => BigDecimal('10'), other.id => BigDecimal('-10'))
    expect(MealCorrection.count).to eq(2)
    expect_one_retry
  end

  it 'previews the second correction from the dinner as the first left it' do
    result = second_while_the_first_saves do |dinner|
      MealCorrecting.preview(dinner) { |edits| edits.add_eater(other) }
    end

    expect(result.changes).to eq(eater.id => BigDecimal('10'), other.id => BigDecimal('-10'))
    expect(MealCorrection.count).to eq(1)
    expect_one_retry
  end
end
