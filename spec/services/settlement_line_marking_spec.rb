# frozen_string_literal: true

require 'rails_helper'

# Marking a settlement line Paid or Let go (ADR 0011 rule 8). Each change
# is a new mark, the newest counts, and a change made on a page that did
# not see the newest mark saves nothing.
RSpec.describe SettlementLineMarking do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin) { create(:admin_user, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:eater) { create(:resident, community: community, unit: unit) }
  let(:line) do
    meal = create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    settle!.reconciliation_balances.find_by!(resident: eater)
  end

  def mark(status, note: nil, seen: line.reload.newest_mark&.id)
    described_class.mark!(line, status: status, note: note, by: admin, seen: seen)
  end

  it 'marks a line Paid, with a note, and records who and when' do
    made = mark('paid', note: '  paid $20 of $40 ')

    expect(made).to have_attributes(status: 'paid', note: 'paid $20 of $40', admin_user: admin)
    expect(line.reload.current_mark).to eq(made)
  end

  it 'keeps every change, and the newest counts' do
    paid = mark('paid')
    let_go = mark('let_go', note: 'Moved away')

    expect(line.reload.marks).to eq([paid, let_go])
    expect(line.current_mark).to eq(let_go)
    expect(line.amount).to eq(BigDecimal('-30'))
  end

  it 'takes a mark off, and keeps the old one in the history' do
    paid = mark('paid')
    off = mark('none', note: 'Marked by mistake')

    expect(line.reload.current_mark).to be_nil
    expect(line.newest_mark).to eq(off)
    expect(line.marks).to eq([paid, off])
  end

  it 'saves nothing when the line was marked after the page was loaded' do
    seen_nothing = nil
    mark('paid')

    expect { mark('let_go', seen: seen_nothing) }.to raise_error(described_class::Changed, /after the page was loaded/)
    expect(line.reload.marks.size).to eq(1)
  end

  it "saves nothing when the mark and the note are the line's already" do
    mark('paid', note: 'Cash')

    expect { mark('paid', note: ' Cash ') }
      .to raise_error(described_class::NothingChanged, 'This line is marked Paid already, with the same note.')
    expect(mark('paid', note: 'Check').note).to eq('Check')
  end

  it 'saves nothing when a line with no mark is given No mark' do
    expect { mark('none') }.to raise_error(described_class::NothingChanged, 'This line has no mark already.')
    expect(line.reload.marks).to be_empty
  end

  it 'refuses a status it does not know' do
    expect { mark('forgiven') }
      .to raise_error(ActiveRecord::RecordInvalid, /Status must be Paid, Let go or No mark/)
  end
end
