# frozen_string_literal: true

require 'rails_helper'

# ADR 0011 rule 6: a superuser corrects a settled dinner from its admin
# page. The form shows each cook, eater and guest, and a reason. Preview
# shows each change in words and each person's change in money, and
# saves nothing. Save sends the preview's fingerprint, so it saves only
# what the preview showed: if the dinner or the form changed after the
# preview, it saves nothing and shows the new preview.
RSpec.describe 'Admin correction form for a settled dinner' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Unit A') }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook One') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater One') }
  let(:other) { create(:resident, community: community, unit: unit, name: 'Other One') }
  # Signed up at the adult price; a birthday entered after the dinner
  # settled makes them 8 on its date, so the price for their age is a
  # child's.
  let(:child) { create(:resident, community: community, unit: unit, name: 'Child One') }
  let!(:meal) do
    create(:meal, community: community, date: latest - 5).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      [eater, child].each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
      create(:guest, meal: meal, resident: eater, multiplier: Multiplier::FULL)
      settle!(cutoff: latest - 5)
      child.update!(birthday: (latest - 5).years_ago(8))
    end.reload
  end
  let(:path) { "/meals/#{meal.id}/correct" }

  before do
    host! 'admin.example.com'
    sign_in admin
  end

  def page
    response.parsed_body
  end

  def alert
    page.at_css('.flash_alert')&.text&.squish
  end

  def panel(title)
    page.css('.panel').find { |panel| panel.at_css('h3').text.start_with?(title) }
  end

  def rows(container)
    container.css('tbody tr').map { |row| row.css('td').map { |cell| cell.text.squish } }
  end

  # The form as the page sends it when nothing is touched: every row, as
  # it is now.
  def untouched
    {
      reason: '',
      cooks: { cook.id.to_s => { amount: '30.00', no_cost: '0', remove: '0' } },
      new_cook: { resident_id: '', amount: '', no_cost: '0' },
      eaters: { eater.id.to_s => 'keep', child.id.to_s => 'keep' },
      guests: { meal.guests.sole.id.to_s => { remove: '0' } },
      new_guest: { host_id: '', multiplier: '2' }
    }
  end

  def cost_to(amount, reason: 'Typed $30 for $20')
    untouched.deep_merge(reason: reason, cooks: { cook.id.to_s => { amount: amount } })
  end

  def nobody_pays_refusal
    'This leaves a $30.00 cost with nobody to charge. Keep someone who pays, or mark the cost No cost.'
  end

  # Everyone who pays taken off, and the $30 cost kept.
  def nobody_pays
    untouched.deep_merge(reason: 'Nobody ate', eaters: { eater.id.to_s => 'remove', child.id.to_s => 'remove' },
                         guests: { meal.guests.sole.id.to_s => { remove: '1' } })
  end

  def preview(correction)
    post path, params: { correction: correction, preview: 'Preview correction' }
  end

  # The fingerprint the preview page carries to its Save button.
  def fingerprint_of(correction)
    preview(correction)
    page.at_css('input[name=fingerprint]')['value']
  end

  def save(correction, fingerprint: fingerprint_of(correction))
    post path, params: { correction: correction, fingerprint: fingerprint, save: 'Save correction' }
  end

  describe 'the button on the dinner\'s page' do
    it 'is there for a superuser on a settled dinner' do
      get "/meals/#{meal.id}"

      expect(page.css('.action_item a').to_h { |link| [link.text, link['href']] })
        .to include('Correct this dinner' => path)
    end

    it 'is not there on an open dinner, or for a plain admin' do
      open = create(:meal, community: community, date: latest + 1)
      get "/meals/#{open.id}"
      expect(response.body).not_to include('Correct this dinner')

      sign_in create(:admin_user, community: community, superuser: false)
      get "/meals/#{meal.id}"
      expect(response.body).not_to include('Correct this dinner')
    end
  end

  describe 'the form' do
    it 'shows each cook, eater and guest as they are now, and the price for an eater\'s age' do
      get path

      expect(page.at_css('#page_title').text).to eq("Correct the #{meal.date.iso8601} Dinner")
      expect(rows(panel('Cooks')).map(&:first)).to eq(['Cook One'])
      expect(rows(panel('Cooks')).first[1]).to eq('$30.00')
      expect(page.at_css("input[name='correction[cooks][#{cook.id}][amount]']")['value']).to eq('30.00')
      expect(rows(panel('Eaters'))).to eq(
        [['Child One', 'Adult', "Keep Remove Change to Child, the price for their age on #{meal.date.iso8601}"],
         ['Eater One', 'Adult', 'Keep Remove']]
      )
      expect(rows(panel('Guests'))).to eq([['Guest of Eater One', 'Adult', '']])
      expect(page.at_css('input[name=save]')).to be_nil
    end

    it 'sends an open dinner to its own page' do
      open = create(:meal, community: community, date: latest + 1)

      get "/meals/#{open.id}/correct"

      expect(response).to redirect_to("/meals/#{open.id}")
      expect(flash[:alert]).to eq('This dinner is not settled yet, so it is changed directly, not corrected.')
    end

    it 'is refused to a plain admin, who can save nothing' do
      sign_in create(:admin_user, community: community, superuser: false)

      get path
      expect(flash[:error]).to eq('You are not authorized to perform this action.')
      expect { save(cost_to('20'), fingerprint: 'x') }.not_to change(MealCorrection, :count)
    end
  end

  describe 'Preview' do
    it 'shows what would change and each person\'s change, and saves nothing' do
      expect { preview(cost_to('20')) }.not_to change(MealCorrection, :count)

      expect(response).to have_http_status(:ok)
      expect(alert).to be_nil
      shown = panel('What this correction does')
      expect(shown.css('li').map(&:text)).to eq(["Changed Cook One's cost from $30.00 to $20.00."])
      expect(rows(shown)).to contain_exactly(['Cook One', 'charged $10.00'], ['Eater One', 'credited $6.67'],
                                             ['Child One', 'credited $3.33'])
      expect(page.at_css('input[name=save]')['value']).to eq('Save correction')
      expect(meal.bills.sole.reload.amount).to eq(30)
      # The form keeps what was typed.
      expect(page.at_css("input[name='correction[cooks][#{cook.id}][amount]']")['value']).to eq('20')
      expect(page.at_css('textarea').text.strip).to eq('Typed $30 for $20')
    end

    # The form reader refuses each mistake it can see first. A model can
    # still refuse an edit: a row added in the moment between the read and
    # the edit, or a model rule added later. The page shows its sentence.
    it 'shows a refusal from a model as a sentence' do
      refused = Bill.new.tap { |bill| bill.errors.add(:base, 'Refused for a reason.') }
      allow(MealCorrecting).to receive(:preview).and_raise(ActiveRecord::RecordInvalid.new(refused))

      preview(cost_to('20'))

      expect(response).to have_http_status(:ok)
      expect(alert).to eq('Refused for a reason.')
    end

    it 'says so when nothing changes' do
      preview(untouched)

      expect(alert).to eq('The correction changes nothing.')
      expect(panel('What this correction does')).to be_nil
    end

    # Everyone who pays taken off, and the cost kept: the next settlement
    # would credit the cook $0 for it (#172, Meal.receipt_and_nobody_to_charge).
    it 'refuses a correction that leaves the cost with nobody to charge, and says what to do' do
      expect { preview(nobody_pays) }.not_to change(MealCorrection, :count)

      expect(alert).to eq(nobody_pays_refusal)
      expect(panel('What this correction does')).to be_nil
      expect(meal.meal_residents.count).to eq(2)
    end

    it 'refuses a cost it cannot read, or a blank one, and names the cook' do
      preview(cost_to('20.005'))
      expect(alert).to eq('Cook One: "20.005" is not a cost. A cost is whole cents, 0 to 9999.99, like 25.50.')

      preview(cost_to(''))
      expect(alert).to eq('Cook One: enter a cost, or tick No cost.')
    end
  end

  describe 'Save' do
    it 'saves the correction the preview showed, with the reason and the admin, and shows it on the dinner' do
      expect { save(cost_to('20')) }.to change(MealCorrection, :count).by(1)

      expect(response).to redirect_to("/meals/#{meal.id}")
      expect(flash[:notice]).to eq('The correction is saved. The next settlement carries it.')
      correction = MealCorrection.sole
      expect(correction).to have_attributes(meal: meal, admin_user: admin, reason: 'Typed $30 for $20',
                                            reconciliation: nil)
      expect(correction.lines.sum(:amount)).to eq(0)
      expect(meal.bills.sole.reload.amount).to eq(20)
      follow_redirect!
      expect(panel('Corrections (1)').text).to include('Reason: Typed $30 for $20')
    end

    it 'makes every kind of edit the form offers, in one correction' do
      correction = untouched.deep_merge(
        reason: 'Several things were wrong',
        cooks: { cook.id.to_s => { remove: '1' } },
        new_cook: { resident_id: other.id.to_s, amount: '', no_cost: '1' },
        eaters: { eater.id.to_s => 'remove', child.id.to_s => 'reprice' },
        new_eater_ids: [other.id.to_s],
        guests: { meal.guests.sole.id.to_s => { remove: '1' } },
        new_guest: { host_id: child.id.to_s, multiplier: Multiplier::HALF.to_s }
      )

      save(correction)

      expect(MealCorrection.sole.edits).to eq(
        [{ 'what' => 'cost', 'resident_id' => cook.id, 'from' => { 'amount' => '30.0', 'no_cost' => false },
           'to' => nil },
         { 'what' => 'cost', 'resident_id' => other.id, 'from' => nil,
           'to' => { 'amount' => '0.0', 'no_cost' => true } },
         { 'what' => 'eater', 'resident_id' => child.id, 'from' => Multiplier::FULL, 'to' => Multiplier::HALF },
         { 'what' => 'eater', 'resident_id' => eater.id, 'from' => Multiplier::FULL, 'to' => nil },
         { 'what' => 'eater', 'resident_id' => other.id, 'from' => nil, 'to' => Multiplier::FULL },
         { 'what' => 'guest', 'resident_id' => eater.id, 'from' => Multiplier::FULL, 'to' => nil },
         { 'what' => 'guest', 'resident_id' => child.id, 'from' => nil, 'to' => Multiplier::HALF }]
      )
      meal.reload
      expect(meal.bills.map { |bill| [bill.resident, bill.no_cost] }).to eq([[other, true]])
      expect(meal.meal_residents.map(&:resident)).to contain_exactly(child, other)
      expect(meal.guests.map { |guest| [guest.resident, guest.multiplier] }).to eq([[child, Multiplier::HALF]])
    end

    it 'saves nothing, and shows the new preview, when the dinner changed after the preview' do
      fingerprint = fingerprint_of(cost_to('20'))
      MealCorrecting.save!(meal, by: admin, reason: 'Someone else first') do |edits|
        edits.cost(cook, amount: BigDecimal('25'), no_cost: false)
      end

      expect { save(cost_to('20'), fingerprint: fingerprint) }.not_to change(MealCorrection, :count)

      expect(response).to have_http_status(:ok)
      expect(alert).to start_with('The dinner or the form changed after the preview, so nothing was saved.')
      expect(panel('What this correction does').css('li').map(&:text))
        .to eq(["Changed Cook One's cost from $25.00 to $20.00."])
      expect(meal.bills.sole.reload.amount).to eq(25)
    end

    it 'saves nothing when the form changed after the preview' do
      fingerprint = fingerprint_of(cost_to('20'))

      expect { save(cost_to('21'), fingerprint: fingerprint) }.not_to change(MealCorrection, :count)

      expect(alert).to start_with('The dinner or the form changed after the preview')
      expect(page.at_css('input[name=fingerprint]')['value']).to eq(fingerprint_of(cost_to('21')))
    end

    # A Save that skips the preview (an old page, a hand-made request)
    # is refused by the same rule.
    it 'refuses a correction that leaves the cost with nobody to charge, and saves nothing' do
      expect { save(nobody_pays, fingerprint: 'not-a-preview') }.not_to change(MealCorrection, :count)

      expect(alert).to eq(nobody_pays_refusal)
      expect(meal.meal_residents.count).to eq(2)
      expect(meal.guests.count).to eq(1)
    end

    it 'saves a correction that takes everyone who pays off and marks the cost No cost' do
      no_cost = nobody_pays.deep_merge(cooks: { cook.id.to_s => { amount: '', no_cost: '1' } })

      expect { save(no_cost) }.to change(MealCorrection, :count).by(1)
      expect(meal.bills.sole.reload).to have_attributes(amount: 0, no_cost: true)
    end

    it 'refuses a blank reason, and shows the preview again' do
      expect { save(cost_to('20', reason: ' ')) }.not_to change(MealCorrection, :count)

      expect(alert).to eq("Reason can't be blank")
      expect(page.at_css('input[name=save]')).to be_present
      expect(meal.bills.sole.reload.amount).to eq(30)
    end

    it 'previews instead of saving when no preview came first' do
      expect do
        post path, params: { correction: cost_to('20'), save: 'Save correction' }
      end.not_to change(MealCorrection, :count)

      expect(panel('What this correction does')).to be_present
    end

    # Another correction takes the cook off after this form read the
    # dinner and before its edit finds the cook's bill again.
    it 'says the dinner changed when a row goes between reading the form and editing it' do
      allow(Bill).to receive(:find_by!).and_raise(ActiveRecord::RecordNotFound)

      expect { preview(untouched.deep_merge(cooks: { cook.id.to_s => { remove: '1' } })) }
        .not_to change(MealCorrection, :count)

      expect(response).to have_http_status(:ok)
      expect(alert).to eq('This dinner changed after the form was opened. Open the form again.')
    end

    it 'refuses a row the dinner no longer has, and saves nothing' do
      stale = untouched.deep_merge(cooks: { other.id.to_s => { amount: '5.00', no_cost: '0', remove: '0' } })

      expect { save(stale, fingerprint: 'x') }.not_to change(MealCorrection, :count)

      expect(alert).to eq('This dinner changed after the form was opened. Open the form again.')
    end
  end
end
