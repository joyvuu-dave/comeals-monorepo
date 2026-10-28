# frozen_string_literal: true

require 'rails_helper'

# The Deploy workflow builds the app on staging and ships that same build
# to production (#257). So the page must get its keys from the app that
# sends it, never from the build.
RSpec.describe PageSettings do
  let(:production_vars) do
    { 'PUSHER_KEY' => 'production-key', 'PUSHER_CLUSTER' => 'us2', 'BUGSNAG_API_KEY' => 'production-bugsnag' }
  end
  let(:production) { ActiveSupport::EnvironmentInquirer.new('production') }

  describe '.values' do
    it "gives the page production's own keys" do
      expect(described_class.values(vars: production_vars, env: production)).to eq(
        'comeals-pusher-key' => 'production-key',
        'comeals-pusher-cluster' => 'us2',
        'comeals-bugsnag-api-key' => 'production-bugsnag'
      )
    end

    # Staging's Pusher values are placeholders and its server sends
    # nothing (config/initializers/pusher.rb). A page that connected
    # with them would only fail.
    it 'gives no Pusher key where the server does not send on Pusher' do
      %w[COMEALS_STAGING INTEGRATION_SERVER].each do |name|
        values = described_class.values(vars: production_vars.merge(name => '1'), env: production)

        expect(values.values_at('comeals-pusher-key', 'comeals-pusher-cluster')).to eq(['', ''])
      end
    end

    it 'gives no Bugsnag key outside production' do
      values = described_class.values(vars: production_vars, env: ActiveSupport::EnvironmentInquirer.new('development'))

      expect(values['comeals-bugsnag-api-key']).to eq('')
    end

    it 'gives an empty value for a key that is not set' do
      expect(described_class.values(vars: {}, env: production).values).to eq(['', '', ''])
    end
  end

  describe '.fill' do
    let(:values) { described_class.values(vars: production_vars, env: production) }

    # What a build on staging writes: its own empty Pusher key, and the
    # cluster, which is the same.
    let(:staging_build) do
      <<~HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <meta name="comeals-pusher-key" content="" />
            <meta name="comeals-pusher-cluster" content="us2" />
            <title>Comeals</title>
          </head>
          <body><div id="root"></div></body>
        </html>
      HTML
    end

    def setting(html, name)
      Nokogiri::HTML(html).css(%(meta[name="#{name}"])).pluck('content')
    end

    it "replaces the build's keys with the app's, one tag each" do
      page = described_class.fill(staging_build, values)

      expect(setting(page, 'comeals-pusher-key')).to eq(['production-key'])
      expect(setting(page, 'comeals-pusher-cluster')).to eq(['us2'])
      expect(setting(page, 'comeals-bugsnag-api-key')).to eq(['production-bugsnag'])
    end

    it 'puts the tags in the head, and leaves the rest of the page as it was' do
      page = described_class.fill(staging_build, values)
      head = Nokogiri::HTML(page).at('head')

      expect(head.css('meta[name^="comeals-"]').size).to eq(3)
      expect(page.sub(%r{(\s*<meta name="comeals-[^>]*/>)+}, '')).to eq(
        staging_build.gsub(%r{\s*<meta name="comeals-[^>]*/>}, '')
      )
    end

    it 'adds the tags to a build that has none' do
      page = described_class.fill(staging_build.gsub(%r{\s*<meta name="comeals-[^>]*/>}, ''), values)

      expect(setting(page, 'comeals-pusher-key')).to eq(['production-key'])
    end

    it 'writes a value so it cannot end the attribute' do
      page = described_class.fill(staging_build, values.merge('comeals-pusher-key' => '"><script>'))

      expect(setting(page, 'comeals-pusher-key')).to eq(['"><script>'])
      expect(page).not_to include('<script>')
    end

    it 'refuses a page with no head' do
      expect { described_class.fill('<div id="root"></div>', values) }
        .to raise_error(PageSettings::NoHead, 'The page has no </head>, so it has nowhere to put its keys.')
    end
  end
end
