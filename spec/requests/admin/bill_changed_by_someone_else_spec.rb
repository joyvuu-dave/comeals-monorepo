# frozen_string_literal: true

require 'rails_helper'

# Issue #274. The admin bill form is built from one read of the bill, and
# the save comes in a later request. A cook can change the same bill from
# the meal page in between. Before bills had a lock_version, the admin
# save then wrote the form's values over the cook's change, with no error:
# the cook's "No cost" was lost, or (when the form changed only the
# amount) the row became No cost with an amount, which the
# bills_no_cost_means_no_amount CHECK refused with a 500.
#
# Now the form sends the lock_version it was built from, and a save from
# an older read is refused with a message. The bill keeps the cook's
# change.
RSpec.describe 'Admin bill changed by someone else' do
  let(:community) { create(:community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }
  let(:unit) { create(:unit, community: community) }
  let(:jane) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }
  let(:bill) { create(:bill, meal: meal, resident: jane, community: community, amount: 12, no_cost: false) }

  before do
    host! 'admin.example.com'
    sign_in superuser
  end

  def form_lock_version
    get "/bills/#{bill.id}/edit"
    response.parsed_body.at_css('input[type=hidden]#bill_lock_version')&.[]('value')
  end

  it 'puts the version of the bill it was built from on the edit form' do
    expect(form_lock_version).to eq(bill.reload.lock_version.to_s)
  end

  context 'when the cook changes the bill after the form was opened' do
    let!(:seen) { form_lock_version }

    before { bill.reload.update!(amount: 0, no_cost: true) }

    def save_the_form
      patch "/bills/#{bill.id}",
            params: { bill: { amount: '20.00', no_cost: '0', lock_version: seen } }
    end

    it "keeps the cook's change" do
      save_the_form

      expect(bill.reload.slice(:amount, :no_cost)).to eq('amount' => BigDecimal('0'), 'no_cost' => true)
    end

    it 'says someone else changed the bill and nothing was saved' do
      save_the_form

      expect(flash[:alert]).to eq('Someone else changed this bill after you opened it. Nothing was saved. ' \
                                  'This form now shows the bill as it is. Make your change again.')
    end

    it 'goes back to the form, which now shows the bill as it is' do
      save_the_form

      expect(response).to redirect_to("/bills/#{bill.id}/edit")
      follow_redirect!
      expect(response.parsed_body.at_css('#bill_amount')['value']).to eq('0.00')
      expect(response.parsed_body.at_css('#bill_no_cost')['checked']).to eq('checked')
      expect(response.parsed_body.at_css('#bill_lock_version')['value']).to eq(bill.reload.lock_version.to_s)
      expect(bill.lock_version.to_s).not_to eq(seen)
    end
  end

  it 'does not show the version on the bill page' do
    get "/bills/#{bill.id}"

    expect(response.parsed_body.css('.attributes_table th').map(&:text))
      .to eq(['Amount', 'Community', 'Created At', 'Meal', 'No Cost', 'Resident', 'Updated At'])
  end

  it 'saves the form when nobody changed the bill' do
    seen = form_lock_version

    patch "/bills/#{bill.id}", params: { bill: { amount: '20.00', no_cost: '0', lock_version: seen } }

    expect(bill.reload.amount).to eq(BigDecimal('20'))
  end
end
