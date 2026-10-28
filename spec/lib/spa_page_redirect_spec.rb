# frozen_string_literal: true

require 'rails_helper'

# The middleware on its own. Rails builds the app's copy once, at boot,
# so the request specs (spec/requests/fallback_controller_spec.rb) never
# build one.
RSpec.describe SpaPageRedirect do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/html' }, ['the app']] } }
  let(:middleware) { described_class.new(app) }

  def env_for(path, query = '')
    { 'PATH_INFO' => path, 'QUERY_STRING' => query }
  end

  it 'answers /index.html with a 301 to /, and no body' do
    expect(middleware.call(env_for('/index.html'))).to eq([301, { 'location' => '/' }, []])
  end

  it 'keeps the query string' do
    expect(middleware.call(env_for('/index.html', 'a=1')).dig(1, 'location')).to eq('/?a=1')
  end

  it 'passes every other path to the app' do
    expect(middleware.call(env_for('/'))).to eq([200, { 'content-type' => 'text/html' }, ['the app']])
    expect(middleware.call(env_for('/calendar/index.html'))).to eq([200, { 'content-type' => 'text/html' },
                                                                    ['the app']])
  end
end
