# frozen_string_literal: true

require 'rails_helper'

# The calendar month is cached for an hour under a version read from the
# rows (Community#calendar_cache_version). A deploy changes the code that
# builds the month, not the rows. bin/deploy clears the whole cache, but
# the Deploy workflow and the Rollback workflow do not. So without the
# release in the version, a month the old code built was served for up to
# an hour after a release whose code builds it differently.
#
# Heroku's Dyno Metadata sets HEROKU_RELEASE_VERSION ("v42") on every
# dyno, and every release (a deploy, a rollback, a config change) gets a
# new one.
RSpec.describe 'the calendar after a release' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  def with_release(version)
    before = ENV.fetch('HEROKU_RELEASE_VERSION', nil)
    ENV['HEROKU_RELEASE_VERSION'] = version
    yield
  ensure
    ENV['HEROKU_RELEASE_VERSION'] = before
  end

  def april
    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    response.parsed_body
  end

  it 'builds the month again with the new code, though no row changed' do
    create(:meal, community: community, date: Date.new(2026, 4, 10))

    old_month = with_release('v100') { april }
    expect(old_month).not_to have_key('built_by')

    # The next release's code adds a field to the month. Nothing writes.
    allow(CalendarSerializer).to receive(:new).and_wrap_original do |original, *args, **options|
      serializer = original.call(*args, **options)
      allow(serializer).to(receive(:to_h).and_wrap_original { |to_h| to_h.call.merge(built_by: 'v101') })
      serializer
    end

    new_month = with_release('v101') { april }
    expect(new_month).to include('built_by' => 'v101')
  end

  it 'still serves the stored month within one release' do
    create(:meal, community: community, date: Date.new(2026, 4, 10))
    with_release('v100') { april }
    allow(CalendarSerializer).to receive(:new).and_call_original

    with_release('v100') { april }

    expect(CalendarSerializer).not_to have_received(:new)
  end
end
