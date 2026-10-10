# typed: strict
# frozen_string_literal: true

# The Idempotency-Key request header of a bills save or a guest add, read
# by the rules of the IETF draft "The Idempotency-Key HTTP Header Field"
# (draft-ietf-httpapi-idempotency-key-header-07, section 2.1). Its value
# is a Structured Field Item whose value is a String (RFC 9651): printable
# ASCII between double quotes, where a backslash comes only before a quote
# or a backslash, to stand for that character.
#
#   Idempotency-Key: "8e03978e-40d5-43e8-bc93-6894a57f9324"
#
# Spaces before and after the item are allowed (RFC 9651, section 4.2).
# An item can also have parameters after the string ("abc";v=1). The draft
# defines none, and RFC 9651 (section 2.1) asks a field not to treat a
# parameter it does not know as an error, so each one is checked against
# the grammar and then dropped. What a byte sequence or a display string
# in a parameter decodes to is not checked, because nothing reads them.
#
# This app adds one rule: a key is 1 to 255 characters, counted after the
# backslashes are read. The bills_save_keys_key_printable and
# guest_add_keys_key_printable CHECKs say the same.
class IdempotencyKeyHeader
  extend T::Sig

  MISSING = T.let('A bills save needs an Idempotency-Key header, with a new key for each save. ' \
                  'Nothing was saved.', String)
  INVALID = T.let('The Idempotency-Key header must be a quoted string of 1 to 255 characters, ' \
                  'like "8e03978e-40d5-43e8-bc93-6894a57f9324". Nothing was saved.', String)

  MAX_LENGTH = T.let(255, Integer)

  # RFC 9651, section 3.3.3: printable ASCII but the quote and the
  # backslash, or a backslash and one of those two.
  STRING = T.let(/"(?:[\x20\x21\x23-\x5B\x5D-\x7E]|\\["\\])*"/, Regexp)

  # The other bare items a parameter's value can be, section 3.3: a
  # decimal, an integer, a token, a byte sequence, a boolean, a date and a
  # display string. The decimal comes before the integer, so "1.5" is not
  # read as 1. \x2F is the slash.
  BARE_ITEM = T.let(
    /-?\d{1,12}\.\d{1,3}|-?\d{1,15}|#{STRING}|[A-Za-z*][!#$%&'*+\-.^_`|~0-9A-Za-z:\x2F]*|
     :[A-Za-z0-9+\x2F=]*:|\?[01]|@-?\d{1,15}|%"(?:[\x20\x21\x23\x24\x26-\x7E]|%[0-9a-f]{2})*"/x,
    Regexp
  )

  # Section 4.2.3.2: a semicolon, spaces, a key, and maybe "=" and a value.
  PARAMETER = T.let(/;\x20*[a-z*][a-z0-9_\-.*]*(?:=(?:#{BARE_ITEM}))?/, Regexp)

  FIELD = T.let(/\A\x20*(?<string>#{STRING})(?:#{PARAMETER})*\x20*\z/, Regexp)

  # The key, without its quotes and backslashes, or nil when the header is
  # missing or not a key.
  sig { returns(T.nilable(String)) }
  attr_reader :key

  # The sentence for a missing or wrong header, or nil when there is a key.
  sig { returns(T.nilable(String)) }
  attr_reader :error

  # `missing` is the sentence for a request with no header. It names the
  # request, so a guest add passes its own; the default is a bills save's.
  sig { params(value: T.nilable(String), missing: String).void }
  def initialize(value, missing: MISSING)
    @key = T.let(value && read(value), T.nilable(String))
    @error = T.let(if value.nil? then missing
                   elsif @key.nil? then INVALID
                   end, T.nilable(String))
  end

  private

  # Bytes, not characters: a header is ASCII, and a byte that is not ASCII,
  # or not valid UTF-8, must fail the match rather than raise.
  sig { params(value: String).returns(T.nilable(String)) }
  def read(value)
    string = FIELD.match(value.b)&.[](:string)
    return nil if string.nil?

    key = T.must(string[1...-1]).gsub(/\\(["\\])/, '\1').force_encoding(Encoding::UTF_8)
    key if key.length.between?(1, MAX_LENGTH)
  end
end
