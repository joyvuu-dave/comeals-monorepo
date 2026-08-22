# frozen_string_literal: true

# Alba builds the JSON that the API returns (app/serializers). A serializer
# is a class that includes Alba::Resource. A method on the serializer with
# the same name as an attribute wins over the model's method, and Alba
# calls it with the record as the one argument: `def title(meal)`.
#
# - oj_rails: encode with Oj in Rails mode. This is the same encoder that
#   Oj.optimize_rails (config/initializers/oj.rb) gives a plain `to_json`,
#   so a hash that went through a serializer and a hash rendered directly
#   produce the same bytes: a BigDecimal becomes a string, a Time becomes
#   ISO 8601.
# - symbolize_keys!: `to_h` returns symbol keys, like a Ruby hash literal.
#   The calendar and meal-form hashes are cached and digested into ETags,
#   and the specs read them with symbols.
# - inflector nil (no inference): every association names its serializer with
#   `resource:`. A missing name raises instead of guessing a class.
Alba.backend = :oj_rails
Alba.symbolize_keys!
Alba.inflector = nil
