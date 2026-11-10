# frozen_string_literal: true

require 'rails_helper'

# RetryOnConflict runs a write again when PostgreSQL refuses it for a
# conflict with another transaction. It does not retry inside an open
# transaction, so these examples run with no test transaction. A second
# try runs the same queries as the first, on purpose, so the N+1 check is
# off.
RSpec.describe 'A resident profile, a write that PostgreSQL refuses for a conflict', prosopite: false do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:resident) { create(:resident, community: community, name: 'Ann Lee', email: 'ann@example.com') }
  let(:headers) { { 'Authorization' => "Bearer #{JwtAuth.encode(resident)}" } }

  def save(fields)
    patch '/api/v1/profile', params: fields, headers: headers, as: :json
  end

  def fields(**changes)
    { name: resident.name, vegetarian: resident.vegetarian, email: resident.email }.merge(changes)
  end

  def message
    response.parsed_body['message']
  end

  def emailed_token
    mail = ActionMailer::Base.deliveries.rfind { |m| m.subject == 'Confirm your new email' }
    mail.text_part.body.to_s[/confirm-email#token=(\S+)/, 1]
  end

  def confirm(token)
    post '/api/v1/profile/email-confirm', params: { email_token: token }, as: :json
  end

  before do
    ActionMailer::Base.deliveries.clear
    allow(RetryOnConflict).to receive(:sleep)
  end

  # The first call raises the error PostgreSQL gives for a conflict. Every
  # later call runs the real method.
  def refuse_first(object, method)
    refused = false
    allow(object).to receive(method).and_wrap_original do |original, *args|
      next original.call(*args) if refused

      refused = true
      raise ActiveRecord::SerializationFailure, 'could not serialize access due to read/write dependencies'
    end
  end

  # At the first call, another connection takes the waiting change off
  # and commits. The request has read the row by then, and has not yet
  # written it.
  def cancel_from_another_connection_at_first(object, method)
    done = false
    allow(object).to receive(method).and_wrap_original do |original, *args|
      unless done
        done = true
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Resident.where(id: resident.id)
                    .update_all(pending_email: nil, email_change_token_digest: nil, email_change_sent_at: nil)
          end
        end.join
      end
      original.call(*args)
    end
  end

  it 'saves the profile on the second try' do
    refuse_first(ProfileUpdate, :save)
    save(fields(vegetarian: true))

    expect(response).to have_http_status(:ok)
    expect(resident.reload.vegetarian).to be(true)
  end

  it 'sends the link again on the second try' do
    save(fields(email: 'ann.new@example.com'))
    refuse_first(EmailChange, :start)
    post '/api/v1/profile/email-link', headers: headers

    expect(response).to have_http_status(:ok)
  end

  it 'opens the link on the second try' do
    save(fields(email: 'ann.new@example.com'))
    token = emailed_token
    refuse_first(EmailChange, :cancel)
    confirm(token)

    expect(response).to have_http_status(:ok)
    expect(resident.reload.email).to eq('ann.new@example.com')
  end

  # The read of the row and the write must be in one transaction. Then
  # PostgreSQL refuses the write, and the second try sees no change.
  # Earlier in the request, ApiController found the resident with the same
  # query that restart_email_change runs. Until RetryOnConflict turned the
  # query cache off, the cache answered it with no SQL, the transaction's
  # first SQL was the UPDATE, and PostgreSQL saw no conflict. The UPDATE
  # wrote only the digest and the time, and the CHECK
  # residents_email_change_all_or_none refused the row: a 500.
  it 'sends no new link for a change that another request took off at the same moment' do
    save(fields(email: 'ann.new@example.com'))
    cancel_from_another_connection_at_first(EmailChange, :start)
    post '/api/v1/profile/email-link', headers: headers

    expect(response).to have_http_status(:bad_request)
    expect(message).to eq(Api::V1::ProfilesController::NOTHING_WAITING)
    expect(resident.reload.pending_email).to be_nil
  end

  it 'does not change the email when another request took the change off at the same moment' do
    save(fields(email: 'ann.new@example.com'))
    token = emailed_token
    cancel_from_another_connection_at_first(EmailChange, :cancel)
    confirm(token)

    expect(response).to have_http_status(:bad_request)
    expect(message).to eq(EmailChange::UNKNOWN)
    expect(resident.reload.email).to eq('ann@example.com')
  end
end
