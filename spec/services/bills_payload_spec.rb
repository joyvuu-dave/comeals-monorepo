# frozen_string_literal: true

require 'rails_helper'

# A bills save as a client sends it: a list of edits, each one cook's
# add, change or remove, with the values the page saw (#135). The request
# specs (spec/requests/api/v1/update_bills_spec.rb) prove the endpoint;
# this pins the rules where they live: one sentence per thing that can be
# wrong with the body, and what each edit does to the stored bill.
RSpec.describe BillsPayload do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Bob') }
  let(:other) { create(:resident, community: community, unit: unit, name: 'Carol') }
  let(:meal) { create(:meal, community: community) }

  # The body as the controller gets it.
  def parse(body)
    described_class.parse(ActionController::Parameters.new(body.deep_stringify_keys))
  end

  def edits(*list)
    parse(edits: list)
  end

  def values(amount, no_cost: false)
    { amount: amount, no_cost: no_cost }
  end

  def adding(resident, to)
    { op: 'add', resident_id: resident.id, to: to }
  end

  def changing(resident, from, to)
    { op: 'change', resident_id: resident.id, from: from, to: to }
  end

  def removing(resident, from)
    { op: 'remove', resident_id: resident.id, from: from }
  end

  def bill_for(resident, amount, no_cost: false)
    create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal(amount), no_cost: no_cost)
  end

  # What the controller reads under the meal lock before it writes.
  def stored
    meal.bills.reload.index_by(&:resident_id)
  end

  def rows
    meal.bills.reload.to_h { |b| [b.resident_id, [b.amount, b.no_cost]] }
  end

  describe 'a body in the old format' do
    it 'is out of date when it has a bills key, whatever else it has' do
      expect(parse(bills: [{ resident_id: cook.id }])).to be_outdated
      expect(parse(bills: [], edits: [])).to be_outdated
      expect(parse(bills: '')).to be_outdated
    end

    it 'says so as its error, and is not valid' do
      payload = parse(bills: [])

      expect(payload.error).to eq('Nothing was saved, because this page is out of date. ' \
                                  'Please reload the page and enter the costs again.')
      expect(payload).not_to be_valid
    end

    it 'is not out of date without a bills key' do
      expect(parse(edits: [])).not_to be_outdated
      expect(parse({})).not_to be_outdated
    end
  end

  describe 'the checks, in order' do
    def error_of(*list)
      edits(*list).error
    end

    let(:list_error) { 'edits must be a list of changes.' }
    let(:op_error) { "Each edit's op must be add, change or remove." }
    let(:sides_error) { "'from' and 'to' each need amount and no_cost." }
    let(:no_cost_error) { 'no_cost must be true or false.' }

    def amount_error(shown)
      "Invalid amount: #{shown}. Amounts are text with whole cents, 0 to 9999.99, like \"25.50\"."
    end

    # A form-encoded empty list arrives as one empty string, and a body
    # without the key as nil.
    it 'refuses anything that is not a list of edits' do
      expect(parse({}).error).to eq(list_error)
      expect(parse(edits: '').error).to eq(list_error)
      expect(parse(edits: { op: 'add' }).error).to eq(list_error)
      expect(parse(edits: ['12.00']).error).to eq(list_error)
      expect(parse(edits: [adding(cook, values('1')), '12.00']).error).to eq(list_error)
    end

    it 'refuses an op that is not add, change or remove' do
      expect(error_of(adding(cook, values('1')).merge(op: 'replace'))).to eq(op_error)
      expect(error_of(adding(cook, values('1')).merge(op: 'Add'))).to eq(op_error)
      expect(error_of(adding(cook, values('1')).except(:op))).to eq(op_error)
    end

    it 'refuses the wrong sides for the op' do
      both = { from: values('1'), to: values('2') }
      expect(error_of({ op: 'add', resident_id: cook.id }.merge(both))).to eq("An add has 'to' and no 'from'.")
      expect(error_of(op: 'add', resident_id: cook.id)).to eq("An add has 'to' and no 'from'.")
      expect(error_of(op: 'change', resident_id: cook.id, to: values('2'))).to eq("A change has 'from' and 'to'.")
      expect(error_of(op: 'change', resident_id: cook.id, from: values('1'))).to eq("A change has 'from' and 'to'.")
      expect(error_of({ op: 'remove', resident_id: cook.id }.merge(both))).to eq("A remove has 'from' and no 'to'.")
      expect(error_of(op: 'remove', resident_id: cook.id)).to eq("A remove has 'from' and no 'to'.")
    end

    it 'takes a side sent as null as a side left out' do
      expect(edits(adding(cook, values('1')).merge(from: nil))).to be_valid
      expect(edits(removing(cook, values('1')).merge(to: nil))).to be_valid
      expect(error_of(changing(cook, nil, values('1')))).to eq("A change has 'from' and 'to'.")
    end

    it 'refuses a side that is not an object with both amount and no_cost' do
      expect(error_of(adding(cook, '12.00'))).to eq(sides_error)
      expect(error_of(adding(cook, { amount: '12.00' }))).to eq(sides_error)
      expect(error_of(adding(cook, { no_cost: false }))).to eq(sides_error)
      expect(error_of(removing(cook, ['12.00', false]))).to eq(sides_error)
    end

    it 'refuses an amount that is not whole cents from 0 to 9999.99, quoting the text sent' do
      ['1.005', '1e3', '10000', '-5', 'abc', ' 5', '5.', '.5', '0x10'].each do |text|
        expect(error_of(adding(cook, values(text)))).to eq(amount_error(text)), text
      end
    end

    # Rails reads a JSON number as a Float, so 25.499999999999999 would
    # arrive as 25.5 and pass the grammar (money rule 1: never Float).
    it 'refuses an amount that is not text, showing it as JSON' do
      expect(error_of(adding(cook, values(25.5)))).to eq(amount_error('25.5'))
      expect(error_of(adding(cook, values(12)))).to eq(amount_error('12'))
      expect(error_of(adding(cook, values(nil)))).to eq(amount_error('null'))
      expect(error_of(adding(cook, values(true)))).to eq(amount_error('true'))
    end

    # Ruby writes a list or an object another way than JSON does
    # ([1, 2] and {"value" => "1"}), and the client sent JSON.
    it 'shows an amount sent as a list or an object as the JSON it was' do
      expect(error_of(adding(cook, values([1, 2])))).to eq(amount_error('[1,2]'))
      expect(error_of(adding(cook, values({ value: '1' })))).to eq(amount_error('{"value":"1"}'))
    end

    it 'refuses a no_cost that is not true or false' do
      [nil, 'yes', 1, '1', 'TRUE', ''].each do |flag|
        expect(error_of(adding(cook, values('1', no_cost: flag)))).to eq(no_cost_error), flag.inspect
      end
    end

    it 'takes no_cost as the text a form-encoded body sends' do
      payload = edits(adding(cook, values('', no_cost: 'true')), adding(other, values('3', no_cost: 'false')))

      expect(payload).to be_valid
      expect(payload.write_to(meal, stored)).to be_nil
      expect(rows).to eq(cook.id => [BigDecimal('0'), true], other.id => [BigDecimal('3'), false])
    end

    it 'checks from before to, and in each side the shape, then the amount, then no_cost' do
      expect(error_of(changing(cook, values('x', no_cost: 'no'), values('y')))).to eq(amount_error('x'))
      expect(error_of(changing(cook, values('1', no_cost: 'no'), values('y')))).to eq(no_cost_error)
      expect(error_of(changing(cook, values('1'), { amount: 'y' }))).to eq(sides_error)
    end

    it 'checks every edit before the cooks, and stops at the first problem' do
      expect(error_of({ op: 'x', resident_id: 0 }, adding(cook, values('y')))).to eq(op_error)
      expect(error_of(adding(cook, values('1')), adding(cook, values('y')))).to eq(amount_error('y'))
      expect(error_of({ op: 'add', resident_id: 0, to: values('1') }, adding(cook, values('y'))))
        .to eq(amount_error('y'))
    end

    it 'refuses the same cook twice, by number, after the edits themselves' do
      expect(error_of(adding(cook, values('1')), removing(cook, values('1')).merge(resident_id: cook.id.to_s)))
        .to eq("Duplicate cook in edits: resident ##{cook.id}.")
    end

    it 'refuses a cook who is not a resident, after the duplicates' do
      expect(error_of(adding(cook, values('1')).merge(resident_id: 0))).to eq('Resident not found.')
      expect(error_of({ op: 'add', resident_id: 0, to: values('1') }, { op: 'add', resident_id: 0, to: values('1') }))
        .to eq('Duplicate cook in edits: resident #0.')
    end

    it 'refuses a resident id that is missing or is not a whole number, as a cook who is not a resident' do
      [nil, 'abc', '7.0', 7.0, '', ' 7', '-7'].each do |id|
        expect(error_of(adding(cook, values('1')).merge(resident_id: id))).to eq('Resident not found.'), id.inspect
      end
      expect(error_of(adding(cook, values('1')).except(:resident_id))).to eq('Resident not found.')
    end

    # Ids that are not whole numbers are not counted as cooks here, so
    # two of them do not hide a cook who is named twice after them.
    it 'finds the same cook twice after two resident ids that are not whole numbers' do
      not_numbers = [adding(other, values('1')).merge(resident_id: 'abc'),
                     adding(other, values('1')).except(:resident_id)]

      expect(error_of(*not_numbers, adding(cook, values('1')), removing(cook, values('1'))))
        .to eq("Duplicate cook in edits: resident ##{cook.id}.")
    end

    it 'takes a resident id as the string of digits a form-encoded body sends' do
      expect(edits(adding(cook, values('1')).merge(resident_id: cook.id.to_s))).to be_valid
    end

    # Ruby's Integer() reads a leading 0 as base 8, so "01000010" would be
    # resident 262152. The id is set here so that it is over 7: for 0 to 7
    # the two bases read the same number.
    it 'reads a resident id with a leading zero in base 10' do
      ten = create(:resident, community: community, unit: unit, name: 'Ten', id: 1_000_010)
      payload = edits(adding(ten, values('1')).merge(resident_id: '01000010'))

      expect(payload).to be_valid
      expect(payload.write_to(meal, stored)).to be_nil
      expect(rows).to eq(ten.id => [BigDecimal('1'), false])
    end

    it 'accepts a blank amount, which is zero, and the largest whole-cent amount' do
      expect(edits(adding(cook, values('')), adding(other, values('9999.99')))).to be_valid
    end

    it 'accepts an empty list' do
      expect(edits).to be_valid
    end

    it 'is valid with no error' do
      payload = edits(adding(cook, values('12.50')))

      expect(payload.error).to be_nil
      expect(payload).to be_valid
      expect(payload).not_to be_outdated
    end
  end

  # Each row of the outcome table: the edit, the stored bill for its cook,
  # and what happens. "Same" is the same amount by value and the same
  # no_cost.
  describe '#write_to' do
    def write(*list)
      edits(*list).write_to(meal, stored)
    end

    describe 'an add' do
      it 'creates the bill when the cook has none' do
        expect(write(adding(cook, values('12.50')))).to be_nil
        expect(rows).to eq(cook.id => [BigDecimal('12.5'), false])
      end

      it 'is done, and writes nothing, when the cook already has those values' do
        bill = bill_for(cook, '12.5')

        expect { expect(write(adding(cook, values('12.50')))).to be_nil }.not_to(change { bill.reload.updated_at })
      end

      it 'is refused when the cook already has other values' do
        bill_for(cook, '7')

        expect(write(adding(cook, values('12.50'))))
          .to eq('Nothing was saved, because this meal changed after you loaded it: Bob is already a cook. ' \
                 'Check the cooks and costs, then enter your change again.')
        expect(rows).to eq(cook.id => [BigDecimal('7'), false])
      end
    end

    describe 'a change' do
      it 'is done, and writes nothing, when the bill already has the new values' do
        bill = bill_for(cook, '9')

        expect { expect(write(changing(cook, values('5'), values('9.00')))).to be_nil }
          .not_to(change { bill.reload.updated_at })
      end

      it 'writes the new values when the bill still has the values the page saw' do
        bill_for(cook, '5')

        expect(write(changing(cook, values('5.0'), values('9.25')))).to be_nil
        expect(rows).to eq(cook.id => [BigDecimal('9.25'), false])
      end

      it 'is refused when the bill has other values' do
        bill_for(cook, '6')

        expect(write(changing(cook, values('5'), values('9'))))
          .to eq("Nothing was saved, because this meal changed after you loaded it: Bob's cost changed. " \
                 'Check the cooks and costs, then enter your change again.')
        expect(rows).to eq(cook.id => [BigDecimal('6'), false])
      end

      it 'is refused when the cook has no bill any more, and does not make one' do
        expect(write(changing(cook, values('5'), values('9'))))
          .to eq('Nothing was saved, because this meal changed after you loaded it: Bob is no longer a cook. ' \
                 'Check the cooks and costs, then enter your change again.')
        expect(rows).to eq({})
      end

      # The page turns no-cost on by sending a blank amount with it.
      it 'writes zero and the flag when no-cost is turned on' do
        bill_for(cook, '12')

        expect(write(changing(cook, values('12.0'), values('', no_cost: true)))).to be_nil
        expect(rows).to eq(cook.id => [BigDecimal('0'), true])
      end

      it 'compares no_cost too, not only the amount' do
        bill_for(cook, '0', no_cost: true)

        expect(write(changing(cook, values('0'), values('4')))).to include("Bob's cost changed")
        expect(rows).to eq(cook.id => [BigDecimal('0'), true])
      end

      it 'compares the amounts as numbers, so a blank amount is zero and 5 is 5.00' do
        bill_for(cook, '0')
        bill_for(other, '5')

        expect(write(changing(cook, values(''), values('1')), changing(other, values('5.00'), values('6')))).to be_nil
        expect(rows).to eq(cook.id => [BigDecimal('1'), false], other.id => [BigDecimal('6'), false])
      end

      # The page never sends one, but it is a fair question to ask.
      it 'checks and writes nothing when from and to are the same' do
        bill_for(cook, '5')

        expect(write(changing(cook, values('5'), values('5')))).to be_nil
        expect(write(changing(cook, values('4'), values('4')))).to include("Bob's cost changed")
      end
    end

    describe 'a remove' do
      it 'is done when the cook has no bill' do
        expect(write(removing(cook, values('5')))).to be_nil
        expect(rows).to eq({})
      end

      it 'removes the bill when it still has the values the page saw' do
        bill_for(cook, '5')

        expect(write(removing(cook, values('5.00')))).to be_nil
        expect(rows).to eq({})
      end

      it 'is refused when the bill has other values' do
        bill_for(cook, '50')

        expect(write(removing(cook, values('0'))))
          .to eq("Nothing was saved, because this meal changed after you loaded it: Bob's cost changed. " \
                 'Check the cooks and costs, then enter your change again.')
        expect(rows).to eq(cook.id => [BigDecimal('50'), false])
      end
    end

    describe 'several edits' do
      it 'writes nothing when any one is refused, and names every refused cook in the order sent' do
        dan = create(:resident, community: community, unit: unit, name: 'Dan')
        bill_for(cook, '6')
        bill_for(dan, '1')

        message = write(changing(dan, values('1'), values('2')), changing(cook, values('5'), values('9')),
                        changing(other, values('5'), values('9')))

        expect(message).to eq('Nothing was saved, because this meal changed after you loaded it: ' \
                              "Bob's cost changed and Carol is no longer a cook. " \
                              'Check the cooks and costs, then enter your change again.')
        expect(rows).to eq(cook.id => [BigDecimal('6'), false], dan.id => [BigDecimal('1'), false])
      end

      it 'leaves alone a cook the edits do not name' do
        bill_for(other, '40')

        expect(write(adding(cook, values('20')))).to be_nil
        expect(rows).to eq(other.id => [BigDecimal('40'), false], cook.id => [BigDecimal('20'), false])
      end

      it 'swaps one cook for another as a remove and an add' do
        bill_for(cook, '5')

        expect(write(removing(cook, values('5')), adding(other, values('5.00')))).to be_nil
        expect(rows).to eq(other.id => [BigDecimal('5'), false])
      end

      # prosopite watches this file. A new bill's validation reads its
      # cook, so without the record the check loaded, two adds would read
      # two residents from the same line. A change reads no cook.
      it 'reads each cook once, however many edits it writes' do
        dan = create(:resident, community: community, unit: unit, name: 'Dan')
        eve = create(:resident, community: community, unit: unit, name: 'Eve')
        bill_for(cook, '1')
        bill_for(other, '2')
        statements = []
        record = ->(*, event) { statements << event[:sql] }

        ActiveSupport::Notifications.subscribed(record, 'sql.active_record') do
          expect(write(changing(cook, values('1'), values('3')), changing(other, values('2'), values('4')),
                       adding(dan, values('5')), adding(eve, values('6')))).to be_nil
        end

        expect(statements.grep(/FROM "residents"/).size).to eq(1)
        expect(rows.transform_values(&:first))
          .to eq(cook.id => BigDecimal('3'), other.id => BigDecimal('4'), dan.id => BigDecimal('5'),
                 eve.id => BigDecimal('6'))
      end
    end
  end

  # What the server keeps next to an Idempotency-Key, to tell the same
  # save sent again from another save that reuses its key (decision 6 of
  # #135). It is the SHA-256 of what the edits ask for, so it does not
  # change with the parts of the body that say nothing about the bills.
  #
  # prosopite is off for the examples that compare payloads: each parse
  # looks up its cooks, once, as one request does, and parsing several
  # payloads in one example repeats that lookup from the same line.
  describe '#fingerprint' do
    let(:change) { changing(cook, values('5.0'), values('7.00')) }

    def fingerprint(body)
      parse(body).fingerprint
    end

    it 'is the SHA-256 of each edit as [op, resident id, from, to], with amounts as numbers' do
      dan = create(:resident, community: community, unit: unit, name: 'Dan')
      payload = edits(change, removing(other, values('', no_cost: true)), adding(dan, values('1.5')))

      asked = [['change', cook.id, ['5.0', false], ['7.0', false]],
               ['remove', other.id, ['0.0', true], nil],
               ['add', dan.id, nil, ['1.5', false]]]

      expect(payload).to be_valid
      expect(payload.fingerprint).to eq(Digest::SHA256.hexdigest(JSON.generate(asked)))
    end

    it 'is the same for amounts written another way, ids sent as text, and a socket id or token',
       prosopite: false do
      expect(fingerprint(edits: [change])).to eq(fingerprint(
                                                   edits: [{ op: 'change', resident_id: cook.id.to_s,
                                                             from: { amount: '5', no_cost: 'false' },
                                                             to: { amount: '7', no_cost: false } }],
                                                   socket_id: '1.2', token: 'abc'
                                                 ))
    end

    it 'differs when an amount, a no_cost, a cook, the op or the order differs', prosopite: false do
      prints = [
        [change],
        [changing(cook, values('5.0'), values('7.01'))],
        [changing(cook, values('5.0'), values('7.00', no_cost: true))],
        [changing(cook, values('5.0', no_cost: true), values('7.00'))],
        [changing(other, values('5.0'), values('7.00'))],
        [adding(cook, values('7.00'))],
        [removing(cook, values('7.00'))],
        [change, adding(other, values('1'))],
        [adding(other, values('1')), change],
        []
      ].map { |list| fingerprint(edits: list) }

      expect(prints.uniq.size).to eq(prints.size)
    end
  end
end
