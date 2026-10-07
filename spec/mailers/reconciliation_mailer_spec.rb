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
    # The cutoff has a one-digit day, so a date written with a leading zero
    # ("Sep 03") or with the full month name ("September 3") shows here.
    let(:reconciliation) { create(:reconciliation, community: community, end_date: Date.new(2026, 9, 3)) }
    let(:mail) { described_class.reconciliation_notify_email(resident, reconciliation) }

    it 'sends to the resident email' do
      expect(mail.to).to eq(['sarah@example.com'])
    end

    it 'names the cutoff date in the subject' do
      expect(mail.subject).to eq('Common meals settled through Sep 3, 2026')
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
      expect(links_in(html_body(cook_mail))).to eq([['the meals you cooked', url]])
    end

    it 'writes the token so that the admin reads back the same token, in both parts' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return(token_with_url_characters)

      expect(urls_in(mail).map { |url| token_read_from(url) }).to eq([token_with_url_characters] * 2)
    end

    it 'underlines the title of the text part with = signs and nothing else' do
      expect(mail.text_part.body.decoded.lines.first(2).map(&:chomp))
        .to eq(['Common Meals Settled', '=' * 'Common Meals Settled'.length])
    end

    it_behaves_like 'an HTML part that is one HTML document'

    # The one sender, NotifyCooksJob, mails a cook after the settlement has
    # committed: SettleAndNotify queues it after settling, and the
    # send_cooking_slot_email task queues it for Reconciliation.last, which
    # is already settled. So the cook's meals are already locked
    # (CLAUDE.md, money rule 7). The mail must not ask for changes that the
    # app will now refuse, or say the lock is still to come (#106).
    it 'does not ask the cook to fix costs of meals the settlement has already locked' do
      [mail.text_part, mail.html_part].each do |part|
        body = part.body.decoded.squish
        expect(body).not_to include('ensure all your meal costs are accurate')
        expect(body).not_to include('will be locked')
      end
    end

    # The owner chose these words (#106). Each test pins every word of one
    # part, so a change to the template cannot drop or change any.
    it 'says the meals through the cutoff are settled and final, in the text part' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return('the-token')
      url = 'http://admin.lvh.me:3000/bills?order=meals.date_desc' \
            "&q%5Bmeal_reconciliation_id_eq%5D=#{reconciliation.id}&q%5Bresident_id_eq%5D=#{resident.id}" \
            '&subdomain=admin&token=the-token&utf8=%E2%9C%93'

      # rstrip: the text layout adds a blank line after the template.
      expect(mail.text_part.body.decoded.rstrip.lines.map(&:chomp)).to eq(
        [
          'Common Meals Settled',
          '====================',
          '',
          'The common meals in this settlement, through Sep 3, 2026, are now settled. ' \
          'Their costs are final and can no longer be changed.',
          '',
          "Here are the meals you cooked in this settlement, and what you spent on each: #{url}",
          '',
          'Have a great day!',
          "~Swan's Way"
        ]
      )
    end

    it 'says the meals through the cutoff are settled and final, in the HTML part' do
      expect(html_body(mail).text.squish).to eq(
        'Common Meals Settled ' \
        'The common meals in this settlement, through Sep 3, 2026, are now settled. ' \
        'Their costs are final and can no longer be changed. ' \
        'Here are the meals you cooked in this settlement, and what you spent on each. ' \
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

    it 'says that meal costs are locked and it is time to collect, in both parts' do
      sentence = "Meal costs have now been locked and it's time to collect and distribute $. " \
                 'Here are the final balances.'

      expect(html_body(mail).text.squish).to include(sentence)
      expect(mail.text_part.body.decoded.lines.map(&:chomp)).to include(sentence)
    end

    it 'underlines the title of the text part with = signs and nothing else' do
      title = 'Resident / Unit Balances for Current Reconciliation'

      expect(mail.text_part.body.decoded.lines.first(2).map(&:chomp)).to eq([title, '=' * title.length])
    end

    it_behaves_like 'an HTML part that is one HTML document'

    it 'keeps the words and the two links in the HTML part' do
      body = html_body(mail)

      expect(body.text.squish).to eq(
        'Resident / Unit Balances for Current Reconciliation ' \
        "Meal costs have now been locked and it's time to collect and distribute $. " \
        'Here are the final balances. Residents Units ~Admin'
      )
      expect(links_in(body)).to eq([['Residents', residents_url], ['Units', units_url]])
    end
  end
end
