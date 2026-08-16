# frozen_string_literal: true

require 'rails_helper'

# Issue #58: the child pricing rule is shown to admins as a plain sentence,
# built from the community's configured ages — never from fixed numbers.
# Odd ages (4 and 13) prove the sentence reads the record.
RSpec.describe 'Admin child pricing rule sentences' do
  let(:community) { create(:community, free_below_age: 4, full_price_age: 13) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }

  let(:rule_sentence) do
    'Children under 4 eat free, children 4 to 12 pay half price, ' \
      'and everyone 13 and older pays full price.'
  end

  before do
    host! 'admin.example.com'
    sign_in superuser
  end

  describe 'community form' do
    it 'shows the two age fields, the configured rule, and the when-it-applies note' do
      get "/communities/#{community.id}/edit"

      expect(response.body).to include('community_free_below_age')
      expect(response.body).to include('community_full_price_age')
      expect(response.body).to include(rule_sentence)
      expect(response.body).to include('Changes apply from the next nightly run, and only to future meal signups.')
    end

    it 'accepts new ages through the form params' do
      put "/communities/#{community.id}", params: {
        community: { free_below_age: 3, full_price_age: 10 }
      }

      expect(community.reload.free_below_age).to eq(3)
      expect(community.full_price_age).to eq(10)
    end

    it 'shows a readable error for ages in the wrong order' do
      put "/communities/#{community.id}", params: {
        community: { free_below_age: 14, full_price_age: 13 }
      }

      expect(community.reload.free_below_age).to eq(4)
      expect(response.body).to include('must be at or below the full-price age')
    end
  end

  describe 'community show page' do
    it 'shows the configured rule' do
      get "/communities/#{community.id}"

      expect(response.body).to include(rule_sentence)
    end
  end

  describe 'resident form' do
    it 'shows the configured rule next to the price category field' do
      unit = create(:unit, community: community)
      resident = create(:resident, community: community, unit: unit)

      get "/residents/#{resident.id}/edit"

      expect(response.body).to include(rule_sentence)
    end
  end
end
