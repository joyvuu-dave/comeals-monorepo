# frozen_string_literal: true

# Behavior of a phone column backed by HasPhoneNumber: any way of typing a
# number is accepted, the E.164 form is what gets stored, and input that is
# not a real number is refused. The including spec defines `record`, a
# valid unsaved instance of the model.
RSpec.shared_examples 'a model with a phone number' do
  it 'saves a US number typed with punctuation in E.164 form' do
    record.phone = '(510) 555-2671'
    record.save!
    expect(record.reload.phone).to eq('+15105552671')
  end

  it 'saves a dotted US number the same way' do
    record.phone = '510.555.2671'
    record.save!
    expect(record.reload.phone).to eq('+15105552671')
  end

  it 'reads a number that starts with + as the country its code names' do
    record.phone = '+44 20 7946 0958'
    record.save!
    expect(record.reload.phone).to eq('+442079460958')
  end

  it 'stores nil when the field is left blank' do
    record.phone = ''
    record.save!
    expect(record.reload.phone).to be_nil
  end

  it 'is valid with no phone number' do
    record.phone = nil
    expect(record).to be_valid
  end

  it 'refuses a number with no area code and says how to fix it' do
    record.phone = '555-2671'
    expect(record).not_to be_valid
    expect(record.errors[:phone].join).to include('area code')
  end

  it 'refuses text that is not a number, keeping the input so it can be corrected' do
    record.phone = 'garbage'
    expect(record).not_to be_valid
    expect(record.phone).to eq('garbage')
  end

  it 'has a CHECK constraint that keeps non-E.164 values out of writes that skip the model' do
    record.phone = nil
    record.save!
    expect { record.update_column(:phone, '510-555-2671') }
      .to raise_error(ActiveRecord::StatementInvalid, /phone_e164/)
  end
end
