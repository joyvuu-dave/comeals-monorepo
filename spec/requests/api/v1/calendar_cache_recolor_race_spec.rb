# frozen_string_literal: true

require 'rails_helper'

# Deleting a rotation recolors the ones after it (Rotation.recolor_community)
# with update_column: no callback, no updated_at bump. The destroy then
# deletes the recolored months' cache entries by hand (LiveUpdate.calendar).
# A delete cannot close the mid-build window (calendar_cache_race_spec.rb):
# a request already building one of those months stores the old color after
# the delete, and because the month's version did not change — the version
# is row count and max updated_at, and update_column moves neither — every
# later reader gets the stale copy for up to an hour.
RSpec.describe 'the calendar cache after a recolor that lands mid-build' do
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

  def june_color
    get "/api/v1/communities/#{community.id}/calendar/2027-06-15", params: { token: token }
    expect(response).to have_http_status(:ok)
    response.parsed_body['rotations'].sole['color']
  end

  it 'does not keep serving the old color of a rotation recolored by a delete in another month' do
    second = create(:rotation, community: community)
    create(:meal, community: community, rotation: second, date: Date.new(2027, 6, 10))
    last = create(:rotation, community: community)
    create(:meal, community: community, rotation: last, date: Date.new(2027, 7, 20))
    # Only the last, untouched rotation may be deleted. The recolor after a
    # delete puts every remaining rotation back on the cycle, so give the
    # June one a color off the cycle: the delete will change it.
    old_color = 'off-cycle'
    second.update_column(:color, old_color)
    landed = false

    allow(CalendarSerializer).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      serializer = original.call(*args, **kwargs)
      allow(serializer).to receive(:to_h).and_wrap_original do |to_h|
        data = to_h.call
        unless landed
          landed = true
          last.destroy!
        end
        data
      end
      serializer
    end

    expect(june_color).to eq(old_color) # read the rows before the recolor: right not to show it
    expect(second.reload.color).not_to eq(old_color) # the delete did recolor it

    expect(june_color).to eq(second.color)
  end
end
