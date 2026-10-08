# frozen_string_literal: true

require 'rails_helper'

# The Idempotency-Key header's value (IETF draft "The Idempotency-Key
# HTTP Header Field", section 2.1): a Structured Field Item whose value is
# a String (RFC 9651, sections 3.3.3 and 4.2.5). This app adds one rule of
# its own: the key is 1 to 255 characters.
RSpec.describe IdempotencyKeyHeader do
  let(:missing) do
    'A bills save needs an Idempotency-Key header, with a new key for each save. Nothing was saved.'
  end
  let(:invalid) do
    'The Idempotency-Key header must be a quoted string of 1 to 255 characters, ' \
      'like "8e03978e-40d5-43e8-bc93-6894a57f9324". Nothing was saved.'
  end

  def key_of(value)
    described_class.new(value).key
  end

  def error_of(value)
    described_class.new(value).error
  end

  it 'reads the key from a quoted string' do
    header = described_class.new('"8e03978e-40d5-43e8-bc93-6894a57f9324"')

    expect(header.key).to eq('8e03978e-40d5-43e8-bc93-6894a57f9324')
    expect(header.error).to be_nil
  end

  it 'answers a missing header with its own sentence' do
    header = described_class.new(nil)

    expect(header.key).to be_nil
    expect(header.error).to eq(missing)
  end

  # RFC 9651, section 4.2: spaces before and after the item are discarded.
  it 'takes spaces before and after the string' do
    expect(key_of('  "abc"  ')).to eq('abc')
  end

  # Section 4.2.5: a backslash escapes a quote or a backslash, and only
  # those two.
  it 'reads the two escapes a string has' do
    expect(key_of('"a\"b\\\\c"')).to eq('a"b\\c')
  end

  it 'keeps spaces and every printable character inside the string' do
    printable = (0x20..0x7E).map(&:chr).join.delete('"\\')

    expect(key_of(%("#{printable}"))).to eq(printable)
  end

  # Section 2.1 of RFC 9651 asks a field not to treat a parameter it does
  # not know as an error, and the draft defines none, so all are read and
  # dropped. Each kind of value a parameter can have is here.
  it 'reads and drops parameters after the string' do
    value = '"abc";a;b=1;c=-1.5;d="x;y";e=tok/en:1;f=:aGk=:;g=?0;h=@1700000000;i=%"%c3%a9";  j=*;' \
            "k=a!\#$%&'*+-.^_`|~:/b"

    expect(key_of(value)).to eq('abc')
  end

  it 'takes a key of 1 and of 255 characters' do
    expect(key_of('"a"')).to eq('a')
    expect(key_of(%("#{'a' * 255}"))).to eq('a' * 255)
  end

  it 'counts an escaped character as one character of the key' do
    expect(key_of(%("#{'\\"' * 255}"))).to eq('"' * 255)
  end

  {
    'an empty header' => '',
    'a value with no quotes' => '8e03978e-40d5-43e8-bc93-6894a57f9324',
    'an empty string' => '""',
    'a key of 256 characters' => %("#{'a' * 256}"),
    'a string with no closing quote' => '"abc',
    'a backslash before another character' => '"a\\bc"',
    'a backslash at the end' => '"abc\\"',
    'a tab inside the string' => %("a\tb"),
    'a character that is not ASCII' => '"café"',
    'a byte that is not valid UTF-8' => "\"a\xFFb\"".b,
    # The same bytes in a string marked UTF-8: matching a regular
    # expression against it raises, so the header is read as bytes.
    'a byte that is not valid UTF-8, in a string marked UTF-8' => "\"a\xFFb\"",
    'two values, as two header lines arrive joined' => '"abc", "def"',
    'text after the string' => '"abc" def',
    'a space before a parameter' => '"abc" ;a=1',
    'a parameter key with a capital letter' => '"abc";A=1',
    'a parameter with no key' => '"abc";=1',
    'a parameter value that is not a bare item' => '"abc";a=,',
    'a parameter string with no closing quote' => '"abc";a="x',
    'a number with too many digits' => '"abc";a=1234567890123456',
    'a single-quoted value' => "'abc'",
    'a byte sequence as the value' => ':aGk=:',
    'a token as the value' => 'abc'
  }.each do |what, value|
    it "refuses #{what}" do
      header = described_class.new(value)

      expect(header.error).to eq(invalid)
      expect(header.key).to be_nil
    end
  end
end
