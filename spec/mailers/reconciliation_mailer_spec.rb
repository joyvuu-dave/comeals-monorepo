# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReconciliationMailer do
  let(:community) { create(:community, name: "Swan's Way") }
  let(:unit) { create(:unit, community: community) }
  let(:resident) do
    create(:resident, community: community, unit: unit, name: 'Sarah Chen', email: 'sarah@example.com')
  end

  # The token is a query value. Rails reads "+" in a query as a space,
  # "&" as the start of the next value, and "#" as the end of the query,
  # so a token that holds one of them must be written as a %-code, or
  # the admin reads a different token and asks the reader to log in.
  let(:token_with_url_characters) { 'a+b&c=d#e/f?g%2B' }

  # Every URL in a mail, from the text part and then from the HTML links.
  def urls_in(mail)
    mail.text_part.body.to_s.scan(%r{https?://\S+}) + links_in(html_body(mail)).map(&:last)
  end

  # The token Rails reads when a browser opens the URL.
  def token_read_from(url)
    Rack::Utils.parse_nested_query(URI(url).query)['token']
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

      expect(cook_mail.text_part.body.to_s.split).to include(url)
      expect(cook_mail.html_part.body.to_s).to include(%(<a href="#{ERB::Util.html_escape(url)}">here</a>))
    end

    it 'writes the token so that the admin reads back the same token, in both parts' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return(token_with_url_characters)

      expect(urls_in(mail).map { |url| token_read_from(url) }).to eq([token_with_url_characters] * 2)
    end

    it_behaves_like 'an HTML part that is one HTML document'

    # The words are an open question (#106). This pins them as they are,
    # so that a change to the markup around them cannot drop any.
    it 'keeps the words and the community name in the HTML part' do
      expect(html_body(mail).text.squish).to eq(
        "Semi-Annual Reconciliation It's time once again to reconcile our Common Meals. " \
        'In preparation, please ensure all your meal costs are accurate. ' \
        'View all your cooking slots for the last 6 months here. ' \
        'Meals will be locked and final balances will be sent out in 2 weeks. ' \
        "Have a great day! ~Swan's Way"
      )
    end
  end

  describe '#common_house_collection_email' do
    let(:mail) { described_class.common_house_collection_email }
    let(:residents_url) do
      'http://admin.lvh.me:3000/residents?q%5Bactive_eq%5D=true&commit=Filter&subdomain=admin&order=name_asc' \
        '&token=the-token&utf8=%E2%9C%93'
    end
    let(:units_url) { 'http://admin.lvh.me:3000/units?token=the-token&utf8=%E2%9C%93' }

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
      lines = mail.text_part.body.to_s.lines.map(&:chomp)

      expect(lines).to include("Residents: #{residents_url}", "Units: #{units_url}")
    end

    it 'names the resident and unit balance links in the HTML part' do
      html = mail.html_part.body.to_s

      expect(html).to include(%(<a href="#{ERB::Util.html_escape(residents_url)}">Residents</a>))
      expect(html).to include(%(<a href="#{ERB::Util.html_escape(units_url)}">Units</a>))
    end

    it 'writes the token so that the admin reads back the same token, in both parts' do
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return(token_with_url_characters)

      expect(urls_in(mail).map { |url| token_read_from(url) }).to eq([token_with_url_characters] * 4)
    end

    it_behaves_like 'an HTML part that is one HTML document'

    it 'keeps the words and the two links in the HTML part' do
      body = html_body(mail)

      expect(body.text.squish).to eq(
        'Resident / Unit Balances for Current Reconciliation ' \
        "Meal costs have now been locked and it's time collect and distribute $. " \
        'Here are the final balances. Residents Units ~Admin'
      )
      expect(links_in(body)).to eq([['Residents', residents_url], ['Units', units_url]])
    end
  end
end
