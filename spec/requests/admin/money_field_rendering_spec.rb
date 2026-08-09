# frozen_string_literal: true

require 'rails_helper'

# Money fields on admin forms render as money. The columns are DECIMAL(12,8),
# so the raw attribute renders as "4.5" or "16.0" — the forms format the
# value to two decimals instead. A new bill's amount is the column default 0,
# which renders blank so the cook's real cost must be typed.
RSpec.describe 'Admin money field rendering' do
  let(:community) { create(:community, cap: BigDecimal('4.5')) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in superuser
  end

  it 'renders the cap as dollars and cents on the community edit form' do
    get "/communities/#{community.id}/edit"

    expect(response.body).to include('value="4.50"')
  end

  it 'renders a blank cap field when no cap is set' do
    community.update!(cap: nil)

    get "/communities/#{community.id}/edit"

    expect_blank_field('community_cap')
  end

  it 'renders a bill amount as dollars and cents on the bill edit form' do
    unit = create(:unit, community: community)
    cook = create(:resident, community: community, unit: unit)
    meal = create(:meal, community: community)
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))

    get "/bills/#{bill.id}/edit"

    expect(response.body).to include('value="16.00"')
  end

  it 'renders a blank amount on the new bill form' do
    get '/bills/new'

    expect_blank_field('bill_amount')
  end

  # A blank submit casts "" to nil for the decimal column. The re-render
  # must show the validation message, not crash on the nil (this was a 500:
  # nil has no #zero?).
  it 're-renders the new bill form with the error when the amount is blank' do
    unit = create(:unit, community: community)
    cook = create(:resident, community: community, unit: unit)
    meal = create(:meal, community: community)

    post '/bills', params: { bill: { meal_id: meal.id, resident_id: cook.id,
                                     community_id: community.id, amount: '' } }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('is not a number')
    expect_blank_field('bill_amount')
  end

  # A sub-cent amount is refused, and the re-rendered field must still show
  # the typo the error names — not a rounded value that looks valid.
  it 'echoes a refused sub-cent amount instead of rounding it' do
    unit = create(:unit, community: community)
    cook = create(:resident, community: community, unit: unit)
    meal = create(:meal, community: community)
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))

    patch "/bills/#{bill.id}", params: { bill: { amount: '16.005' } }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('must be whole cents')
    expect(response.body).to include('value="16.005"')
  end

  # The input with this id must exist and carry no value attribute (or an
  # empty one) — a regex because the tag's other attributes vary.
  def expect_blank_field(dom_id)
    field = response.body[/<input[^>]*id="#{dom_id}"[^>]*>/]
    expect(field).to be_present
    expect(field).not_to match(/value="[^"]/)
  end
end
