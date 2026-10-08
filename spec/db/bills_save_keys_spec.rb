# frozen_string_literal: true

require 'rails_helper'

# The rules of the bills_save_keys table, which PostgreSQL holds for every
# write path, the model's included. A key row is written in the same
# transaction as the bills it stands for (Api::V1::MealsController#save_bills).
RSpec.describe 'the bills_save_keys table' do
  let(:community) { create(:community) }
  let(:meal) { create(:meal, community: community) }
  let(:fingerprint) { Digest::SHA256.hexdigest('[]') }

  # Raw SQL, past the model. Each insert in a savepoint, so a refused one
  # leaves the example's transaction usable for the next.
  def insert(meal_id: meal.id, key: 'k', edits_sha256: fingerprint, created_at: 'now()')
    connection = ActiveRecord::Base.connection
    connection.transaction(requires_new: true) do
      connection.exec_query(
        "INSERT INTO bills_save_keys (meal_id, key, edits_sha256, created_at) VALUES ($1, $2, $3, #{created_at})",
        'insert', [meal_id, key, edits_sha256]
      )
    end
  end

  # The unique index is what makes "the same key twice" impossible, even
  # for two saves that each looked and found no key. The race itself is
  # in spec/requests/api/v1/bills_idempotency_key_race_spec.rb.
  it 'refuses a second row with the same key for the same meal' do
    insert(key: 'same')

    expect { insert(key: 'same') }
      .to raise_error(ActiveRecord::RecordNotUnique, /index_bills_save_keys_on_meal_id_and_key/)
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
      expect { insert(key: key) }.to raise_error(ActiveRecord::StatementInvalid, /bills_save_keys_key_printable/)
    end
  end

  it 'refuses a fingerprint that is not a SHA-256 in lowercase hex' do
    expect { insert(edits_sha256: fingerprint.upcase) }
      .to raise_error(ActiveRecord::StatementInvalid, /bills_save_keys_edits_sha256_hex/)
    expect { insert(edits_sha256: fingerprint[0, 63]) }
      .to raise_error(ActiveRecord::StatementInvalid, /bills_save_keys_edits_sha256_hex/)
  end

  it 'refuses a row with no meal, key, fingerprint or time' do
    expect { insert(meal_id: nil) }.to raise_error(ActiveRecord::NotNullViolation)
    expect { insert(key: nil) }.to raise_error(ActiveRecord::NotNullViolation)
    expect { insert(edits_sha256: nil) }.to raise_error(ActiveRecord::NotNullViolation)
    expect { insert(created_at: 'NULL') }.to raise_error(ActiveRecord::NotNullViolation)
  end

  it 'refuses a meal that does not exist' do
    expect { insert(meal_id: 0) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  # A key says only that a save for this meal was written. When the meal
  # goes (an open meal that never happened, CLAUDE.md "Deletion policy"),
  # its keys mean nothing and go with it.
  it 'is deleted with its meal' do
    insert(key: 'k')

    meal.destroy!

    expect(ActiveRecord::Base.connection.select_value('SELECT count(*) FROM bills_save_keys')).to eq(0)
  end
end
