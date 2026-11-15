# frozen_string_literal: true

require 'rails_helper'

# Through the whole stack: a write that PostgreSQL refuses because its
# disk is full is answered 507 with a message, and saves nothing
# (DatabaseFull, challenge 30). Before 2026-11-15 it was answered 500,
# and the page told the person "The server had a problem" and treated the
# write as maybe saved.
#
# A trigger raises PostgreSQL's real disk_full error (SQLSTATE 53100) on
# the table the write inserts into, so the error comes from the database
# driver the way a full disk's does. The trigger is made inside the
# example's own transaction, so it is gone after the example.
RSpec.describe 'A write refused because the database disk is full' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: community.today + 3) }

  def fill_the_disk_for(table)
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL.squish)
      CREATE FUNCTION spec_disk_full() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'could not extend file: No space left on device' USING ERRCODE = 'disk_full';
      END $$
    SQL
    connection.execute("CREATE TRIGGER spec_disk_full BEFORE INSERT ON #{table} " \
                       'FOR EACH ROW EXECUTE FUNCTION spec_disk_full()')
  end

  def free_the_disk_for(table)
    ActiveRecord::Base.connection.execute("DROP TRIGGER spec_disk_full ON #{table}")
  end

  def add_guest(key)
    post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests",
         params: { vegetarian: false, token: token }, headers: IdempotencyKey.header(key), as: :json
  end

  it 'answers a sign-up 507 with the message, and saves no sign-up' do
    fill_the_disk_for('meal_residents')

    post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token, late: false, vegetarian: false }

    expect(response).to have_http_status(:insufficient_storage)
    expect(response.parsed_body).to eq('message' => DatabaseFull::MESSAGE)
    expect(MealResident.where(meal: meal)).to be_empty
  end

  it 'answers a guest add 507, keeps no guest and no key, and saves it once when the key is sent again' do
    key = SecureRandom.uuid
    fill_the_disk_for('guests')

    add_guest(key)

    expect(response).to have_http_status(:insufficient_storage)
    expect(response.parsed_body).to eq('message' => DatabaseFull::MESSAGE)
    expect(Guest.where(meal: meal)).to be_empty
    expect(GuestAddKey.count).to eq(0)

    free_the_disk_for('guests')
    add_guest(key)

    expect(response).to have_http_status(:ok)
    expect(Guest.where(meal: meal).count).to eq(1)
  end

  it 'answers 500 as before for an error that is not a full disk' do
    allow_any_instance_of(Api::V1::SiteController) # rubocop:disable RSpec/AnyInstance -- the failure is inside the request
      .to receive(:version).and_raise(ActiveRecord::StatementInvalid, 'something else')

    expect { get '/api/v1/version' }.to raise_error(ActiveRecord::StatementInvalid)
  end
end
