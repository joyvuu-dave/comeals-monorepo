# frozen_string_literal: true
# typed: false

# A fix for mutant 0.17.1, loaded by hook 6 in config/mutant/hooks.rb.
#
# When mutant starts, it calls `name` on every loaded module and reads the
# answer as an expression. Faker's classes have a class method `name` that
# returns a random fake value: `Faker::Name.name` is "Msgr. Latasha
# Schaden", `Faker::University.name` is "Western Fay Academy". A value
# with a dot after its first word looks like `Scope.method` to mutant, so
# it checks the rest as a method name by parsing `def <rest>; end`. A
# value with an apostrophe, such as "Mr. Patrick O'Keefe", does not parse,
# and `valid_method_name?` raises Parser::SyntaxError instead of answering
# false. Mutant stops before it mutates anything. On GitHub that ended a
# piece of the full run (runs 42892140239 and 42913028051), since each
# piece is a new process with new random names.
#
# The fix: text that does not parse is not a method name. Reported to
# mutant on 2026-11-10: https://github.com/mbj/mutant/issues/1690
# spec/config/mutant_method_name_check_spec.rb checks it, and fails when
# mutant is not 0.17.1, so an upgrade is checked again: remove this file
# if the new version answers false itself.
module MutantMethodNameCheck
  VERSION = '0.17.1'

  # const_get because Sorbet has no types for the mutant gem.
  def self.apply
    mutant = Object.const_get(:Mutant)
    unless mutant::VERSION == VERSION
      raise "mutant is #{mutant::VERSION}, not #{VERSION}: read config/mutant/method_name_check.rb"
    end

    mutant::Expression::Method.singleton_class.prepend(self)
  end

  private

  def valid_method_name?(name)
    super
  rescue Parser::SyntaxError
    false
  end
end
