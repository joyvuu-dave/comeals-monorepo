# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261013120400_clear_rotation_marks_set_by_hand.rb')

# The data migration that takes the "residents notified" marks off the
# rotations that have not started yet and that nobody was mailed about.
# In production they were set by hand on 2026-07-11 (issue #39) while
# broadcast email sent nothing.
RSpec.describe ClearRotationMarksSetByHand do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:today) { community.today }
  let(:marked_at) { Time.zone.parse('2026-07-11 22:08:22') }

  # A rotation with one meal on each date given, marked notified.
  def rotation(*dates, marked: true)
    create(:rotation, community: community).tap do |made|
      dates.each { |date| create(:meal, community: community, rotation: made, date: date) }
      made.update_columns(residents_notified: marked, new_rotation_notified_at: (marked_at if marked))
    end
  end

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  def marks(made)
    made.reload.then { |row| [row.residents_notified, row.new_rotation_notified_at] }
  end

  it 'takes both marks off a rotation that starts after today' do
    upcoming = rotation(today + 1, today + 4)

    migrate(:up)

    expect(marks(upcoming)).to eq([false, nil])
  end

  it 'leaves a rotation that started today or before, even if it ends later' do
    started = rotation(today, today + 3)
    past = rotation(today - 30, today - 27)

    migrate(:up)

    expect([marks(started), marks(past)]).to eq([[true, marked_at], [true, marked_at]])
  end

  it 'leaves a rotation that someone was mailed about' do
    mailed = rotation(today + 7)
    MailDelivery.record!(mailer: 'rotation_signup_email', about: mailed,
                         resident: create(:resident, community: community))

    migrate(:up)

    expect(marks(mailed)).to eq([true, marked_at])
  end

  it 'leaves a rotation the app marked on purpose when it was made without email' do
    made_without_email = rotation(today + 10, marked: false)
    made_without_email.update_columns(new_rotation_notified_at: marked_at)

    migrate(:up)

    expect(marks(made_without_email)).to eq([false, marked_at])
  end

  it 'prints the rotations it changed, for the release log, and not the ones it left' do
    upcoming = rotation(today + 1)
    later = rotation(today + 30)
    rotation(today + 60, marked: false)

    ids = [upcoming.id, later.id].sort.join(', ')
    expect(migrate(:up)).to include("Took the notified marks off rotation(s) #{ids}, which start after today " \
                                    'and nobody was mailed about.')
  end

  it 'does nothing, and says so, when no rotation matches' do
    rotation(today - 1)

    expect(migrate(:up)).to include('No rotation that has not started is marked notified')
  end

  it 'refuses to run down: the release log names the rotations' do
    expect { migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /release log/)
  end

  it_behaves_like 'a data migration that tries a conflict again', described_class
end
