# frozen_string_literal: true

require 'rails_helper'

# Every filter in the admin sidebar, sent the way the Filter button sends
# it: a GET with q[...] params. These are all the filters there are; every
# other list page sets config.filters = false. ransack turns the params
# into the WHERE clause, so a ransack update can break a filter while every
# page still renders and sorts (#160). Each example checks two things: the
# list shows only the matching rows, and the form still shows the option
# that was chosen.
RSpec.describe 'Admin list filters' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  before do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community, superuser: true)
  end

  def page_html = response.parsed_body

  # The record ids in the list, top to bottom.
  def listed_ids
    page_html.css('table.index_table > tbody > tr').map { |row| row['id'][/\d+\z/].to_i }
  end

  # The text of the option a browser shows in the filter's select: the one
  # marked selected, or the first one when none is marked.
  def shown_option(name)
    options = page_html.css(%(form.filter_form select[name="#{name}"] option))
    expect(options).not_to be_empty, "expected a filter named #{name}"
    (options.find { |option| option['selected'] } || options.first).text
  end

  describe 'residents, by active' do
    let!(:active) { create(:resident, community: community, unit: unit, active: true) }
    let!(:retired) { create(:resident, community: community, unit: unit, active: false) }

    it 'lists everyone and shows Any when no filter is applied' do
      get '/residents'

      expect(listed_ids).to contain_exactly(active.id, retired.id)
      expect(shown_option('q[active_eq]')).to eq('Any')
    end

    it 'lists only retired residents for No' do
      get '/residents', params: { q: { active_eq: 'false' } }

      expect(listed_ids).to eq([retired.id])
      expect(shown_option('q[active_eq]')).to eq('No')
    end

    it 'lists only active residents for Yes' do
      get '/residents', params: { q: { active_eq: 'true' } }

      expect(listed_ids).to eq([active.id])
      expect(shown_option('q[active_eq]')).to eq('Yes')
    end
  end

  describe 'meals, by reconciled' do
    let!(:reconciliation) { create(:reconciliation, community: community) }
    let(:settled_meal) { Meal.where(reconciliation_id: reconciliation.id).sole }
    # Created after the reconciliation, so its sweep cannot claim it.
    let!(:open_meal) { create(:meal, community: community) }

    # The list shows open and reconciled meals together here, so the form
    # must not say "Reconciled? Yes". It did from 2017 until 2026-10-10:
    # the filter had no blank option, so a browser showed the first one.
    it 'lists every meal and shows Any when no filter is applied' do
      get '/meals'

      expect(listed_ids).to contain_exactly(open_meal.id, settled_meal.id)
      expect(shown_option('q[reconciliation_id_null]')).to eq('Any')
    end

    it 'lists only the reconciled meal for Yes' do
      get '/meals', params: { q: { reconciliation_id_null: 'false' } }

      expect(listed_ids).to eq([settled_meal.id])
      expect(shown_option('q[reconciliation_id_null]')).to eq('Yes')
    end

    it 'lists only the open meal for No' do
      get '/meals', params: { q: { reconciliation_id_null: 'true' } }

      expect(listed_ids).to eq([open_meal.id])
      expect(shown_option('q[reconciliation_id_null]')).to eq('No')
    end
  end

  describe 'cooking slots, by cook and by reconciliation' do
    let!(:reconciliation) { create(:reconciliation, community: community) }
    let(:settled_bill) { Bill.joins(:meal).where(meals: { reconciliation_id: reconciliation.id }).sole }
    let(:cook) { create(:resident, community: community, unit: unit, name: 'Carla Cook') }
    let!(:open_bill) do
      create(:bill, community: community, resident: cook, amount: BigDecimal('5'),
                    meal: create(:meal, community: community))
    end

    it 'lists every slot and shows Any in both filters when no filter is applied' do
      get '/bills'

      expect(listed_ids).to contain_exactly(open_bill.id, settled_bill.id)
      expect(shown_option('q[resident_id_eq]')).to eq('Any')
      expect(shown_option('q[meal_reconciliation_id_eq]')).to eq('Any')
    end

    it 'lists only the chosen cook' do
      get '/bills', params: { q: { resident_id_eq: cook.id } }

      expect(listed_ids).to eq([open_bill.id])
      expect(shown_option('q[resident_id_eq]')).to eq('Carla Cook')
      expect(shown_option('q[meal_reconciliation_id_eq]')).to eq('Any')
    end

    # This filter reaches through the bill's meal (Bill allows ransack to
    # follow `meal`), so it is the one filter that joins a second table.
    it "lists only the slots on the chosen reconciliation's meals" do
      get '/bills', params: { q: { meal_reconciliation_id_eq: reconciliation.id } }

      expect(listed_ids).to eq([settled_bill.id])
      expect(shown_option('q[meal_reconciliation_id_eq]')).to eq(reconciliation.date.to_s)
      expect(shown_option('q[resident_id_eq]')).to eq('Any')
    end
  end
end
