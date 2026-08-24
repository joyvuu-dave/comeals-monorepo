# frozen_string_literal: true

# Turn on pg_trgm so a query can match a name with a typo in it.
#
# ILIKE finds a name when the first letters are right ("bon" finds Bonnie).
# It cannot find "steev" or "Suzzane", because the mistake is inside the
# word. pg_trgm compares three-letter chunks, so
#   word_similarity('steev', name) > 0.4
# finds "Steve Safru". Heroku Postgres supports the extension on every plan.
#
# No index: residents has fewer than a hundred rows, so a sequential scan
# is already the fastest plan.
class EnablePgTrgmForFuzzyNameSearch < ActiveRecord::Migration[8.1]
  def change
    enable_extension 'pg_trgm'
  end
end
