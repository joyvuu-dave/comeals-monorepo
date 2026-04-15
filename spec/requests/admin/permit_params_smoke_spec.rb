# frozen_string_literal: true

require 'rails_helper'

# Smoke tests for ActiveAdmin permit_params declarations.
#
# Each ActiveAdmin resource declares `permit_params :a, :b, ...`. When Rails'
# global `permit_all_parameters` flag is enabled, these declarations are
# decorative — any param flows through. With strong params enforced, every
# attribute submitted by an admin form must appear in `permit_params` or it's
# silently dropped, leaving records partially populated and tests passing.
#
# These specs POST to each admin create endpoint with the actual fields the
# admin form submits and verify the resulting record has every attribute set.
# A missing attribute means the corresponding field is missing from
# `permit_params` in app/admin/<resource>.rb.
RSpec.describe 'Admin permit_params smoke tests' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  describe 'POST /residents (admin)' do
    it 'persists every form field' do
      expect do
        post '/residents', params: {
          resident: {
            name: 'Smoke Test Resident',
            birthday: '1990-04-15',
            email: 'smoke@example.com',
            password: 'password123',
            vegetarian: true,
            multiplier: 1,
            unit_id: unit.id,
            can_cook: false,
            active: false,
            community_id: community.id
          }
        }
      end.to change(Resident, :count).by(1)

      resident = Resident.find_by(email: 'smoke@example.com')
      expect(resident).not_to be_nil
      expect(resident.name).to eq('Smoke Test Resident')
      expect(resident.birthday).to eq(Date.new(1990, 4, 15))
      expect(resident.vegetarian).to be true
      expect(resident.multiplier).to eq(1)
      expect(resident.unit_id).to eq(unit.id)
      expect(resident.can_cook).to be false
      expect(resident.active).to be false
      expect(resident.authenticate('password123')).to eq(resident)
    end
  end

  describe 'POST /events (admin)' do
    it 'persists every form field' do
      expect do
        post '/events', params: {
          event: {
            title: 'Smoke Event',
            description: 'A smoke test event',
            start_date: '2026-05-01 18:00:00',
            end_date: '2026-05-01 20:00:00',
            allday: false,
            community_id: community.id
          }
        }
      end.to change(Event, :count).by(1)

      event = Event.find_by(title: 'Smoke Event')
      expect(event).not_to be_nil
      expect(event.description).to eq('A smoke test event')
      expect(event.allday).to be false
      expect(event.community_id).to eq(community.id)
    end
  end

  describe 'POST /units (admin)' do
    it 'persists every form field' do
      expect do
        post '/units', params: {
          unit: { name: 'Smoke Unit', community_id: community.id }
        }
      end.to change(Unit, :count).by(1)

      smoke_unit = Unit.find_by(name: 'Smoke Unit')
      expect(smoke_unit).not_to be_nil
      expect(smoke_unit.community_id).to eq(community.id)
    end
  end

  describe 'POST /guest_room_reservations (admin)' do
    it 'persists every form field' do
      resident = create(:resident, community: community, unit: unit, multiplier: 2)

      expect do
        post '/guest_room_reservations', params: {
          guest_room_reservation: {
            resident_id: resident.id,
            date: '2026-05-15',
            community_id: community.id
          }
        }
      end.to change(GuestRoomReservation, :count).by(1)

      grr = GuestRoomReservation.last
      expect(grr.resident_id).to eq(resident.id)
      expect(grr.date).to eq(Date.new(2026, 5, 15))
      expect(grr.community_id).to eq(community.id)
    end
  end

  describe 'POST /common_house_reservations (admin)' do
    it 'persists every form field' do
      resident = create(:resident, community: community, unit: unit, multiplier: 2)

      expect do
        post '/common_house_reservations', params: {
          common_house_reservation: {
            resident_id: resident.id,
            title: 'Smoke Booking',
            start_date: '2026-05-20 14:00:00',
            end_date: '2026-05-20 16:00:00',
            community_id: community.id
          }
        }
      end.to change(CommonHouseReservation, :count).by(1)

      chr = CommonHouseReservation.last
      expect(chr.resident_id).to eq(resident.id)
      expect(chr.title).to eq('Smoke Booking')
      expect(chr.community_id).to eq(community.id)
    end
  end

  describe 'POST /meals (admin)' do
    it 'persists every form field including nested associations' do
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      host = create(:resident, community: community, unit: unit, multiplier: 2)

      expect do
        post '/meals', params: {
          meal: {
            date: '2026-06-01',
            community_id: community.id,
            closed: false,
            attendee_ids: [eater.id.to_s],
            guests_attributes: {
              '0' => { multiplier: 2, resident_id: host.id, _destroy: '0' }
            }
          }
        }
      end.to change(Meal, :count).by(1)

      meal = Meal.find_by(date: Date.new(2026, 6, 1))
      expect(meal).not_to be_nil
      expect(meal.community_id).to eq(community.id)
      expect(meal.attendees).to include(eater)
      expect(meal.guests.count).to eq(1)
      expect(meal.guests.first.resident_id).to eq(host.id)
    end
  end

  describe 'POST /admin_users (admin)' do
    it 'persists every form field' do
      expect do
        post '/admin_users', params: {
          admin_user: {
            email: 'smoke-admin@example.com',
            password: 'newpassword123',
            password_confirmation: 'newpassword123',
            community_id: community.id
          }
        }
      end.to change(AdminUser, :count).by(1)

      created = AdminUser.find_by(email: 'smoke-admin@example.com')
      expect(created).not_to be_nil
      expect(created.community_id).to eq(community.id)
      expect(created.valid_password?('newpassword123')).to be true
    end
  end
end
