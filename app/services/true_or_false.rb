# typed: strict
# frozen_string_literal: true

# The one rule for a true/false value in an API request (#138): late and
# vegetarian on a sign-up, a change and a guest, closed on a meal,
# all_day on an event, and no_cost in a bills save.
#
# Taken: true, false, 1 and 0, and the same as text: "true", "false",
# "1" and "0", exactly these, in lower case. A JSON body sends true and
# false; a form-encoded body sends every value as text. Everything else
# is refused with a 400, in the words the models use for a nil (#121):
# "Late must be true or false".
#
# Rails' own reading is not used. It reads a value as false only when it
# is one of its false words ("0", "f", "false", "off", and the same in
# upper case), "" as nil, and every other value as true. So "no", "maybe"
# and "False" (what Python's requests sends for False) were saved as
# true, and nobody saw an error: a script that sent closed=False closed
# the meal.
module TrueOrFalse
  extend T::Sig

  VALUES = T.let({ true => true, false => false, 1 => true, 0 => false,
                   'true' => true, 'false' => false, '1' => true, '0' => false }.freeze,
                 T::Hash[T.untyped, T::Boolean])
  private_constant :VALUES

  # The words after the name, in a refusal and in a model's error for a
  # nil in a true/false column (#121, #139).
  MESSAGE = T.let('must be true or false', String)

  # The value as true or false, or nil when it is not one of the values
  # above. A lookup, so a value is taken only when it is exactly one of
  # them: 1.0 is not 1, and "True" is not "true".
  sig { params(raw: T.untyped).returns(T.nilable(T::Boolean)) }
  def self.read(raw)
    VALUES[raw]
  end

  # The sentence for a refused value: "Late must be true or false". Rails
  # writes a column's name the same way in a model's error.
  sig { params(name: Symbol).returns(String) }
  def self.refusal(name)
    "#{name.to_s.humanize} #{MESSAGE}"
  end

  # The values with these names in a request, by name, or the message of
  # the 400 when any of them is refused: one sentence for each, one per
  # line, in the order of `names`.
  #
  # With required: true, a value that is left out is refused, the same as
  # null or "". With required: false (a change), a value that is left out
  # is left out of the answer too, so the caller keeps the stored value;
  # a value that is sent is read the same way.
  sig do
    params(params: ActionController::Parameters, names: T::Array[Symbol], required: T::Boolean)
      .returns(T.any(T::Hash[Symbol, T::Boolean], String))
  end
  def self.from_params(params, names, required:)
    values = T.let({}, T::Hash[Symbol, T::Boolean])
    refused = T.let([], T::Array[String])
    names.each do |name|
      next unless required || params.key?(name)

      value = read(params[name])
      if value.nil?
        refused << refusal(name)
      else
        values[name] = value
      end
    end
    refused.empty? ? values : refused.join("\n")
  end
end
