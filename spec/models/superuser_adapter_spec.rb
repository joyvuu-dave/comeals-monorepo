# frozen_string_literal: true

require 'rails_helper'

# Adapter logic in isolation. spec/requests/admin/superuser_authorization_spec.rb
# proves ActiveAdmin actually invokes it end-to-end through routing.
RSpec.describe SuperuserAdapter do
  let(:community) { create(:community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }
  let(:admin) { create(:admin_user, community: community, superuser: false) }

  def adapter_for(user)
    described_class.new(nil, user)
  end

  def write_actions
    %i[new create edit update destroy]
  end

  # Asserts every write action against every model, naming the pair that failed.
  def expect_writes(user, models, allowed:)
    models.each do |model|
      klass = model.is_a?(String) ? model.constantize : model
      write_actions.each do |action|
        result = adapter_for(user).authorized?(action, klass)
        expect(result).to be(allowed), "#{action} on #{klass}: expected #{allowed}, got #{result}"
      end
    end
  end

  describe 'reading' do
    it 'allows every signed-in admin to read anything' do
      expect(adapter_for(admin).authorized?(:read)).to be true
      expect(adapter_for(admin).authorized?(:read, Bill)).to be true
      expect(adapter_for(admin).authorized?(:read, AdminUser)).to be true
    end
  end

  describe 'a superuser' do
    it 'may write on the money path' do
      expect_writes(superuser, described_class::LEDGER_MODELS, allowed: true)
    end

    it 'may write on the governance models' do
      expect(adapter_for(superuser).authorized?(:update, AdminUser)).to be true
      expect(adapter_for(superuser).authorized?(:update, Community)).to be true
    end

    it 'may write on everything else' do
      expect(adapter_for(superuser).authorized?(:create, Event)).to be true
    end
  end

  describe 'creating a Community' do
    it 'is allowed while none exists, which is the bootstrap step' do
      # `community` is a lazy let, so not referencing it leaves the table empty
      # — the same state a fresh deployment starts in.
      bootstrap_admin = create(:admin_user, community: nil, superuser: true)
      expect(Community.exists?).to be false

      expect(adapter_for(bootstrap_admin).authorized?(:new, Community)).to be true
      expect(adapter_for(bootstrap_admin).authorized?(:create, Community)).to be true
    end

    it 'is refused once one exists, for a superuser too' do
      community # create the singleton

      expect(adapter_for(superuser).authorized?(:new, Community)).to be false
      expect(adapter_for(superuser).authorized?(:create, Community)).to be false
      expect(adapter_for(admin).authorized?(:new, Community)).to be false
    end

    it 'does not block editing the community that exists' do
      community

      expect(adapter_for(superuser).authorized?(:edit, Community)).to be true
      expect(adapter_for(superuser).authorized?(:update, community)).to be true
    end
  end

  describe 'a plain admin' do
    it 'may not write on the money path' do
      expect_writes(admin, described_class::LEDGER_MODELS, allowed: false)
    end

    it 'may not grant admin access or change community settings' do
      expect(adapter_for(admin).authorized?(:update, AdminUser)).to be false
      expect(adapter_for(admin).authorized?(:update, Community)).to be false
    end

    it 'may write on everything that is not money or governance' do
      expect_writes(admin, [Resident, Unit, Event, Rotation, CommonHouseReservation, GuestRoomReservation],
                    allowed: true)
    end

    # Editing a resident's price category never reaches back into a settled
    # meal, because attendance snapshots its own multiplier. That is what
    # makes Resident safe to leave open — if it stops being true, this
    # boundary has to move.
    it 'may edit residents, whose multiplier is snapshotted onto attendance' do
      expect(adapter_for(admin).authorized?(:update, Resident)).to be true
      expect(MealResident.column_names).to include('multiplier')
    end

    it 'is refused a write it cannot identify, rather than allowed by default' do
      expect(adapter_for(admin).authorized?(:update, nil)).to be false
      expect(adapter_for(admin).authorized?(:update, Object.new)).to be false
    end
  end

  describe 'a read-only token request' do
    before { Current.read_only_admin_token = true }

    after { Current.read_only_admin_token = nil }

    it 'may read the resources the emails link to' do
      described_class::TOKEN_READABLE_MODELS.each do |model|
        result = adapter_for(admin).authorized?(:read, model.constantize)
        expect(result).to be(true), "expected token to read #{model}"
      end
    end

    it 'may not read admin accounts or community settings' do
      expect(adapter_for(admin).authorized?(:read, AdminUser)).to be false
      expect(adapter_for(admin).authorized?(:read, Community)).to be false
    end

    # The whole point of moving this rule off the account and onto the
    # request: pointing READ_ONLY_ADMIN_ID at a superuser must not turn a
    # mailed link into a write-capable one.
    it 'writes nothing even when the account behind the token is a superuser' do
      expect_writes(superuser, [Bill, Event], allowed: false)
    end

    # ActiveAdmin redirects an unauthorized request to the dashboard, so
    # refusing the dashboard would make every denial a redirect loop.
    it 'may still read the dashboard, which is the redirect target for denials' do
      expect(adapter_for(admin).authorized?(:read)).to be true
    end
  end
end
