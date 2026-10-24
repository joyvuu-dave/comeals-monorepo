# frozen_string_literal: true

require 'rails_helper'

# An admin reset token that is still live is as good as the password, so
# it must never be written to a log. Two logs see every request line:
# Rails's own ("Started GET ...") and Heroku's router, which records the
# path and the query of every request and which this app cannot filter.
# Rails hides a parameter's value in its own log, but the router writes
# the query as it came. So the token never travels in a path or a query:
#
# - The emailed link carries it after the #, in the fragment. A browser
#   never sends the fragment to the server, so opening the link asks only
#   for GET /password/edit.
# - The page reads the token from the fragment with a script, puts it in
#   the form's hidden field, and the form sends it in the body of
#   PUT /password, where Rails hides it as [FILTERED].
RSpec.describe 'Admin password reset link' do
  let(:community) { create(:community) }
  let!(:admin) do
    create(:admin_user, community: community, email: 'admin@example.com',
                        password: 'the-old-password', password_confirmation: 'the-old-password')
  end
  let(:log) { StringIO.new }
  # Production logs at :info (config/environments/production.rb).
  let(:sink) { ActiveSupport::Logger.new(log).tap { |logger| logger.level = :info } }
  # What the router would log for each request: the path and the query.
  let(:request_lines) { [] }

  before { host! 'admin.example.com' }

  # Devise's mail links to the admin host. Production names it
  # (config/environments/production.rb); the test environment does not.
  around do |example|
    default_url_options = ActionMailer::Base.default_url_options
    ActionMailer::Base.default_url_options = { host: 'admin.example.com' }
    Rails.logger.broadcast_to(sink)
    example.run
  ensure
    Rails.logger.stop_broadcasting_to(sink)
    ActionMailer::Base.default_url_options = default_url_options
  end

  def ask_for_a_link
    post '/password', params: { admin_user: { email: 'admin@example.com' } }
    request_lines << request.fullpath
    expect(response).to redirect_to('/login')
  end

  def mailed_link
    ActionMailer::Base.deliveries.last.body.decoded[%r{href="(http://admin\.example\.com/password/edit[^"]*)"}, 1]
  end

  def mailed_token
    URI.parse(mailed_link).fragment.delete_prefix('reset_password_token=')
  end

  # What a browser asks the server for when it opens a link: everything
  # but the fragment.
  def visit(link)
    uri = URI.parse(link)
    get [uri.path, uri.query].compact.join('?')
    request_lines << request.fullpath
  end

  def set_password(token, password, confirmation = password)
    put '/password', params: { admin_user: { reset_password_token: token, password: password,
                                             password_confirmation: confirmation } }
    request_lines << request.fullpath
  end

  it 'mails a link that carries the token in the fragment only' do
    ask_for_a_link
    uri = URI.parse(mailed_link)

    expect(uri.path).to eq('/password/edit')
    expect(uri.query).to be_nil
    expect(uri.fragment).to match(/\Areset_password_token=[\w-]{20}\z/)
  end

  it 'shows the form when the link is opened, with no token in the request' do
    ask_for_a_link
    visit(mailed_link)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="admin_user_reset_password_token"')
    expect(response.body).to include('Change your password')
  end

  it 'writes the token to no log line and no request line, from the email to the new password' do
    ask_for_a_link
    token = mailed_token
    visit(mailed_link)
    expect(response).to have_http_status(:ok)

    set_password(token, 'the-new-password')

    expect(response).to redirect_to('/')
    expect(admin.reload.valid_password?('the-new-password')).to be(true)
    expect(log.string).to include('Started GET "/password/edit"', 'Started PUT "/password"')
    expect(log.string.lines.grep(/#{Regexp.escape(token)}/)).to eq([])
    expect(request_lines).to eq(['/password', '/password/edit', '/password'])
  end

  # A wrong confirmation shows the form again with the token still in its
  # hidden field (Devise puts it back), so the second try needs no link.
  # The page's answer is the body of PUT /password; no request line has
  # the token.
  it 'keeps the token in the form after a refused try, and the second try works' do
    ask_for_a_link
    token = mailed_token
    visit(mailed_link)

    set_password(token, 'the-new-password', 'something-else')
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(%(value="#{token}"))

    set_password(token, 'the-new-password')
    expect(admin.reload.valid_password?('the-new-password')).to be(true)
    expect(log.string.lines.grep(/#{Regexp.escape(token)}/)).to eq([])
  end

  # A link mailed before the token moved to the fragment has it in the
  # query. That request line is in the router's log already, so the page
  # does not take the token from it: it sends the admin to ask for a new
  # link, and the new link replaces the old token.
  it 'turns away an old link with the token in the query, and says to ask for a new one' do
    ask_for_a_link
    token = mailed_token

    get "/password/edit?reset_password_token=#{token}"

    expect(response).to redirect_to('/password/new')
    expect(flash[:alert]).to eq(AdminPasswordsController::OLD_LINK)
    follow_redirect!
    expect(response.body).to include(AdminPasswordsController::OLD_LINK)
    expect(log.string.lines.grep(/#{Regexp.escape(token)}/)).to eq([])
  end

  # Opening the page with no link at all used to send the admin to the
  # login page. The server cannot tell that case apart now, because the
  # token is never sent to it, so the page's script says it.
  it 'shows the page with an empty token field when nothing is sent' do
    get '/password/edit'

    expect(response).to have_http_status(:ok)
    field = response.body[/<input[^>]*id="admin_user_reset_password_token"[^>]*>/]
    expect(field).to include('type="hidden"')
    expect(field).not_to match(/value="[^"]/)
  end
end
