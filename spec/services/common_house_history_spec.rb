# frozen_string_literal: true

require 'rails_helper'

# Before the Common House login existed, the shared screen signed in with
# a resident's account, so its old history rows name that resident.
# CommonHouseHistory.relabel moves the rows that account wrote before a
# cutoff to the Common House login. The account's id and the cutoff are
# inputs, so neither is in the repo.
RSpec.describe CommonHouseHistory do
  let!(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:screen_account) { create(:resident, community: community, unit: unit) }
  let(:someone_else) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }
  let(:cutoff) { Time.iso8601('2021-10-26T00:00:00-07:00') }
  let!(:login) { create(:common_house_login) }

  # A history row by this author, written at this time.
  def audit_by(author, at:)
    audit = Audited::Audit.create!(auditable: meal, action: 'update', user: author, audited_changes: {})
    audit.update_columns(created_at: at)
    audit
  end

  describe '.relabel' do
    it 'moves the rows the account wrote before the cutoff to the Common House login' do
      old = audit_by(screen_account, at: cutoff - 1.second)

      count = described_class.relabel(resident_id: screen_account.id, before: cutoff, write: true)

      expect(count).to eq(1)
      expect(old.reload).to have_attributes(user_type: 'CommonHouseLogin', user_id: login.id)
    end

    # The cutoff is the first moment that is not moved.
    it 'leaves the rows written at the cutoff and after it' do
      kept = [audit_by(screen_account, at: cutoff), audit_by(screen_account, at: cutoff + 1.day)]

      described_class.relabel(resident_id: screen_account.id, before: cutoff, write: true)

      expect(Audited::Audit.where(id: kept).pluck(:user_type, :user_id))
        .to eq([['Resident', screen_account.id]] * 2)
    end

    it "leaves other residents' rows" do
      other = audit_by(someone_else, at: cutoff - 1.day)

      described_class.relabel(resident_id: screen_account.id, before: cutoff, write: true)

      expect(other.reload).to have_attributes(user_type: 'Resident', user_id: someone_else.id)
    end

    # The rows name their author by type and id. An admin row with the
    # resident's id number is a different author.
    it "leaves an admin's rows that carry the same id number" do
      admin_row = audit_by(create(:admin_user), at: cutoff - 1.day)
      admin_row.update_columns(user_id: screen_account.id)

      described_class.relabel(resident_id: screen_account.id, before: cutoff, write: true)

      expect(admin_row.reload).to have_attributes(user_type: 'AdminUser', user_id: screen_account.id)
    end

    it 'without write, counts the rows and changes none' do
      old = audit_by(screen_account, at: cutoff - 1.day)

      count = described_class.relabel(resident_id: screen_account.id, before: cutoff, write: false)

      expect(count).to eq(1)
      expect(old.reload).to have_attributes(user_type: 'Resident', user_id: screen_account.id)
    end

    it 'changes nothing the second time' do
      audit_by(screen_account, at: cutoff - 1.day)
      described_class.relabel(resident_id: screen_account.id, before: cutoff, write: true)

      expect(described_class.relabel(resident_id: screen_account.id, before: cutoff, write: true)).to eq(0)
    end

    it 'makes the history show the row as the Common House' do
      old = audit_by(screen_account, at: cutoff - 1.day)

      described_class.relabel(resident_id: screen_account.id, before: cutoff, write: true)

      expect(AuditSerializer.new(old.reload).to_h[:user_name]).to eq('Common House')
    end

    it 'refuses when no admin has made the Common House login yet' do
      login.delete

      expect { described_class.relabel(resident_id: screen_account.id, before: cutoff, write: true) }
        .to raise_error(CommonHouseHistory::Refused, 'There is no Common House login yet. An admin makes it first.')
    end

    # A typo in the id must not run as "0 rows" with no error.
    it 'refuses an id no resident has' do
      screen_account

      expect { described_class.relabel(resident_id: 0, before: cutoff, write: true) }
        .to raise_error(CommonHouseHistory::Refused, 'No resident has id 0.')
    end

    # Rows written after the login was made may be the resident's own,
    # from their own phone. Refusing this also means every Common House
    # row older than the login came from this task, so the change can be
    # undone exactly.
    it 'refuses a cutoff after the Common House login was made' do
      expect do
        described_class.relabel(resident_id: screen_account.id, before: login.created_at + 1.second, write: true)
      end.to raise_error(CommonHouseHistory::Refused,
                         'The cutoff must not be after the Common House login was made ' \
                         "(#{login.created_at.utc.iso8601}).")
    end
  end

  # A date alone, or a time with no zone, could mean several instants.
  describe '.parse_instant' do
    it 'reads a time with an offset' do
      expect(described_class.parse_instant('2021-10-26T00:00:00-07:00'))
        .to eq(Time.utc(2021, 10, 26, 7))
    end

    it 'reads a time in UTC' do
      expect(described_class.parse_instant('2021-10-26T07:00:00Z')).to eq(Time.utc(2021, 10, 26, 7))
    end

    ['2021-10-26', '2021-10-26T00:00:00', 'yesterday', ''].each do |text|
      it "refuses #{text.inspect}" do
        expect { described_class.parse_instant(text) }
          .to raise_error(CommonHouseHistory::Refused,
                          'BEFORE must be a time with its zone, like 2021-10-26T00:00:00-07:00. ' \
                          "It was #{text.inspect}.")
      end
    end
  end
end
