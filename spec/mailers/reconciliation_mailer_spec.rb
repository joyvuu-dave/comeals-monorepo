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
    let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater One') }
    let(:admin) { create(:admin_user, community: community, superuser: true) }
    let(:mail) { described_class.reconciliation_notify_email(resident, reconciliation) }

    # A dinner on `date` that `cook` cooked for $30, and that one eater ate.
    def dinner(date, cook: resident)
      create(:meal, community: community, date: date).tap do |meal|
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
        create(:meal_resident, meal: meal, resident: eater, community: community)
      end
    end

    def correct(meal, reason, &)
      MealCorrecting.save!(meal.reload, by: admin, reason: reason, &)
    end

    def token_is(token)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return(token)
    end

    def bills_url(reconciliation, cook)
      'http://admin.lvh.me:3000/bills?order=meals.date_desc' \
        "&q%5Bmeal_reconciliation_id_eq%5D=#{reconciliation.id}&q%5Bresident_id_eq%5D=#{cook.id}" \
        '&subdomain=admin&token=the-token&utf8=%E2%9C%93'
    end

    def meal_url(meal)
      "http://admin.lvh.me:3000/meals/#{meal.id}?subdomain=admin&token=the-token&utf8=%E2%9C%93"
    end

    # The text part's lines. rstrip: the text layout adds a blank line
    # after the template.
    def text_lines(mail)
      mail.text_part.body.decoded.rstrip.lines.map(&:chomp)
    end

    context 'when the cook cooked a meal in the settlement' do
      # The cutoff has a one-digit day, so a date written with a leading
      # zero ("Sep 03") or with the full month name ("September 3") shows
      # here.
      let(:reconciliation) do
        dinner(Date.new(2026, 9, 3))
        settle!(cutoff: Date.new(2026, 9, 3))
      end

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
      # share its id with the reconciliation, so a link built from the
      # wrong id cannot pass by chance.
      it "links to the cook's own bills in that settlement, in both parts" do
        token_is('the-token')
        candidates = Array.new(2) { create(:resident, community: community, unit: unit) }
        candidates.each_with_index { |candidate, i| dinner(Date.new(2026, 9, 1) + i, cook: candidate) }
        settlement = settle!(cutoff: Date.new(2026, 9, 3))
        cook = candidates.find { |candidate| candidate.id != settlement.id }

        cook_mail = described_class.reconciliation_notify_email(cook, settlement)

        expect(cook_mail.text_part.body.to_s.split).to include(bills_url(settlement, cook))
        expect(links_in(html_body(cook_mail))).to eq([['the meals you cooked', bills_url(settlement, cook)]])
      end

      it 'writes the token so that the admin reads back the same token, in both parts' do
        token_is(token_with_url_characters)

        expect(urls_in(mail).map { |url| token_read_from(url) }).to eq([token_with_url_characters] * 2)
      end

      it 'underlines the title of the text part with = signs and nothing else' do
        expect(mail.text_part.body.decoded.lines.first(2).map(&:chomp))
          .to eq(['Common Meals Settled', '=' * 'Common Meals Settled'.length])
      end

      it_behaves_like 'an HTML part that is one HTML document'

      # The one sender, NotifyCooksJob, mails a cook after the settlement
      # has committed: SettleAndNotify queues it after settling, and the
      # send_cooking_slot_email task queues it for Reconciliation.last,
      # which is already settled. So the cook's meals are already locked
      # (CLAUDE.md, money rule 7). The mail must not ask for changes that
      # the app will now refuse, or say the lock is still to come (#106).
      it 'does not ask the cook to fix costs of meals the settlement has already locked' do
        [mail.text_part, mail.html_part].each do |part|
          body = part.body.decoded.squish
          expect(body).not_to include('ensure all your meal costs are accurate')
          expect(body).not_to include('will be locked')
        end
      end

      # The owner chose these words (#106). Each test pins every word of
      # one part, so a change to the template cannot drop or change any.
      it 'says the meals through the cutoff are settled and final, in the text part' do
        token_is('the-token')
        url = bills_url(reconciliation, resident)

        expect(text_lines(mail)).to eq(
          [
            'Common Meals Settled',
            '====================',
            '',
            'The common meals in this settlement, through Sep 3, 2026, are now settled. ' \
            'Their costs are final. If a cost was wrong, an admin can correct it, and the change goes into ' \
            'the next settlement.',
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
          'Their costs are final. If a cost was wrong, an admin can correct it, and the change goes into ' \
          'the next settlement. ' \
          'Here are the meals you cooked in this settlement, and what you spent on each. ' \
          "Have a great day! ~Swan's Way"
        )
      end
    end

    # ADR 0011 rule 6. A correction to a settled dinner changes a cook's
    # cost, and the next settlement carries the change. That settlement's
    # mail tells the cook, who may have cooked nothing in it.
    context 'when the settlement carries a correction to the cook\'s cost' do
      let(:other_cook) { create(:resident, community: community, unit: unit, name: 'Other Cook') }
      # Both settled by the first settlement; `corrected` is then corrected.
      let!(:earlier) { dinner(Date.new(2026, 8, 13)) }
      let!(:corrected) { dinner(Date.new(2026, 8, 20)).tap { settle!(cutoff: Date.new(2026, 8, 20)) } }
      # The settlement that carries the correction. The cook mail goes to
      # the cooks of its one new dinner and to the corrected cook.
      let(:reconciliation) do
        correct(corrected, 'Typed $30 for $20') do |edits|
          edits.cost(resident, amount: BigDecimal('20'), no_cost: false)
        end
        dinner(Date.new(2026, 9, 3), cook: other_cook)
        settle!(cutoff: Date.new(2026, 9, 3))
      end

      before { token_is('the-token') }

      it 'says what changed and why, and links to the dinner, in the text part' do
        expect(text_lines(mail)).to eq(
          [
            'Common Meals Settled',
            '====================',
            '',
            'The common meals in this settlement, through Sep 3, 2026, are now settled. ' \
            'Their costs are final. If a cost was wrong, an admin can correct it, and the change goes into ' \
            'the next settlement.',
            '',
            'An admin corrected your cost on a meal settled before. This settlement carries the change:',
            '',
            "Aug 20, 2026: Changed Sarah Chen's cost from $30.00 to $20.00. Reason: Typed $30 for $20",
            meal_url(corrected),
            '',
            'Have a great day!',
            "~Swan's Way"
          ]
        )
      end

      it 'says what changed and why, and links to the dinner, in the HTML part' do
        body = html_body(mail)

        expect(body.text.squish).to eq(
          'Common Meals Settled ' \
          'The common meals in this settlement, through Sep 3, 2026, are now settled. ' \
          'Their costs are final. If a cost was wrong, an admin can correct it, and the change goes into ' \
          'the next settlement. ' \
          'An admin corrected your cost on a meal settled before. This settlement carries the change: ' \
          "Aug 20, 2026: Changed Sarah Chen's cost from $30.00 to $20.00. Reason: Typed $30 for $20 " \
          "Have a great day! ~Swan's Way"
        )
        expect(links_in(body)).to eq([['Aug 20, 2026', meal_url(corrected)]])
      end

      it_behaves_like 'an HTML part that is one HTML document'

      it 'also links to the meals the cook cooked in the settlement, and writes each token so it reads back' do
        dinner(Date.new(2026, 9, 2))
        token_is(token_with_url_characters)

        expect(text_lines(mail)).to include(
          a_string_starting_with('Here are the meals you cooked in this settlement'),
          'An admin corrected your cost on a meal settled before. This settlement carries the change:'
        )
        expect(urls_in(mail).map { |url| token_read_from(url) }).to eq([token_with_url_characters] * 4)
      end

      it 'lists only the changes to this cook\'s cost' do
        correct(corrected, 'Two cooks') do |edits|
          edits.cost(other_cook, amount: BigDecimal('5'), no_cost: false)
          edits.remove_eater(eater)
        end

        expect(text_lines(mail).grep(/Aug 20/)).to eq(
          ["Aug 20, 2026: Changed Sarah Chen's cost from $30.00 to $20.00. Reason: Typed $30 for $20"]
        )
        other_mail = described_class.reconciliation_notify_email(other_cook, reconciliation)
        expect(text_lines(other_mail).grep(/Aug 20/))
          .to eq(['Aug 20, 2026: Added Other Cook as a cook ($5.00). Reason: Two cooks'])
      end

      it 'lists each corrected dinner by its date, and says so for more than one' do
        # The later dinner is corrected first, so the order is the dinners'.
        correct(corrected, 'Typed $30 for $20') do |edits|
          edits.cost(resident, amount: BigDecimal('20'), no_cost: false)
        end
        correct(earlier, 'No receipt') { |edits| edits.remove_cook(resident) }
        two = described_class.reconciliation_notify_email(resident, settle!(cutoff: Date.new(2026, 9, 3)))

        expect(text_lines(two)).to include(
          'An admin corrected your cost on 2 meals settled before. This settlement carries the changes:'
        )
        expect(text_lines(two).grep(/^Aug/)).to eq(
          [
            'Aug 13, 2026: Removed Sarah Chen as a cook ($30.00). Reason: No receipt',
            "Aug 20, 2026: Changed Sarah Chen's cost from $30.00 to $20.00. Reason: Typed $30 for $20"
          ]
        )
        expect(links_in(html_body(two)).map(&:last)).to eq([meal_url(earlier), meal_url(corrected)])
      end

      # The dinner entered first is the later one, so the order of entry
      # is not the order of the dates.
      it 'lists the dinners by date, not in the order they were entered' do
        later = dinner(Date.new(2026, 8, 27))
        sooner = dinner(Date.new(2026, 8, 26))
        settle!(cutoff: Date.new(2026, 8, 27))
        [sooner, later].each do |meal|
          correct(meal, 'Typed $30 for $20') { |edits| edits.cost(resident, amount: BigDecimal('20'), no_cost: false) }
        end
        mail = described_class.reconciliation_notify_email(resident, settle!(cutoff: Date.new(2026, 9, 3)))

        expect(text_lines(mail).grep(/^Aug/).map { |line| line[/\AAug \d+/] }).to eq(['Aug 26', 'Aug 27'])
      end

      # Eight corrections of one dinner. Ruby's sort happens to keep up to
      # seven equal dates in the order it was given them, which is the
      # order they were made, so fewer would not show that order is kept.
      it 'lists the corrections of one dinner in the order they were made' do
        amounts = (21..28).to_a
        amounts.each do |amount|
          correct(corrected, "Fix #{amount}") do |edits|
            edits.cost(resident, amount: BigDecimal(amount), no_cost: false)
          end
        end
        mail = described_class.reconciliation_notify_email(resident, settle!(cutoff: Date.new(2026, 9, 3)))

        expect(text_lines(mail).grep(/^Aug 20/).map { |line| line[/Reason: (.*)\z/, 1] })
          .to eq(amounts.map { |amount| "Fix #{amount}" })
      end

      it 'puts a space between two changes to the cook in one correction' do
        correct(corrected, 'Two fixes') do |edits|
          edits.cost(resident, amount: BigDecimal('25'), no_cost: false)
          edits.cost(resident, amount: BigDecimal('20'), no_cost: false)
        end
        mail = described_class.reconciliation_notify_email(resident, settle!(cutoff: Date.new(2026, 9, 3)))

        expect(text_lines(mail).grep(/^Aug 20/)).to eq(
          ["Aug 20, 2026: Changed Sarah Chen's cost from $30.00 to $25.00. " \
           "Changed Sarah Chen's cost from $25.00 to $20.00. Reason: Two fixes"]
        )
      end

      it 'says a settlement that settles no new meal carries only corrections, in both parts' do
        correct(corrected, 'Typed $30 for $20') do |edits|
          edits.cost(resident, amount: BigDecimal('20'), no_cost: false)
        end
        only = described_class.reconciliation_notify_email(resident, settle!(cutoff: Date.new(2026, 9, 3)))
        sentence = 'This settlement, through Sep 3, 2026, settles no new meals. ' \
                   'It carries corrections to meals settled before.'

        expect(text_lines(only)[3]).to eq(sentence)
        expect(html_body(only).text.squish).to start_with("Common Meals Settled #{sentence} An admin corrected")
      end
    end
  end

  # The common house email (ADR 0011 rule 9): what each person owes or is
  # owed in the settlement, by unit, then the people who had moved out,
  # and a read-only link to the settlement's page. CollectionList's spec
  # covers who is listed where; these cover the words.
  describe '#common_house_collection_email' do
    let(:latest) { Reconciliation.latest_cutoff(community.today) }
    let(:unit) { create(:unit, community: community, name: 'Ash') }
    let(:elm) { create(:unit, community: community, name: 'Elm') }
    let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater One') }
    let(:gone) { create(:resident, community: community, unit: unit, name: 'Gone Away') }
    # Sarah cooks for $30, and two people eat, one of whom moved out
    # before the settlement. Idle Isa ate nothing, so she has no line.
    let(:reconciliation) do
      meal = create(:meal, community: community, date: latest)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
      [eater, gone].each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
      create(:resident, community: community, unit: elm, name: 'Idle Isa')
      gone.update!(active: false)
      settle!(cutoff: latest)
    end
    let(:mail) { described_class.common_house_collection_email(reconciliation) }
    let(:settled_through) { latest.strftime('%b %-d, %Y') }
    let(:url) do
      "http://admin.lvh.me:3000/reconciliations/#{reconciliation.id}?subdomain=admin&token=the-token" \
        '&utf8=%E2%9C%93'
    end
    let(:opening) do
      "The common meals through #{settled_through} are settled. Here is what each person owes or is owed in " \
        'this settlement, by unit. Please collect from each person who owes, and pay each person who is owed.'
    end

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return('the-token')
    end

    def text_lines(mail)
      mail.text_part.body.decoded.rstrip.lines.map(&:chomp)
    end

    it 'sends to the common house email' do
      expect(mail.to).to eq(['commonhouse@swansway.com'])
    end

    it 'names the settlement in the subject' do
      expect(mail.subject).to eq("Balances to collect: common meals settled through #{settled_through}")
    end

    it 'lists each unit and each person in it, then the people who moved out, in words' do
      expect(text_lines(mail)).to eq(
        ['Balances to Collect', '=' * 'Balances to Collect'.length, '', opening, '',
         'Ash: is owed $15.00', '- Eater One: owes $15.00', '- Sarah Chen: is owed $30.00', '',
         'Elm: $0.00', '- Idle Isa: $0.00', '',
         'Moved out', '- Gone Away: owes $15.00', '',
         "The settlement's page shows the meals in it: #{url}", '',
         "~Swan's Way"]
      )
    end

    it 'says the same in the HTML part, with a link to the settlement page' do
      body = html_body(mail)

      expect(body.text.squish).to eq(
        "Balances to Collect #{opening} " \
        'Ash: is owed $15.00 Eater One: owes $15.00 Sarah Chen: is owed $30.00 ' \
        'Elm: $0.00 Idle Isa: $0.00 ' \
        'Moved out Gone Away: owes $15.00 ' \
        "The settlement's page shows the meals in it. ~Swan's Way"
      )
      expect(body.css('h2').map(&:text)).to eq(['Ash: is owed $15.00', 'Elm: $0.00', 'Moved out'])
      expect(links_in(body)).to eq([["The settlement's page", url]])
    end

    it 'says whose units an old settlement shows, and has no moved-out list' do
      reconciliation.update_columns(units_recorded_on: reconciliation.date + 1)
      sentence = "This settlement was made before the app saved each person's unit. These are the units people " \
                 "live in, or last lived in, on #{(reconciliation.date + 1).strftime('%b %-d, %Y')}."

      expect(text_lines(mail)).to include(sentence, 'Ash: $0.00', '- Gone Away: owes $15.00')
      expect(text_lines(mail)).not_to include('Moved out')
      expect(html_body(mail).text.squish).to include(sentence)
    end

    it 'writes the token so that the admin reads back the same token, in both parts' do
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_TOKEN', nil).and_return(token_with_url_characters)

      expect(urls_in(mail).map { |link| token_read_from(link) }).to eq([token_with_url_characters] * 2)
    end

    it_behaves_like 'an HTML part that is one HTML document'
  end
end
