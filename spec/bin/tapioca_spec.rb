# frozen_string_literal: true

require 'rails_helper'

# bin/tapioca is Bundler's binstub with one addition: a `dsl` run in an
# agent worktree uses the worktree's test database (docs/sorbet.md). The
# tapioca command itself and the checkout's .env are fakes here
# (spec/bin/preload).
RSpec.describe 'bin/tapioca' do
  let(:script) { Rails.root.join('bin/tapioca').to_s }
  let(:dotenv) { Tempfile.new('dotenv') }

  after { dotenv.close! }

  def tapioca(*, dotenv_text: nil, env: {})
    dotenv.write(dotenv_text.to_s) && dotenv.flush
    env = { 'DATABASE_URL' => nil, 'FAKE_DOTENV' => dotenv_text ? dotenv.path : '' }.merge(env)
    out, status = run_ruby_script(script, *, env: env, preload: %w[fake_tapioca fake_dotenv])
    expect(status).to be_success, out
    out
  end

  it "points a dsl run at the worktree's test database" do
    out = tapioca('dsl', '--verify', dotenv_text: "PUSHER_KEY=x\nTEST_DB_SUFFIX=_fix_it\n")

    expect(out).to eq("tapioca dsl --verify\nDATABASE_URL=postgresql:///comeals_test_fix_it\n")
  end

  it 'leaves a dsl run alone in the main checkout, whose .env has no TEST_DB_SUFFIX' do
    out = tapioca('dsl', dotenv_text: "PUSHER_KEY=x\n")

    expect(out).to eq("tapioca dsl\nDATABASE_URL=(not set)\n")
  end

  it 'leaves a dsl run alone where there is no .env, as on CI' do
    expect(tapioca('dsl')).to eq("tapioca dsl\nDATABASE_URL=(not set)\n")
  end

  it 'keeps a DATABASE_URL that is set already' do
    out = tapioca('dsl', dotenv_text: "TEST_DB_SUFFIX=_fix_it\n", env: { 'DATABASE_URL' => 'postgresql:///other' })

    expect(out).to eq("tapioca dsl\nDATABASE_URL=postgresql:///other\n")
  end

  it 'changes nothing for the other commands' do
    out = tapioca('gem', '--verify', dotenv_text: "TEST_DB_SUFFIX=_fix_it\n")

    expect(out).to eq("tapioca gem --verify\nDATABASE_URL=(not set)\n")
  end
end
