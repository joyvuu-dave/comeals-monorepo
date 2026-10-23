# frozen_string_literal: true

require 'rails_helper'

# A reset token that is still live is as good as the password, so it must
# never be written to a log. Two logs see every request line: Rails's own
# ("Started GET ...") and Heroku's router, which records the path and the
# query of every request and which this app cannot filter. Rails's
# filter_parameters hides a parameter's value in the "Parameters:" line,
# but not in the path. So the token never travels in a path or a query:
#
# - The emailed link carries it after the #, in the fragment. A browser
#   never sends the fragment to the server, so the page request is just
#   GET /reset-password.
# - The reset page reads it from the fragment and sends it in the body of
#   a POST, where filter_parameters (:token) hides it.
RSpec.describe 'Password reset tokens and the logs' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) do
    create(:resident, community: community, unit: unit, name: 'Sarah Chen', email: 'sarah@example.com')
  end
  let(:log) { StringIO.new }
  # Production logs at :info (config/environments/production.rb). At
  # :debug Action Mailer also logs every email it sends, link and all,
  # which is fine on a laptop.
  let(:sink) { ActiveSupport::Logger.new(log).tap { |logger| logger.level = :info } }

  around do |example|
    Rails.logger.broadcast_to(sink)
    example.run
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  def mailed_link
    ActionMailer::Base.deliveries.last.text_part.body.decoded[%r{https?://\S+/reset-password\S*}].delete_suffix('.')
  end

  # The token in the mailed link, wherever in the link it is.
  def mailed_token
    mailed_link[/[\w-]{43}\z/]
  end

  # What a browser asks the server for when it opens a link: everything
  # but the fragment.
  def request_line_of(link)
    uri = URI.parse(link)
    [uri.path, uri.query].compact.join('?')
  end

  it 'mails a link that carries the token in the fragment only' do
    post '/api/v1/residents/password-reset', params: { email: 'sarah@example.com' }
    uri = URI.parse(mailed_link)

    expect(uri.path).to eq('/reset-password')
    expect(uri.query).to be_nil
    expect(uri.fragment).to match(/\Atoken=[\w-]{43}\z/)
  end

  it 'writes the token to no log line when the emailed link is opened' do
    post '/api/v1/residents/password-reset', params: { email: 'sarah@example.com' }
    token = mailed_token

    get request_line_of(mailed_link)

    expect(response).to have_http_status(:ok)
    expect(log.string).to include('Started GET "/reset-password')
    expect(log.string.lines.grep(/#{Regexp.escape(token)}/)).to eq([])
  end

  it 'writes the token to no log line, from the email to the new password' do
    post '/api/v1/residents/password-reset', params: { email: 'sarah@example.com' }
    token = mailed_token

    get request_line_of(mailed_link)
    expect(response).to have_http_status(:ok)

    post '/api/v1/residents/password-reset/name', params: { token: token }, as: :json
    expect(response.parsed_body).to eq('name' => 'Sarah')

    post '/api/v1/residents/password-reset/new', params: { token: token, password: 'new one' }, as: :json
    expect(response.parsed_body).to eq('message' => 'Password updated!')
    expect(resident.reload.authenticate('new one')).to eq(resident)

    expect(token).to match(/\A[\w-]{43}\z/)
    expect(log.string).to include('Started POST "/api/v1/residents/password-reset/new"')
    expect(log.string.lines.grep(/#{Regexp.escape(token)}/)).to eq([])
  end
end
