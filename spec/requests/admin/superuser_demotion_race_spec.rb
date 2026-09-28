# frozen_string_literal: true

require 'rails_helper'

# Two superusers each removing the other's access at the same moment.
# Either demotion alone is allowed, because another superuser is left.
# Both together would leave none. Through admin, this race is the only
# way to reach the last-superuser rule: the controller refuses any
# self-demotion, so a lone superuser can never be demoted one request at
# a time (superuser_management_spec.rb).
#
# Neither the controller nor the model guard can see the race. Each
# checks "is another superuser left?" before the other side has
# committed, and each sees yes. The trigger from 20260728120000 is what
# refuses it: it takes FOR UPDATE on the other superusers' rows, so the
# later write waits for the earlier one, and at SERIALIZABLE it is then
# refused as a conflict (ADR 0004).
#
# One side is the admin form. The other is a database session of its
# own, writing the row the way psql or a task that skips the model would,
# so only the database stands between the two writes. Without a test
# transaction, because the two sessions must see each other's locks.
RSpec.describe 'two superusers removing each other at the same moment' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let!(:me) { create(:admin_user, community: community, superuser: true) }
  let!(:other) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in me
    # The first signed-in request writes Devise's sign-in columns to my
    # row. Done here, so the request under test only reads the row and
    # waits on the superuser rule, not on that write.
    get '/'
  end

  def db_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # Demotes me and holds the transaction open until another session is
  # waiting on a lock, then commits. Reports each step through the queue.
  def other_side_demotes_me(outcome)
    Thread.new do
      session = db_session
      session.exec('BEGIN')
      session.exec_params('UPDATE admin_users SET superuser = false WHERE id = $1', [me.id])
      outcome << :written
      outcome << :nobody_waited unless someone_waits?(session)
      session.exec('COMMIT')
      outcome << :committed
    rescue PG::Error => e
      outcome << "#{e.class}: #{e.message}"
    ensure
      session&.close
    end
  end

  # True once some other session is waiting on a lock. Polled rather than
  # slept on: a fixed sleep would be either slow or flaky.
  def someone_waits?(session)
    250.times do
      waiting = session.exec('SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
                             "AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()").getvalue(0, 0).to_i
      return true if waiting.positive?

      sleep 0.02
    end
    false
  end

  it 'refuses the second demotion as a conflict, so one superuser is left' do
    outcome = Queue.new
    other_side = other_side_demotes_me(outcome)
    expect(outcome.pop).to eq(:written)

    patch "/admin_users/#{other.id}", params: { admin_user: { superuser: false } }

    expect(other_side.join(15)).not_to be_nil, 'the other side did not finish'
    expect(Array.new(outcome.size) { outcome.pop }).to eq([:committed])
    expect(flash[:alert]).to eq('Someone else was changing this at the same time. Nothing was saved. Try again.')
    expect(AdminUser.where(superuser: true).pluck(:id)).to eq([other.id])
  end
end
