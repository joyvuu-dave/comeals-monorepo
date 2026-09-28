# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReconciliationMailer do
  let(:community) { create(:community, name: "Swan's Way") }
  let(:unit) { create(:unit, community: community) }
  let(:resident) do
    create(:resident, community: community, unit: unit, name: 'Sarah Chen', email: 'sarah@example.com')
  end

  describe '#reconciliation_notify_email' do
    let(:reconciliation) { create(:reconciliation, community: community) }
    let(:mail) { described_class.reconciliation_notify_email(resident, reconciliation) }

    it 'sends to the resident email' do
      expect(mail.to).to eq(['sarah@example.com'])
    end

    it 'has the correct subject' do
      expect(mail.subject).to eq("Meal Reconciliation #{reconciliation.id}")
    end

    it 'includes the community name' do
      expect(mail.body.encoded).to include('Swan')
    end

    # The link shows this cook's bills in this settlement, so the URL
    # carries both ids. The cook is whichever of two residents does not
    # share its id with the reconciliation, so a link built from the wrong
    # id cannot pass by chance.
    it "links to the cook's own bills in that settlement, in both parts" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return('the-token')
      candidates = Array.new(2) { create(:resident, community: community, unit: unit) }
      cook = candidates.find { |candidate| candidate.id != reconciliation.id }
      url = 'http://admin.lvh.me:3000/bills?order=meals.date_desc' \
            "&q%5Bmeal_reconciliation_id_eq%5D=#{reconciliation.id}&q%5Bresident_id_eq%5D=#{cook.id}" \
            '&subdomain=admin&token=the-token&utf8=%E2%9C%93'

      cook_mail = described_class.reconciliation_notify_email(cook, reconciliation)

      expect(cook_mail.text_part.body.to_s).to include(url)
      expect(cook_mail.html_part.body.to_s).to include(%(<a href="#{ERB::Util.html_escape(url)}">here</a>))
    end
  end

  describe '#common_house_collection_email' do
    let(:mail) { described_class.common_house_collection_email }
    let(:residents_url) do
      'http://admin.lvh.me:3000/residents?q%5Bactive_eq%5D=true&commit=Filter&subdomain=admin&order=name_asc' \
        '&token=the-token&utf8=%E2%9C%93'
    end
    let(:units_url) { 'http://admin.lvh.me:3000/units?&token=the-token&utf8=%E2%9C%93' }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return('the-token')
    end

    it 'sends to the common house email' do
      expect(mail.to).to eq(['commonhouse@swansway.com'])
    end

    it 'has the correct subject' do
      expect(mail.subject).to eq('Reconciliation Balances')
    end

    it 'links the balances under the configured admin root, with the read-only token' do
      expect(mail.text_part.body.to_s).to include("Residents: #{residents_url}", "Units: #{units_url}")
    end

    it 'names the resident and unit balance links in the HTML part' do
      html = mail.html_part.body.to_s

      expect(html).to include(%(<a href="#{ERB::Util.html_escape(residents_url)}">Residents</a>))
      expect(html).to include(%(<a href="#{ERB::Util.html_escape(units_url)}">Units</a>))
    end
  end
end
