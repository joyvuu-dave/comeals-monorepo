# frozen_string_literal: true

require 'rails_helper'

# Two sends of one event with the same Idempotency-Key at the same moment:
# the page sent it, heard nothing, and sent it again while the first was
# still running (challenge 30). Both pass the key check before either has
# written, and both insert an event. Exactly one event may be saved, and
# both sends must be answered 200.
#
# What stops the second is PostgreSQL. Each send looked up the key inside
# its transaction and found nothing, so when the first commits its key,
# the second's insert of the same key is refused as a conflict, not as a
# unique violation. RetryOnConflict runs it again, and the lookup finds
# the key. Without a test transaction, because the two sends must see each
# other's commits. prosopite is off: a retry runs the same queries again
# on purpose.
RSpec.describe 'two sends of an event with the same Idempotency-Key at the same moment', prosopite: false do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:resident) { create(:resident, community: community, unit: create(:unit, community: community)) }

  def send_event(token, answers)
    env = Rack::MockRequest.env_for(
      '/api/v1/events', method: 'POST', 'CONTENT_TYPE' => 'application/json',
                        input: JSON.generate(title: 'Work party', start_year: 2026, start_month: 5, start_day: 1,
                                             start_hours: 9, start_minutes: 0, end_hours: 12, end_minutes: 0),
                        'HTTP_AUTHORIZATION' => "Bearer #{token}", 'HTTP_IDEMPOTENCY_KEY' => '"the-same-key"'
    )
    status, headers, body = Rails.application.call(env)
    text = +''
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)
    answers << [status, headers['idempotent-replayed'], JSON.parse(text)['message']]
  end

  it 'saves one event and answers both sends 200, the second as replayed' do
    token = resident.keys.first.token
    answers = Queue.new

    outcomes = at_the_same_moment([/\AINSERT INTO "events"/, -> { send_event(token, answers) }],
                                  [/\AINSERT INTO "events"/, -> { send_event(token, answers) }])

    expect(outcomes).to eq(%i[ok ok])
    expect(Array.new(answers.size) { answers.pop }).to contain_exactly(
      [200, nil, 'Event has been created'], [200, 'true', 'Event has been created']
    )
    expect(Event.count).to eq(1)
    expect(RequestKey.count).to eq(1)
  end
end
