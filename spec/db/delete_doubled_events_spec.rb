# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261012120300_delete_doubled_events.rb')

# The data migration that deletes events saved twice: the same title, start
# and end, almost always a second apart, like a button clicked twice. The
# calendar showed each of them twice. One copy of each stays: the one with
# the most description, and the first one made when they tie.
RSpec.describe DeleteDoubledEvents do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:start) { Time.zone.local(2024, 12, 8, 9) }

  def event(title, description: '', start_date: start, end_date: start + 1.hour, allday: false)
    create(:event, community: community, title: title, description: description,
                   start_date: start_date, end_date: end_date, allday: allday)
  end

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  describe 'up' do
    let!(:first) { event('Work day') }
    let!(:copy) { event('Work day') }
    let!(:third) { event('Work Day ') }

    it 'keeps the first of a group whose descriptions tie, and deletes the rest' do
      migrate(:up)

      expect(Event.where(id: [first.id, copy.id, third.id]).pluck(:id)).to eq([first.id])
    end

    it 'keeps the copy with the most description' do
      blank = event('Zoom meeting', start_date: start + 1.day, end_date: start + 1.day + 1.hour)
      described = event('Zoom meeting', description: 'common zoom', start_date: start + 1.day,
                                        end_date: start + 1.day + 1.hour)

      migrate(:up)

      expect(Event.where(id: [blank.id, described.id]).pluck(:id)).to eq([described.id])
    end

    it 'counts a description by its words, not by spaces at its ends' do
      padded = event('Exec', description: 'Solar contract  ', start_date: start + 2.days,
                             end_date: start + 2.days + 1.hour)
      later = event('Exec', description: 'Solar Contract', start_date: start + 2.days,
                            end_date: start + 2.days + 1.hour)

      migrate(:up)

      expect(Event.where(id: [padded.id, later.id]).pluck(:id)).to eq([padded.id])
    end

    # One description in production ends with a no-break space, which
    # btrim leaves in place.
    it 'does not count a no-break space at the end of a title or a description' do
      plain = event('Exec', description: 'Solar contract', start_date: start + 3.days,
                            end_date: start + 3.days + 1.hour)
      padded = event("Exec\u00a0", description: "Solar Contract\u00a0", start_date: start + 3.days,
                                   end_date: start + 3.days + 1.hour)

      migrate(:up)

      expect(Event.where(id: [plain.id, padded.id]).pluck(:id)).to eq([plain.id])
    end

    it 'leaves events alone that differ in title, start, end or all day' do
      others = [event('Work night'), event('Work day', start_date: start + 1.hour, end_date: start + 2.hours),
                event('Work day', end_date: start + 2.hours)]

      migrate(:up)

      expect(Event.where(id: others.map(&:id)).count).to eq(3)
    end

    it 'prints each event it deleted, with what it held, for the release log' do
      out = migrate(:up)

      expect(out).to include("Deleted event #{copy.id}, a copy of event #{first.id}: \"Work day\"")
      expect(out).to include("Deleted event #{third.id}, a copy of event #{first.id}: \"Work Day \"")
      expect(out).to include('Deleted 2 doubled event(s).')
    end

    it 'does nothing, and says so, when no event is doubled' do
      migrate(:up)

      expect(migrate(:up)).to include('No event is doubled.')
      expect(Event.where(id: first.id)).to exist
    end
  end

  describe 'down' do
    it 'refuses: deleted events cannot come back from here' do
      expect { migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /release log/)
    end
  end
end
