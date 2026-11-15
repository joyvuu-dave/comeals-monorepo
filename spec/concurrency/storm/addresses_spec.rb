# frozen_string_literal: true

require 'rails_helper'

# Which address each storm client sends from, and the two judgments made
# from the counts per address (spec/support/storm/addresses.rb).
RSpec.describe Storm::Addresses do
  subject(:addresses) { described_class.new(shared: 3) }

  let(:now) { 1_800_000_000 } # the start of a minute and of a 5-minute window

  describe '#address_for' do
    it 'gives the first `shared` clients one address, and every other client its own' do
      expect(Array.new(5) { |index| addresses.address_for(index) })
        .to eq(([described_class::SHARED] * 3) + ['10.9.0.4', '10.9.0.5'])
    end

    it 'gives every client its own address when `shared` is 1' do
      expect(described_class.new(shared: 1).address_for(0)).to eq('10.9.0.1')
    end

    it 'goes on to the next block of 250' do
      expect(addresses.address_for(250)).to eq('10.9.1.1')
    end
  end

  describe '#throttled_with_reason?' do
    it 'counts the sends of every client on the address together' do
      600.times { addresses.note_sent(described_class::SHARED, false, now) }
      expect(addresses.throttled_with_reason?(described_class::SHARED, false, now)).to be(false)

      addresses.note_sent(described_class::SHARED, false, now)
      expect(addresses.throttled_with_reason?(described_class::SHARED, false, now)).to be(true)
      expect(addresses.throttled_with_reason?('10.9.0.4', false, now)).to be(false)
    end

    it 'counts the window before, for a request sent at the edge' do
      601.times { addresses.note_sent('10.9.0.4', false, now - 1) }

      expect(addresses.throttled_with_reason?('10.9.0.4', false, now)).to be(true)
      expect(addresses.throttled_with_reason?('10.9.0.4', false, now + 60)).to be(false)
    end

    it 'counts logins against the login limit only for a login' do
      21.times { addresses.note_sent('10.9.0.4', true, now) }

      expect(addresses.throttled_with_reason?('10.9.0.4', true, now)).to be(true)
      expect(addresses.throttled_with_reason?('10.9.0.4', false, now)).to be(false)
    end

    it 'says what an address sent, for a problem' do
      addresses.note_sent('10.9.0.4', true, now)

      expect(addresses.sent_from('10.9.0.4')).to eq([60, now / 60] => 1, [300, now / 300] => 1)
    end
  end

  describe '#count_problems' do
    def counted(address, count, window: now / 60)
      ThrottleCount.set("rack::attack:#{window}:api/ip:#{address}", count, expires_at: 1.minute.from_now)
    end

    before { 10.times { addresses.note_sent(described_class::SHARED, false, now) } }

    it 'finds nothing when the server counted what the clients sent' do
      counted(described_class::SHARED, 10)

      expect(addresses.count_problems(clients: 3)).to eq([])
    end

    it 'allows one request per client in flight at each edge of the windows' do
      counted(described_class::SHARED, 4)

      expect(addresses.count_problems(clients: 3)).to eq([])
    end

    it 'names an address whose count the server lost' do
      counted(described_class::SHARED, 3)

      expect(addresses.count_problems(clients: 3))
        .to eq(["address #{described_class::SHARED} (3 clients): the server counted 3 API requests " \
                "in windows [#{now / 60}], but its clients sent 10"])
    end

    it 'names an address with no rows, when nothing deletes them' do
      expect(addresses.count_problems(clients: 3))
        .to eq(["address #{described_class::SHARED}: the server has no throttle_counts row for it"])
    end

    it 'leaves out an address with no rows when the hourly cleanup may have deleted them' do
      expect(addresses.count_problems(clients: 3, rows_may_be_deleted: true)).to eq([])
    end
  end

  describe '#summary' do
    it "shows the shared address's count on the server next to what its clients sent" do
      2.times { addresses.note_sent(described_class::SHARED, false, now) }
      ThrottleCount.set("rack::attack:#{now / 60}:api/ip:#{described_class::SHARED}", 2, expires_at: 1.minute.from_now)

      expect(addresses.summary(clients: 5))
        .to eq("throttle counts: #{described_class::SHARED} (3 clients) sent 2 API requests, the server counted 2")
    end

    it 'says when no clients share an address' do
      expect(described_class.new(shared: 1).summary(clients: 5))
        .to eq('throttle counts: no shared address (STORM_SHARED_ADDRESS=1)')
    end
  end
end
