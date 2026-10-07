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
# `permit_params` in app/admin/<resource>.rb. Each value differs from the
# column's default, so a dropped field shows up as the default: a boolean
# is sent as the value it does not start with.
RSpec.describe 'Admin permit_params smoke tests' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:zone) { ActiveSupport::TimeZone[community.timezone] }

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
            phone: '510-555-2671',
            password: 'password123',
            vegetarian: true,
            kind: 'adult',
            unit_id: unit.id,
            can_cook: false,
            active: false
          }
        }
      end.to change(Resident, :count).by(1)

      resident = Resident.find_by(email: 'smoke@example.com')
      expect(resident).not_to be_nil
      expect(resident.name).to eq('Smoke Test Resident')
      expect(resident.birthday).to eq(Date.new(1990, 4, 15))
      expect(resident.phone).to eq('+15105552671')
      expect(resident.vegetarian).to be true
      # kind: 'adult' agrees with the birthday, so it cannot show here
      # whether kind reached the model. resident_form_spec.rb's 'refuses
      # Adult with a birthday that makes a child' does show it.
      expect(resident).not_to be_child
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
            allday: '1'
          }
        }
      end.to change(Event, :count).by(1)

      event = Event.find_by(title: 'Smoke Event')
      expect(event).not_to be_nil
      expect(event.description).to eq('A smoke test event')
      expect(event.start_date).to eq(zone.local(2026, 5, 1, 18))
      expect(event.end_date).to eq(zone.local(2026, 5, 1, 20))
      expect(event.allday).to be true
      expect(event.community_id).to eq(community.id)
    end
  end

  describe 'POST /units (admin)' do
    it 'persists every form field' do
      expect do
        post '/units', params: {
          unit: { name: 'Smoke Unit' }
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
            date: '2026-05-15'
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
            end_date: '2026-05-20 16:00:00'
          }
        }
      end.to change(CommonHouseReservation, :count).by(1)

      chr = CommonHouseReservation.last
      expect(chr.resident_id).to eq(resident.id)
      expect(chr.title).to eq('Smoke Booking')
      expect(chr.start_date).to eq(zone.local(2026, 5, 20, 14))
      expect(chr.end_date).to eq(zone.local(2026, 5, 20, 16))
      expect(chr.community_id).to eq(community.id)
    end
  end

  describe 'POST /meals (admin)' do
    let(:rotation) { create(:rotation, community: community) }

    # The guest is a child: FULL is the column default, so a dropped
    # multiplier would save a full-price guest without an error.
    it 'persists every form field including nested associations' do
      host = create(:resident, community: community, unit: unit, multiplier: 2)

      expect do
        post '/meals', params: {
          meal: {
            date: '2026-06-01',
            rotation_id: rotation.id,
            closed: '0',
            guests_attributes: {
              '0' => { multiplier: Multiplier::HALF, resident_id: host.id, _destroy: '0' }
            }
          }
        }
      end.to change(Meal, :count).by(1)

      meal = Meal.find_by(date: Date.new(2026, 6, 1))
      expect(meal).not_to be_nil
      expect(meal.community_id).to eq(community.id)
      expect(meal.rotation_id).to eq(rotation.id)
      expect(meal.guests.count).to eq(1)
      expect(meal.guests.first.resident_id).to eq(host.id)
      expect(meal.guests.first.multiplier).to eq(Multiplier::HALF)
    end

    # closed defaults to false, and max is kept only on a closed meal
    # (Meal#conditionally_set_max), so the two are checked together.
    it 'persists closed and max' do
      post '/meals', params: { meal: { date: '2026-06-03', rotation_id: rotation.id, closed: '1', max: '5' } }

      meal = Meal.find_by(date: Date.new(2026, 6, 3))
      expect(meal).not_to be_nil
      expect(meal.closed).to be true
      expect(meal.max).to eq(5)
    end

    # attendee_ids assignment removes MealResident rows via the through
    # association — never through a form param. It must not be permitted
    # (issue #7); attendance changes go through the API, where the model
    # guards and audit hooks run per row.
    it 'ignores attendee_ids' do
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      post '/meals', params: {
        meal: {
          date: '2026-06-02',
          rotation_id: rotation.id,
          closed: false,
          attendee_ids: [eater.id.to_s]
        }
      }

      meal = Meal.find_by(date: Date.new(2026, 6, 2))
      expect(meal).not_to be_nil
      expect(meal.attendees).to be_empty
    end
  end

  describe 'POST /admin_users (admin)' do
    it 'persists every form field' do
      expect do
        post '/admin_users', params: {
          admin_user: {
            email: 'smoke-admin@example.com',
            phone: '510-555-2671',
            password: 'newpassword123',
            password_confirmation: 'newpassword123'
          }
        }
      end.to change(AdminUser, :count).by(1)

      created = AdminUser.find_by(email: 'smoke-admin@example.com')
      expect(created).not_to be_nil
      expect(created.community_id).to eq(community.id)
      expect(created.phone).to eq('+15105552671')
      expect(created.valid_password?('newpassword123')).to be true
    end
  end
end
