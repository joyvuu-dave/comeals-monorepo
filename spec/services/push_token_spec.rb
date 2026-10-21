# frozen_string_literal: true

require 'rails_helper'

# The push_token of a request from the meal page's sign-up list (#237).
# spec/requests/api/v1/late_write_push_spec.rb checks the pushes; this
# file checks which values are taken.
RSpec.describe PushToken do
  it 'takes 1 to 64 letters, digits and hyphens, such as a UUID' do
    ['a', 'tap-1', SecureRandom.uuid, 'A' * 64].each do |raw|
      expect(described_class.read(raw)).to eq(raw), raw.inspect
    end
  end

  it 'reads everything else as no token' do
    [nil, '', 'a' * 65, 'a b', 'tap_1', "tap\n", 'café', 1, ['tap'], { 'a' => 'b' }].each do |raw|
      expect(described_class.read(raw)).to be_nil, raw.inspect
    end
  end
end
