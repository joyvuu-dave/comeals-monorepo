# typed: true
# frozen_string_literal: true

# browser/browser, not browser: the gem's main file also adds a helper to
# every controller when Rails is loaded (the Gemfile says more).
require 'browser/browser'

# The browser a report came from, read from its User-Agent string: the
# browser's name and major version, the operating system, and the kind
# of device. Only these few words are kept, never the string itself.
#
# Two things the string cannot say:
#
# - Since iPadOS 13, Safari on an iPad sends the same string as Safari on
#   a Mac ("Macintosh; Intel Mac OS X 10_15_7"). The browser check sends
#   `touch` (more than one touch point on the screen), and a Mac string
#   with a touch screen is read as an iPad.
# - Newer Safari and Chrome freeze the operating system's version in the
#   string (macOS stays "10_15_7", and iOS 26 says "18_6"). So no OS
#   version is read. The browser's own version is the number the support
#   line uses (app/frontend/browser_target.mjs): on an iPad or iPhone,
#   Safari's version is the iOS version. Another browser on an iPad or
#   iPhone (Chrome, Firefox) uses Safari's engine and sends its own
#   version, so for those the check's result, not the version, says
#   whether the browser works.
class BrowserDescription
  extend T::Sig

  UNKNOWN = 'Unknown'

  # The operating system names, by the gem's platform id. Anything else is
  # UNKNOWN.
  PLATFORMS = T.let({
    ios: 'iOS', mac: 'macOS', android: 'Android', windows: 'Windows',
    chrome_os: 'ChromeOS', linux: 'Linux'
  }.freeze, T::Hash[Symbol, String])

  # Platforms that only run on a computer.
  DESKTOP_PLATFORMS = %i[mac windows chrome_os linux].freeze

  sig { returns(String) }
  attr_reader :browser

  sig { returns(T.nilable(Integer)) }
  attr_reader :major

  sig { returns(String) }
  attr_reader :os

  sig { returns(String) }
  attr_reader :device

  sig { params(user_agent: String, touch: T::Boolean).void }
  def initialize(user_agent, touch:)
    parsed = Browser.new(user_agent)
    @bot = T.let(parsed.bot?, T::Boolean)
    @browser = T.let(parsed.known? ? parsed.name : UNKNOWN, String)
    major = parsed.version.to_i
    @major = T.let(major.positive? ? major : nil, T.nilable(Integer))
    ipad = parsed.platform.mac? && touch
    @os = T.let(ipad ? 'iPadOS' : os_name(parsed), String)
    @device = T.let(ipad ? 'tablet' : device_kind(parsed), String)
  end

  # A crawler, a script, or a request with no User-Agent at all.
  sig { returns(T::Boolean) }
  def bot?
    @bot
  end

  private

  sig { params(parsed: Browser::Base).returns(String) }
  def os_name(parsed)
    return 'iPadOS' if parsed.device.ipad?

    PLATFORMS.fetch(parsed.platform.id, UNKNOWN)
  end

  sig { params(parsed: Browser::Base).returns(String) }
  def device_kind(parsed)
    return 'tablet' if parsed.device.tablet?
    return 'phone' if parsed.device.mobile?
    return 'desktop' if DESKTOP_PLATFORMS.include?(parsed.platform.id)

    'unknown'
  end
end
