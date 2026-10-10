# frozen_string_literal: true

require 'rails_helper'

# The rules of the guest_add_keys table, which PostgreSQL holds for every
# write path, the model's included. A key row is written in the same
# transaction as the guest it stands for (Api::V1::MealsController#create_guest).
RSpec.describe 'the guest_add_keys table' do
  let(:community) { create(:community) }
  let(:meal) { create(:meal, community: community) }
  let(:host) { create(:resident, community: community) }

  # Raw SQL, past the model. Each insert in a savepoint, so a refused one
  # leaves the example's transaction usable for the next.
  def insert(created_at: 'now()', **columns)
    row = { meal_id: meal.id, key: 'k', resident_id: host.id, vegetarian: false, guest_id: nil }.merge(columns)
    connection = ActiveRecord::Base.connection
    connection.transaction(requires_new: true) do
      connection.exec_query(
        'INSERT INTO guest_add_keys (meal_id, key, resident_id, vegetarian, guest_id, created_at) ' \
        "VALUES ($1, $2, $3, $4, $5, #{created_at})",
        'insert', row.values_at(:meal_id, :key, :resident_id, :vegetarian, :guest_id)
      )
    end
  end

  def rows
    ActiveRecord::Base.connection.select_rows('SELECT key, guest_id FROM guest_add_keys ORDER BY key')
  end

  # The unique index is what makes "the same key twice" impossible, even
  # for two adds that each looked and found no key. The race itself is
  # in spec/requests/api/v1/guest_idempotency_key_race_spec.rb.
  it 'refuses a second row with the same key for the same meal' do
    insert(key: 'same')

    expect { insert(key: 'same') }
      .to raise_error(ActiveRecord::RecordNotUnique, /index_guest_add_keys_on_meal_id_and_key/)
  end

  it 'takes the same key for another meal' do
    other = create(:meal, community: community, date: meal.date - 1)
    insert(key: 'same')

    expect { insert(meal_id: other.id, key: 'same') }.not_to raise_error
  end

  it 'takes a key of 1 to 255 printable ASCII characters, spaces included' do
    expect { insert(key: 'a') }.not_to raise_error
    expect { insert(key: 'a' * 255) }.not_to raise_error
    expect { insert(key: ' !"~') }.not_to raise_error
  end

  {
    'an empty key' => '',
    'a key of 256 characters' => 'a' * 256,
    'a key with a tab' => "a\tb",
    'a key that is not ASCII' => 'café'
  }.each do |what, key|
    it "refuses #{what}" do
      expect { insert(key: key) }.to raise_error(ActiveRecord::StatementInvalid, /guest_add_keys_key_printable/)
    end
  end

  it 'refuses a row with no meal, key, host, flag or time' do
    expect { insert(meal_id: nil) }.to raise_error(ActiveRecord::NotNullViolation)
    expect { insert(key: nil) }.to raise_error(ActiveRecord::NotNullViolation)
    expect { insert(resident_id: nil) }.to raise_error(ActiveRecord::NotNullViolation)
    expect { insert(vegetarian: nil) }.to raise_error(ActiveRecord::NotNullViolation)
    expect { insert(created_at: 'NULL') }.to raise_error(ActiveRecord::NotNullViolation)
  end

  it 'refuses a meal, a host or a guest that does not exist' do
    expect { insert(meal_id: 0) }.to raise_error(ActiveRecord::InvalidForeignKey)
    expect { insert(resident_id: 0) }.to raise_error(ActiveRecord::InvalidForeignKey)
    expect { insert(guest_id: 0) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  # A key says only that a guest add for this meal was written. When the
  # meal goes (an open meal that never happened, CLAUDE.md "Deletion
  # policy"), its keys mean nothing and go with it.
  it 'is deleted with its meal' do
    insert(key: 'k')

    meal.destroy!

    expect(rows).to eq([])
  end

  # A resident can be deleted only when they have no guests, sign-ups or
  # bills (a resident made by mistake). Their keys go with them.
  it 'is deleted with its host' do
    insert(key: 'k')

    host.destroy!

    expect(rows).to eq([])
  end

  # When the guest is removed the key stays, so a tap sent again still
  # adds nothing, and the row no longer names the guest.
  it 'keeps the row when its guest is removed, with no guest' do
    guest = create(:guest, meal: meal, resident: host)
    insert(key: 'k', guest_id: guest.id)

    guest.destroy!

    expect(rows).to eq([['k', nil]])
  end
end
