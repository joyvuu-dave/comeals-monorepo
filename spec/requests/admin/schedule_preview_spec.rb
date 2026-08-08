# frozen_string_literal: true

require 'rails_helper'

# The live preview under the schedule grid (app/admin/community.rb,
# collection_action :schedule_preview). It is a hand-written admin action, so
# it must call authorize! itself — the examples below pin that a plain admin
# and a read-only token are refused, which is exactly what silently breaks if
# that line is ever dropped (the meal_resident.rb trap, ADR 0004).
RSpec.describe 'Admin schedule preview' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }
  let(:admin) { create(:admin_user, community: community, superuser: false) }

  before { host! 'admin.example.com' }

  def post_preview(schedule:, anchor: '2026-08-02', meals_per_rotation: 12)
    post '/communities/schedule_preview',
         params: { community: { schedule: schedule,
                                schedule_anchor_date: anchor,
                                meals_per_rotation: meals_per_rotation } }
  end

  describe 'as a superuser' do
    before { sign_in superuser }

    it 'returns the upcoming dates for a draft grid' do
      travel_to Date.new(2026, 8, 7) do
        post_preview(schedule: { '0' => ['', '0', '1', '4'], '1' => ['', '0', '2', '4'] })
      end

      expect(response).to have_http_status(:ok)
      # 2026-08-02 anchors week 1, so the Tuesday of the following week is
      # the alternating day — same phase the equivalence specs pin.
      expect(response.body).to include('Sun Aug 9, 2026')
      expect(response.body).to include('Tue Aug 11, 2026')
      expect(response.body).not_to include('Mon Aug 10, 2026')
    end

    it 'handles a skip-week grid' do
      travel_to Date.new(2026, 8, 7) do
        post_preview(schedule: { '0' => ['', '3'], '1' => [''] }, meals_per_rotation: 3)
      end

      expect(response).to have_http_status(:ok)
      # Wednesdays every other week: Aug 5 was week 1, so Aug 19, Sep 2, Sep 16.
      expect(response.body).to include('Wed Aug 19, 2026')
      expect(response.body).to include('Wed Sep 2, 2026')
      expect(response.body).not_to include('Aug 12')
    end

    it 'skips holidays' do
      travel_to Date.new(2026, 11, 20) do
        post_preview(schedule: { '0' => ['', '4'] }, meals_per_rotation: 2)
      end

      # Thanksgiving 2026 is Thursday November 26.
      expect(response.body).not_to include('Nov 26')
      expect(response.body).to include('Thu Dec 3, 2026')
    end

    it 'returns the validation messages for an empty grid' do
      post_preview(schedule: { '0' => [''], '1' => [''] })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('must include at least one meal day')
    end

    it 'returns the validation message for a bad meals_per_rotation' do
      post_preview(schedule: { '0' => ['', '0'] }, meals_per_rotation: 0)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('must be a whole number from 1 to 100')
    end
  end

  # The save path, not the preview: pins that permit_params lets the grid
  # hash through and that an all-unchecked week (only the hidden "" marker)
  # survives the round trip as an empty week.
  describe 'saving the schedule' do
    before { sign_in superuser }

    it 'updates the columns from the form params' do
      patch "/communities/#{community.id}",
            params: { community: { schedule: { '0' => ['', '3'], '1' => [''] },
                                   schedule_anchor_date: '2026-08-05',
                                   meals_per_rotation: 4 } }

      community.reload
      expect(community.schedule).to eq([[3], []])
      expect(community.schedule_anchor_date).to eq(Date.new(2026, 8, 2)) # normalized to Sunday
      expect(community.meals_per_rotation).to eq(4)
    end

    it 'refuses a plain admin' do
      sign_in admin
      patch "/communities/#{community.id}",
            params: { community: { meals_per_rotation: 4 } }

      expect(community.reload.meals_per_rotation).to eq(12)
    end
  end

  # Not under the superuser describe: its sign_in creates the community, and
  # this example needs an empty table — the state the bootstrap form runs in.
  describe 'bootstrap' do
    it 'previews with no Community row yet, which is the bootstrap form' do
      bootstrap_superuser = create(:admin_user, community: nil, superuser: true)
      expect(Community.count).to eq(0)
      sign_in bootstrap_superuser

      post_preview(schedule: { '0' => ['', '0'] }, meals_per_rotation: 2)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'authorization' do
    it 'refuses a plain admin' do
      sign_in admin
      post_preview(schedule: { '0' => ['', '0'] })

      expect(response).to redirect_to('/')
    end

    it 'refuses a read-only token' do
      token_account = create(:admin_user, community: community, superuser: true)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return('test-token')
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(token_account.id.to_s)

      post '/communities/schedule_preview',
           params: { token: 'test-token',
                     community: { schedule: { '0' => ['', '0'] },
                                  schedule_anchor_date: '2026-08-02',
                                  meals_per_rotation: 12 } }

      expect(response).not_to have_http_status(:ok)
    end
  end
end
