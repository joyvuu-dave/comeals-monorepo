# frozen_string_literal: true

require 'rails_helper'

# all_pages_spec renders every admin page against one bare record. These
# examples render the parts of a page that only appear once there is
# something to list: a meal's guests, a unit's residents, a rotation's
# meals, a check that crashed, a bill for nothing. A column block that
# never runs is a column block a rename can break unseen.
RSpec.describe 'Admin pages with something to list' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Elm 12') }
  let(:resident) { create(:resident, community: community, unit: unit, name: 'Rosa Lister') }
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }

  before do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community, superuser: true)
  end

  # Settled data is immutable by design, so a page state that only a hand
  # edit can produce is set up the way a hand edit would do it.
  def behind_the_guards
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
      yield
    end
  end

  it 'lists upcoming meals and closed meals on the dashboard' do
    upcoming = create(:meal, community: community, date: Date.tomorrow)
    closed = create(:meal, community: community, date: Date.yesterday)
    create(:meal_resident, meal: closed, resident: resident, community: community)
    create(:bill, meal: closed, resident: resident, community: community, amount: BigDecimal('20'))
    closed.update!(closed: true)

    get '/'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/meals/#{upcoming.id}")
    expect(response.body).to include("/meals/#{closed.id}")
  end

  it 'lists guests and a bill for nothing on a resident statement' do
    create(:guest, meal: meal, resident: resident, multiplier: 2)
    create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('0'))

    get "/residents/#{resident.id}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Price Category')
    expect(response.body).to include("/meals/#{meal.id}")
  end

  it 'lists guests on a meal page' do
    create(:guest, meal: meal, resident: resident)

    get "/meals/#{meal.id}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Guest of Rosa')
  end

  it 'lists the meals of a rotation' do
    rotation = create(:rotation, community: community)
    meal.update!(rotation: rotation)

    get "/rotations/#{rotation.id}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/meals/#{meal.id}")
  end

  it 'lists the active residents of a unit' do
    resident

    get "/units/#{unit.id}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/residents/#{resident.id}")
  end

  it 'leaves the amount blank for a bill for nothing on the bills index' do
    create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('0'))

    get '/bills'

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('$0.00')
  end

  it 'shows a ledger check that passed and one that crashed' do
    passed = create(:ledger_check_run)
    create(:ledger_check_run, :errored)

    get '/ledger_check_runs'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('All Match')
    expect(response.body).to include('Did Not Finish')

    get "/ledger_check_runs/#{passed.id}"

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('What disagreed')
  end

  it 'exports guest room reservations as CSV with the host name' do
    create(:guest_room_reservation, community: community, resident: resident)

    get '/guest_room_reservations.csv'

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with('text/csv')
    expect(response.body).to include('Rosa Lister')
  end

  describe 'a settled meal that a hand edit left without its line items or its bills' do
    let!(:settled) do
      create(:meal_resident, meal: meal, resident: resident, community: community)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
      reconciliation = settle!(cutoff: Date.yesterday)
      meal.reload
      reconciliation
    end

    it 'renders the meal list and page with blank costs instead of raising' do
      behind_the_guards { MealCharge.where(meal_id: meal.id).delete_all }

      get '/meals'
      expect(response).to have_http_status(:ok)

      get "/meals/#{meal.id}"
      expect(response).to have_http_status(:ok)
    end

    it 'shows a dash for the cooks on the reconciliation page' do
      behind_the_guards { Bill.where(meal_id: meal.id).delete_all }

      get "/reconciliations/#{settled.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('—')
    end
  end

  describe 'the community page' do
    it 'shows the cap, an empty week, and how far meals already exist' do
      community.update!(cap: BigDecimal('4.50'), schedule: [[0, 1, 4], []])
      meal

      get "/communities/#{community.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('$4.50')
      expect(response.body).to include('No meals')
      expect(response.body).to include("Meals already exist through #{meal.date.strftime('%b %-d, %Y')}")
    end
  end
end
