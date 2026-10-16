# frozen_string_literal: true

require 'rails_helper'

# The words and the form for a settlement line's mark (ADR 0011 rule 8),
# read as the page gets them. The request spec
# (spec/requests/admin/settlement_marks_spec.rb) checks the page around
# them; this one checks every word and every field the helper writes.
RSpec.describe SettlementMarkHelper do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin) { create(:admin_user, community: community, email: 'helper@example.com') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Dana Diner') }
  let(:line) do
    meal = create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today))
    cook = create(:resident, community: community, unit: unit)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    settle!.reconciliation_balances.find_by!(resident: eater)
  end

  # A mark made on Jan 5, so a day with one digit shows how the date is
  # written.
  def mark(status, note: nil)
    SettlementLineMark.create!(reconciliation_balance: line, status: status, note: note, admin_user: admin,
                               created_at: Time.zone.local(2027, 1, 5, 12))
  end

  describe '#settlement_mark_words' do
    it 'is an empty string for a line with no mark' do
      expect(helper.settlement_mark_words(nil)).to eq('')
    end

    it 'says the mark, its note, and who made it and when' do
      expect(helper.settlement_mark_words(mark('paid', note: 'paid $20 of $30')))
        .to eq('<strong>Paid</strong> <div>paid $20 of $30</div> ' \
               '<div class="mark-by">by helper@example.com, Jan 5, 2027</div>')
    end

    it 'leaves out the note when there is none' do
      expect(helper.settlement_mark_words(mark('let_go')))
        .to eq('<strong>Let go</strong> <div class="mark-by">by helper@example.com, Jan 5, 2027</div>')
    end

    it 'says when, and not who, to the read-only link' do
      words = Current.set(read_only_admin_token: 'the-token') { helper.settlement_mark_words(mark('paid')) }

      expect(words).to eq('<strong>Paid</strong> <div class="mark-by">Jan 5, 2027</div>')
    end
  end

  describe '#settlement_mark_form' do
    def form(let_go_allowed:)
      html = helper.settlement_mark_form('/settlement_line_marks', line.reload, let_go_allowed: let_go_allowed)
      Nokogiri::HTML.fragment(html).at_css('form')
    end

    # Each field as [tag, type, name, value]; the select gives its
    # selected value.
    def fields(form)
      form.css('input, select').map do |field|
        value = field.name == 'select' ? field.at_css('option[selected]')&.[]('value') : field['value']
        [field.name, field['type'], field['name'], value]
      end
    end

    def options(form)
      form.css('select option').map { |option| [option.text, option['value']] }
    end

    it 'posts the line, the newest mark it showed, the status and the note, and nothing more' do
      newest = mark('paid', note: 'Cash')
      form = form(let_go_allowed: false)

      expect(form.attributes.transform_values(&:value))
        .to include('action' => '/settlement_line_marks', 'method' => 'post', 'class' => 'settlement-mark')
      expect(fields(form)).to eq(
        [['input', 'hidden', 'line_id', line.id.to_s], ['input', 'hidden', 'seen', newest.id.to_s],
         ['select', nil, 'status', 'paid'], %w[input text note Cash], ['input', 'submit', nil, 'Save']]
      )
    end

    it 'names the person on each field, for a screen reader, and gives no field an id' do
      form = form(let_go_allowed: false)

      expect(form.css('[aria-label]').pluck('aria-label'))
        .to eq(['Mark for Dana Diner', 'Note for Dana Diner', 'Save the mark for Dana Diner'])
      expect(form.at_css('input[name=note]')['placeholder']).to eq('Note')
      expect(form.at_css('input[type=submit]')['data-disable-with']).to eq('Save')
      expect(form.css('[id]')).to be_empty
    end

    it 'puts a space between the fields' do
      form = form(let_go_allowed: false)

      expect(form.children.map { |node| node.text? ? node.text : node.name })
        .to eq(['input', ' ', 'input', ' ', 'select', ' ', 'input', ' ', 'input'])
    end

    it 'offers Paid and No mark, and starts on Paid, for a line with no mark' do
      form = form(let_go_allowed: false)

      expect(options(form)).to eq([%w[Paid paid], ['No mark', 'none']])
      expect(fields(form)).to eq(
        [['input', 'hidden', 'line_id', line.id.to_s], ['input', 'hidden', 'seen', nil],
         ['select', nil, 'status', 'paid'], ['input', 'text', 'note', nil], ['input', 'submit', nil, 'Save']]
      )
    end

    it 'offers Let go too, to an admin who may set it' do
      expect(options(form(let_go_allowed: true))).to eq([%w[Paid paid], ['Let go', 'let_go'], ['No mark', 'none']])
    end

    # The mark was taken off: the line has no mark now, but the change
    # must still name the mark that took it off, or it is refused.
    it 'sends the newest mark, even one that took the mark off, and starts on Paid with no note' do
      mark('paid', note: 'Cash')
      off = mark('none', note: 'By mistake')

      expect(fields(form(let_go_allowed: false))).to eq(
        [['input', 'hidden', 'line_id', line.id.to_s], ['input', 'hidden', 'seen', off.id.to_s],
         ['select', nil, 'status', 'paid'], ['input', 'text', 'note', nil], ['input', 'submit', nil, 'Save']]
      )
    end

    it 'shows a line marked Let go, with its note, to an admin who may change it' do
      newest = mark('let_go', note: 'Moved away')
      form = form(let_go_allowed: true)

      expect(fields(form)).to eq(
        [['input', 'hidden', 'line_id', line.id.to_s], ['input', 'hidden', 'seen', newest.id.to_s],
         ['select', nil, 'status', 'let_go'], ['input', 'text', 'note', 'Moved away'],
         ['input', 'submit', nil, 'Save']]
      )
    end

    it 'gives no form for a line marked Let go to an admin who may not change it, and says why' do
      mark('let_go')

      expect(helper.settlement_mark_form('/settlement_line_marks', line.reload, let_go_allowed: false))
        .to eq('Only a superuser can change a Let go mark.')
    end
  end
end
