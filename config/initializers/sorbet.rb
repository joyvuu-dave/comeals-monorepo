# typed: false
# frozen_string_literal: true

# sorbet-runtime checks every `sig` when the method is called. By default a
# value that does not match raises TypeError, in production too, so a
# signature that is slightly wrong (a method that returns nil once in a
# while) would turn a working request into a 500.
#
# So outside the test suite a failed check is reported, not raised: it goes
# through Rails.error to Bugsnag (lib/bugsnag_error_subscriber.rb) and the
# call goes on as if there were no sig. In the test suite it raises, so a
# wrong sig fails a spec.
#
# This is a handler, not `T::Configuration.default_checked_level = :tests`,
# because that setting must be set before any sig is evaluated, and
# `bin/tapioca dsl` (which is itself written with Sorbet) has evaluated sigs
# long before it loads this file.
#
# T.must, T.let and T.cast are not sigs. They always raise, where the old
# code would have raised NoMethodError a line later.
#
# See docs/sorbet.md.
unless Rails.env.test?
  T::Configuration.call_validation_error_handler = lambda do |signature, opts|
    error = TypeError.new(opts[:pretty_message])
    error.set_backtrace(caller)
    Rails.error.report(error, handled: true, source: 'sorbet',
                              context: { method: signature&.method_name&.to_s })
  end
end
