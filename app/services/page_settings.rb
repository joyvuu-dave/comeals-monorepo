# typed: strict
# frozen_string_literal: true

# The keys the app's page needs from the app that sends it: the Pusher key
# and cluster, and the Bugsnag key. FallbackController writes them into
# the page as <meta> tags each time it sends it, and the page reads them
# there (app/frontend/src/helpers/page_settings.ts).
#
# They are not built into the JavaScript, because the Deploy workflow
# builds on staging and ships that same build to production (#257). A
# key built in would be staging's: an empty Pusher key, so production's
# screens would never update by themselves, and no Bugsnag key. So the
# tags a build carries are always replaced here.
#
# They are the server's own values, so the page listens on the Pusher app
# the server sends on, and reports to the same Bugsnag project as Rails.
module PageSettings
  extend T::Sig

  class NoHead < StandardError; end

  # One of these tags as a build writes it, in either form: Vite writes
  # `<meta name=".." content="..">`, a page by hand may end in " />".
  TAG = T.let(%r{[ \t]*<meta name="comeals-[a-z-]+" content="[^"]*"\s*/?>\n?}, Regexp)

  # The server sends nothing on Pusher on staging and on the integration
  # test server (PusherSetup.silenced?), and its Pusher values there are
  # placeholders. A page that connected with them would only fail, so it
  # gets no key. Browser reports go to Bugsnag only from production, as
  # Rails's own do (config/initializers/bugsnag.rb).
  sig { params(vars: T::Hash[String, String], env: ActiveSupport::EnvironmentInquirer).returns(T::Hash[String, String]) }
  def self.values(vars:, env:)
    pusher = !PusherSetup.silenced?(vars)
    {
      'comeals-pusher-key' => pusher ? vars.fetch('PUSHER_KEY', '') : '',
      'comeals-pusher-cluster' => pusher ? vars.fetch('PUSHER_CLUSTER', '') : '',
      'comeals-bugsnag-api-key' => env.production? ? vars.fetch('BUGSNAG_API_KEY', '') : ''
    }
  end

  # The page with every tag a build wrote taken out, and one tag for each
  # value put in at the end of the head.
  sig { params(html: String, values: T::Hash[String, String]).returns(String) }
  def self.fill(html, values)
    raise NoHead, 'The page has no </head>, so it has nowhere to put its keys.' unless html.include?('</head>')

    tags = values.map do |name, value|
      %(    <meta name="#{ERB::Util.html_escape(name)}" content="#{ERB::Util.html_escape(value)}" />\n)
    end
    html.gsub(TAG, '').sub('</head>', "#{tags.join}  </head>")
  end
end
