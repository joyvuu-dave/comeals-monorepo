# frozen_string_literal: true

require 'rails_helper'

# spec/support/spa_page.rb writes a stand-in public/index.html for the
# request specs when there is no front-end build (#142). These examples
# point it at a file of their own under tmp/, so they never write or
# delete the real page, which other processes in this checkout may be
# reading at the same time.
RSpec.describe SpaPage do
  let(:dir) { Rails.root.join('tmp', "spa-page-spec-#{Process.pid}") }
  let(:page) { dir.join('index.html') }

  before do
    dir.mkpath
    stub_const('SpaPage::PATH', page)
  end

  after { dir.rmtree }

  it 'writes the stand-in page' do
    described_class.write_unless_present

    expect(page.read).to eq(SpaPage::STAND_IN)
  end

  # A build writes the page as 0644. The stand-in stays after the run,
  # and a later build writes into the same file and keeps its mode.
  it 'lets everyone read the stand-in page, as a built page does' do
    described_class.write_unless_present

    expect(format('%o', page.stat.mode & 0o777)).to eq('644')
  end

  it 'leaves a page that is already there alone' do
    page.write('built page')

    described_class.write_unless_present

    expect(page.read).to eq('built page')
  end

  it 'leaves the page alone when another process writes one between the check and the link' do
    allow(page).to receive(:exist?) do
      page.write('page from another process')
      false
    end

    described_class.write_unless_present

    expect(page.read).to eq('page from another process')
  end
end
