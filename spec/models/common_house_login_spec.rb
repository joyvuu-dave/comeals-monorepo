# frozen_string_literal: true

# == Schema Information
#
# Table name: common_house_logins
#
#  id               :bigint           not null, primary key
#  keys_valid_since :datetime         not null
#  password_digest  :string           not null
#  singleton_guard  :integer          default(0), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_common_house_logins_on_singleton_guard  (singleton_guard) UNIQUE
#
require 'rails_helper'

RSpec.describe CommonHouseLogin do
  include ActiveSupport::Testing::TimeHelpers

  let(:password) { 'a long shared password' }

  describe 'one row only' do
    it 'refuses a second login through the model' do
      described_class.create!(password: password)
      second = described_class.new(password: password)

      expect(second).not_to be_valid
      expect(second.errors[:base]).to include('There is already a Common House login. Change its password instead.')
    end

    it 'refuses a second row that skips the model' do
      described_class.create!(password: password)
      row = { password_digest: 'x', created_at: Time.current, updated_at: Time.current }

      expect { described_class.insert_all!([row]) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'refuses a row whose guard is not 0, so the unique index cannot be stepped around' do
      row = { password_digest: 'x', singleton_guard: 1, created_at: Time.current, updated_at: Time.current }

      expect { described_class.insert_all!([row]) }
        .to raise_error(ActiveRecord::StatementInvalid, /singleton_guard_is_zero/)
    end
  end

  describe '#authenticate' do
    let(:login) { described_class.create!(password: password) }

    it 'returns the login for the right password' do
      expect(login.authenticate(password)).to eq(login)
    end

    it 'returns false for a wrong password' do
      expect(login.authenticate('not it')).to be(false)
    end

    it 'returns false for no password' do
      expect(login.authenticate(nil)).to be(false)
    end
  end

  describe 'the password' do
    it 'must be at least 12 characters' do
      login = described_class.new(password: 'a' * 11)

      expect(login).not_to be_valid
      expect(login.errors[:password]).to include('must be at least 12 characters')
    end

    it 'cannot be blank, unlike a resident password' do
      login = described_class.new(password: '')

      expect(login).not_to be_valid
    end

    it 'must match its confirmation, when one is given' do
      login = described_class.new(password: password, password_confirmation: 'something else')

      expect(login).not_to be_valid
      expect(login.errors[:password_confirmation]).to include("doesn't match Password")
    end

    it 'is required when the login is created' do
      expect(described_class.new).not_to be_valid
    end

    it 'is stored only as a digest' do
      login = described_class.create!(password: password)

      expect(login.reload.password_digest).not_to include(password)
    end
  end

  describe 'changing the password' do
    it 'signs out every screen signed in before the change' do
      login = described_class.create!(password: password)
      before = login.keys_valid_since

      travel 1.minute do
        login.update!(password: 'another long password')
      end

      expect(login.reload.keys_valid_since).to be > before
    end

    it 'leaves sessions alone when something else is saved' do
      login = described_class.create!(password: password)
      before = login.reload.keys_valid_since

      travel 1.minute do
        login.touch
      end

      expect(login.reload.keys_valid_since).to eq(before)
    end
  end

  it 'refuses to be deleted, because the history names it' do
    login = described_class.create!(password: password)

    expect(login.destroy).to be(false)
    expect(described_class.exists?(login.id)).to be(true)
  end

  it 'leaves the digest and the session time out of its JSON' do
    login = described_class.create!(password: password)

    expect(login.serializable_hash.keys).not_to include('password_digest', 'keys_valid_since')
  end

  # The resident sign-in form takes it, so it must be an address the
  # resident model would take, except for its .invalid ending.
  describe 'EMAIL' do
    it 'is the reserved address' do
      expect(described_class::EMAIL).to eq('common-house@comeals.invalid')
    end

    it 'has the form of an email address' do
      expect(described_class::EMAIL).to match(Resident::VALID_EMAIL_REGEX)
    end
  end
end
