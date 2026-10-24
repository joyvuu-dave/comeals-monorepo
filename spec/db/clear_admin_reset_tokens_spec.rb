# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261023140000_clear_admin_reset_tokens.rb')

# The data migration that ends every admin reset token at the deploy that
# moves the token out of the link's query. A token mailed before then was
# in the query, so Heroku's router may have logged it when the link was
# opened. Clearing it makes such a token useless at once, instead of up to
# a day later.
RSpec.describe ClearAdminResetTokens do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  # Devise's own step that stores a new token's digest and returns the
  # token, without the email (the test environment has no mail host).
  def give_reset_token(admin)
    admin.send(:set_reset_password_token)
  end

  def reset_columns(admin)
    ActiveRecord::Base.connection.select_rows(<<~SQL.squish).first
      SELECT reset_password_token, reset_password_sent_at FROM admin_users WHERE id = #{Integer(admin.id)}
    SQL
  end

  it 'empties the token and its time on every admin that has one, and says how many' do
    ann = create(:admin_user, community: community)
    bob = create(:admin_user, community: community)
    give_reset_token(ann)
    give_reset_token(bob)

    output = migrate(:up)

    expect([reset_columns(ann), reset_columns(bob)]).to eq([[nil, nil], [nil, nil]])
    expect(output).to include('Cleared the reset token of 2 admin(s)')
  end

  it 'makes a token mailed before it unusable' do
    admin = create(:admin_user, community: community, password: 'the-old-password',
                                password_confirmation: 'the-old-password')
    token = give_reset_token(admin)

    migrate(:up)

    reset = AdminUser.reset_password_by_token(reset_password_token: token, password: 'the-new-password',
                                              password_confirmation: 'the-new-password')
    expect(reset.errors[:reset_password_token]).to eq(['is invalid'])
    expect(admin.reload.valid_password?('the-old-password')).to be(true)
  end

  it 'changes nothing else on the row' do
    admin = create(:admin_user, community: community)
    give_reset_token(admin)
    before = admin.reload.attributes.except('reset_password_token', 'reset_password_sent_at')

    migrate(:up)

    expect(admin.reload.attributes.except('reset_password_token', 'reset_password_sent_at')).to eq(before)
  end

  it 'does nothing on the way down' do
    expect { migrate(:down) }.not_to raise_error
  end

  it_behaves_like 'a data migration that tries a conflict again', described_class
end
