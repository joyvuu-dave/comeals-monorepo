# frozen_string_literal: true

require 'rails_helper'

# The attendance_version of a sign-up, take-off or change. The request
# specs check the endpoints (spec/requests/api/v1/attendance_out_of_order_spec.rb);
# this file checks the rule itself, value by value.
RSpec.describe AttendanceVersionParam do
  def read(raw)
    described_class.from_params(ActionController::Parameters.new(attendance_version: raw))
  end

  it 'is nil when no version is sent, or null' do
    expect(described_class.from_params(ActionController::Parameters.new)).to be_nil
    expect(read(nil)).to be_nil
  end

  it 'takes a whole number, 0 or more, as a number or as text of digits' do
    [[0, 0], [7, 7], ['0', 0], ['12', 12], [10**17, 10**17], ['9' * 18, Integer('9' * 18)]].each do |raw, version|
      expect(read(raw)).to eq(version), raw.inspect
    end
  end

  it 'refuses every other value' do
    [-1, 4.0, 10**18, '-1', '4.0', '', ' 4', '04', '9' * 19, 'four', true, [], {}].each do |raw|
      expect(read(raw)).to eq('Attendance version must be a whole number, 0 or more.'), raw.inspect
    end
  end
end
