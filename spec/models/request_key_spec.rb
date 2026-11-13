# frozen_string_literal: true

require 'rails_helper'

# The key of a calendar write, a guest remove or a settle that was saved
# (ADR 0015). What a second send gets is in
# spec/requests/api/v1/request_keys_spec.rb; this file is the model's own
# rules.
#
# The hash examples are described by a sentence, not by '.request_sha256',
# so mutant runs them for sent_body and sorted too, which only
# request_sha256 calls (docs/mutation-testing.md, "Which examples run for
# a subject").
# == Schema Information
#
# Table name: request_keys
#
#  id             :bigint           not null, primary key
#  body           :jsonb            not null
#  key            :text             not null
#  request_sha256 :text             not null
#  sender         :text             not null
#  status         :integer          not null
#  created_at     :datetime         not null
#
# Indexes
#
#  index_request_keys_on_created_at      (created_at)
#  index_request_keys_on_sender_and_key  (sender,key) UNIQUE
#
RSpec.describe RequestKey do
  def request(path, method: 'POST', body: nil, type: 'application/json')
    env = Rack::MockRequest.env_for(path, method: method, input: body.to_s)
    env['CONTENT_TYPE'] = type if body
    ActionDispatch::Request.new(env)
  end

  def hash_of(...)
    described_class.request_sha256(request(...))
  end

  describe 'the hash of a request' do
    it 'is the SHA-256 of the method, the path and the sent parameters with their keys sorted at every level' do
      sent = '{"b":{"d":[{"z":1,"y":2}],"c":2},"a":1}'

      expect(hash_of('/api/v1/events', body: sent))
        .to eq(Digest::SHA256.hexdigest(%(POST /api/v1/events\n{"a":1,"b":{"c":2,"d":[{"y":2,"z":1}]}})))
    end

    it 'keeps the order of a list, because the order of a list can be part of the change' do
      expect(hash_of('/api/v1/events', body: '{"ids":[1,2]}'))
        .not_to eq(hash_of('/api/v1/events', body: '{"ids":[2,1]}'))
    end

    it 'leaves out who sent it and the browser connection, which can be new on the second send' do
      plain = hash_of('/api/v1/events', body: '{"title":"Potluck"}')
      extras = '{"title":"Potluck","socket_id":"1.2","push_token":"p","controller":"x","action":"y"}'
      with_extras = hash_of('/api/v1/events?token=abc&format=json', body: extras)

      expect(with_extras).to eq(plain)
    end

    it 'counts the query string as part of the request' do
      expect(hash_of('/api/v1/events?day=1', body: '{"title":"Potluck"}'))
        .to eq(Digest::SHA256.hexdigest(%(POST /api/v1/events\n{"day":"1","title":"Potluck"})))
    end

    it 'differs when the method, the path or a value differs' do
      base = hash_of('/api/v1/events/4', method: 'PATCH', body: '{"title":"Potluck"}')

      expect([
               hash_of('/api/v1/events/4', method: 'POST', body: '{"title":"Potluck"}'),
               hash_of('/api/v1/events/5', method: 'PATCH', body: '{"title":"Potluck"}'),
               hash_of('/api/v1/events/4', method: 'PATCH', body: '{"title":"Picnic"}')
             ]).to all(satisfy { |other| other != base })
    end

    it 'reads a form body as a form' do
      expect(hash_of('/api/v1/events', body: 'title=Potluck&b=2', type: 'application/x-www-form-urlencoded'))
        .to eq(Digest::SHA256.hexdigest(%(POST /api/v1/events\n{"b":"2","title":"Potluck"})))
    end

    it 'keeps a JSON body that is not an object under _json, as Rails does' do
      expect(hash_of('/api/v1/events', body: '[1,2]'))
        .to eq(Digest::SHA256.hexdigest(%(POST /api/v1/events\n{"_json":[1,2]})))
    end

    it 'is the hash of no parameters for an empty JSON body, which JSON.parse would refuse' do
      env = Rack::MockRequest.env_for('/api/v1/events/4/delete', method: 'DELETE')
      env['CONTENT_TYPE'] = 'application/json'

      expect(described_class.request_sha256(ActionDispatch::Request.new(env)))
        .to eq(Digest::SHA256.hexdigest(%(DELETE /api/v1/events/4/delete\n{})))
    end

    # Rack 3 lets a server leave rack.input out, and then raw_post is nil.
    it 'is the hash of no parameters for a request with no body stream at all' do
      env = Rack::MockRequest.env_for('/api/v1/events/4/delete', method: 'DELETE')
      env.delete('rack.input')

      expect(described_class.request_sha256(ActionDispatch::Request.new(env)))
        .to eq(Digest::SHA256.hexdigest(%(DELETE /api/v1/events/4/delete\n{})))
    end

    it 'is the hash of no parameters when nothing was sent' do
      expect(hash_of('/api/v1/events/4/delete', method: 'DELETE'))
        .to eq(Digest::SHA256.hexdigest(%(DELETE /api/v1/events/4/delete\n{})))
    end
  end

  describe '.sender_of' do
    it 'names the kind of login and its id' do
      resident = create(:resident)
      login = create(:common_house_login)

      expect([described_class.sender_of(resident), described_class.sender_of(login)])
        .to eq(["Resident:#{resident.id}", "CommonHouseLogin:#{login.id}"])
    end
  end

  describe '.delete_expired' do
    let(:now) { Time.zone.parse('2026-11-12 12:00:00') }

    def key_made_at(time, key)
      described_class.create!(sender: 'Resident:1', key: key, request_sha256: 'a' * 64,
                              status: 200, body: {}, created_at: time)
    end

    it 'deletes the keys made more than 7 days ago, keeps the rest, and says how many it deleted' do
      key_made_at(now - 7.days - 1.second, 'just-over')
      key_made_at(now - 30.days, 'long-ago')
      key_made_at(now - 7.days, 'exactly-seven-days')
      key_made_at(now - 1.minute, 'new')

      expect(described_class.delete_expired(now: now)).to eq(2)
      expect(described_class.pluck(:key)).to contain_exactly('exactly-seven-days', 'new')
    end

    it 'reads the time now when it is not given one' do
      key_made_at(8.days.ago, 'old')
      key_made_at(6.days.ago, 'new')

      described_class.delete_expired

      expect(described_class.pluck(:key)).to eq(['new'])
    end

    # A keyed write looks up its key and then adds one at SERIALIZABLE, so
    # it can make PostgreSQL refuse the delete, as with BillsSaveKey.
    it 'tries again when PostgreSQL refuses the delete for a conflict, with the tries a scheduled job gets' do
      allow(RetryOnConflict).to receive(:call).and_call_original
      key_made_at(now - 8.days, 'old')

      described_class.delete_expired(now: now)

      expect(RetryOnConflict).to have_received(:call)
        .with(attempts: RecurringJob::CONFLICT_ATTEMPTS, base_delay: RecurringJob::CONFLICT_BASE_DELAY)
      expect(described_class.count).to eq(0)
    end
  end
end
