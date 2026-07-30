# frozen_string_literal: true

require 'rails_helper'

# At SERIALIZABLE, PostgreSQL can refuse any transaction for a conflict. The
# API retries three times and then answers 409. Admin does not retry — see
# config/initializers/active_admin_conflict_rescue.rb for why the retry cannot
# work inside an ActiveAdmin controller. It shows the message and the person
# submits again.
#
# The refusal is injected here rather than raced for real. What a real race
# does is spec/db/settlement_race_spec.rb's job; this file only checks the
# answer admin gives once the database has refused.
RSpec.describe 'Admin conflict rescue' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  # Raised where the write happens, so everything before it — authorization,
  # the reconciled guards, strong params — has already run.
  def refuse_the_next_write
    # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Unit).to receive(:save)
      .and_raise(ActiveRecord::SerializationFailure, 'could not serialize access')
    # rubocop:enable RSpec/AnyInstance
  end

  describe 'a write refused for a conflict' do
    it 'redirects instead of raising' do
      refuse_the_next_write

      post '/units', params: { unit: { name: 'A-1', community_id: community.id } }

      expect(response).to have_http_status(:found)
    end

    it 'says nothing was saved and to try again' do
      refuse_the_next_write

      post '/units', params: { unit: { name: 'A-1', community_id: community.id } }

      expect(flash[:alert]).to eq('Someone else was changing this at the same time. ' \
                                  'Nothing was saved. Try again.')
    end

    it 'writes nothing' do
      refuse_the_next_write

      expect do
        post '/units', params: { unit: { name: 'A-1', community_id: community.id } }
      end.not_to change(Unit, :count)
    end

    it 'goes back to the page the person came from' do
      refuse_the_next_write

      post '/units',
           params: { unit: { name: 'A-1', community_id: community.id } },
           headers: { 'HTTP_REFERER' => 'http://admin.example.com/units/new' }

      expect(response).to redirect_to('http://admin.example.com/units/new')
    end

    # Without a referer there is nowhere to go back to. The dashboard is a
    # page every admin can reach, so it is the fallback.
    it 'goes to the dashboard when there is no referer' do
      refuse_the_next_write

      post '/units', params: { unit: { name: 'A-1', community_id: community.id } }

      expect(response).to redirect_to(admin_root_path)
    end

    # Nothing retries in admin, so if this is not reported the conflict is
    # invisible. Bugsnag is what tells us whether step 5 caused any of these.
    it 'reports the refusal so it can be counted' do
      refuse_the_next_write
      allow(Rails.error).to receive(:report)

      post '/units', params: { unit: { name: 'A-1', community_id: community.id } }

      expect(Rails.error).to have_received(:report)
        .with(instance_of(ActiveRecord::SerializationFailure), hash_including(handled: true))
    end
  end

  # A deadlock is the same problem with the same answer, and both are
  # subclasses of ActiveRecord::TransactionRollbackError, which is what the
  # rescue names.
  it 'answers a deadlock the same way' do
    # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Unit).to receive(:save)
      .and_raise(ActiveRecord::Deadlocked, 'deadlock detected')
    # rubocop:enable RSpec/AnyInstance

    post '/units', params: { unit: { name: 'A-1', community_id: community.id } }

    expect(flash[:alert]).to match(/nothing was saved/i)
  end

  # The handler is registered from a to_prepare block, which runs again on
  # every reload in development. rescue_from appends without checking for a
  # duplicate, so without the guard in the initializer the list would grow on
  # each reload.
  it 'registers the handler exactly once' do
    matching = ActiveAdmin::BaseController.rescue_handlers
                                          .count { |klass, _| klass == 'ActiveRecord::TransactionRollbackError' }

    expect(matching).to eq(1)
  end

  # The reason the retry is not here. If a future ActiveAdmin stops memoizing
  # the row, an around_action retry becomes possible and this decision is
  # worth revisiting. Until then a retry would write from the read the
  # database already refused.
  it 'still memoizes the row it read, which is why there is no retry' do
    unit_row = create(:unit, community: community)

    get "/units/#{unit_row.id}/edit"

    expect(controller.instance_variable_get(:@unit)).to be_a(Unit)
  end
end
