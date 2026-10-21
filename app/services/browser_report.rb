# typed: true
# frozen_string_literal: true

# One report from the browser check (app/frontend/browser_check.js), read
# from the query string of POST /api/v1/browser-reports and the request's
# User-Agent header.
#
# The check sends exactly one of three shapes, and anything else is
# refused with Invalid:
#
#   result=passed&touch=0|1
#   result=failed&tests=<known test>,...&touch=0|1
#   result=error&error=<at most 200 characters>&touch=0|1
class BrowserReport
  extend T::Sig

  class Invalid < StandardError; end

  RESULTS = %w[passed failed error].freeze

  # The tests the check runs, by the names it sends.
  TESTS = %w[modules lookbehind color_mix cookies].freeze

  # The check cuts its error message to this many characters.
  MAX_ERROR = 200

  # The start of a User-Agent string is enough to read the browser, and a
  # long one is junk anyway. Real browsers send 100 to 300 characters.
  MAX_USER_AGENT = 512

  sig { returns(String) }
  attr_reader :result

  sig { returns(T::Array[String]) }
  attr_reader :tests

  sig { returns(T.nilable(String)) }
  attr_reader :error

  sig { returns(String) }
  attr_reader :user_agent

  sig { returns(BrowserDescription) }
  attr_reader :browser

  sig { params(params: ActionController::Parameters, user_agent: T.nilable(String)).void }
  def initialize(params, user_agent)
    @result = T.let(one_of(params, :result, RESULTS), String)
    @tests = T.let(read_tests(params), T::Array[String])
    @error = T.let(read_error(params), T.nilable(String))
    touch = one_of(params, :touch, %w[0 1]) == '1'
    @user_agent = T.let(user_agent.to_s[0, MAX_USER_AGENT].to_s, String)
    @browser = T.let(BrowserDescription.new(@user_agent, touch: touch), BrowserDescription)
  end

  private

  sig { params(params: ActionController::Parameters, key: Symbol).returns(T.nilable(String)) }
  def text(params, key)
    value = params[key]
    return nil if value.nil?
    raise Invalid, "#{key} must be one value" unless value.is_a?(String)

    value
  end

  sig { params(params: ActionController::Parameters, key: Symbol, allowed: T::Array[String]).returns(String) }
  def one_of(params, key, allowed)
    value = text(params, key)
    raise Invalid, "#{key} must be one of #{allowed.join(', ')}" unless allowed.include?(value)

    T.must(value)
  end

  sig { params(params: ActionController::Parameters).returns(T::Array[String]) }
  def read_tests(params)
    value = text(params, :tests)
    unless result == 'failed'
      raise Invalid, "tests are sent only with result=failed, not #{result}" unless value.nil?

      return []
    end

    tests = value.to_s.split(',')
    raise Invalid, 'a failed report names at least one test' if tests.empty?
    raise Invalid, "unknown test in #{value}" unless (tests - TESTS).empty?
    raise Invalid, "a test is named twice in #{value}" unless tests.uniq == tests

    tests
  end

  sig { params(params: ActionController::Parameters).returns(T.nilable(String)) }
  def read_error(params)
    value = text(params, :error)
    unless result == 'error'
      raise Invalid, "an error is sent only with result=error, not #{result}" unless value.nil?

      return nil
    end

    raise Invalid, 'an error report says what the error was' if value.blank?
    raise Invalid, "an error is at most #{MAX_ERROR} characters" if value.length > MAX_ERROR

    value
  end
end
