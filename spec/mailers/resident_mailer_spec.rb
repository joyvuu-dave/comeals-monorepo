# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ResidentMailer do
  let(:community) { create(:community, name: "Swan's Way") }
  let(:unit) { create(:unit, community: community) }
  let(:resident) do
    create(:resident, community: community, unit: unit, name: 'Sarah Chen', email: 'sarah@example.com')
  end

  describe '#password_reset_email' do
    # PasswordReset makes the token and stores only its digest, so the
    # mailer takes the token itself.
    let(:mail) { described_class.password_reset_email(resident, 'abc123token') }

    it 'sends to the resident email' do
      expect(mail.to).to eq(['sarah@example.com'])
    end

    it 'has the correct subject' do
      expect(mail.subject).to eq('Reset your password')
    end

    it 'includes the reset token URL in the body' do
      expect(mail.body.encoded).to include('abc123token')
    end

    it 'links to the reset page under the configured app root, in the text part' do
      expect(mail.text_part.body.decoded.lines.map(&:chomp))
        .to include('To reset your password, follow this link: http://localhost:3036/reset-password#token=abc123token.')
    end

    it 'greets the resident by name' do
      expect(mail.body.encoded).to include('Sarah Chen')
    end

    it_behaves_like 'an HTML part that is one HTML document'

    it 'keeps the greeting, the words and the reset link in the HTML part' do
      body = html_body(mail)

      expect(body.text.squish).to eq('Reset your Comeals.com password, Sarah Chen ' \
                                     'To reset your password, follow this link. Have a great day!')
      expect(links_in(body)).to eq([['follow this link.', 'http://localhost:3036/reset-password#token=abc123token']])
    end
  end

  # A change of email waits in pending_email until the link is opened
  # (EmailChange). These two groups are the only examples mutant runs for
  # the two methods, so each one checks every part of its mail.
  describe '#email_change_link_email' do
    let(:mail) do
      resident.pending_email = 'sarah.new@example.com'
      described_class.email_change_link_email(resident, 'abc123token')
    end

    it 'goes to the new address, with its subject' do
      expect(mail.to).to eq(['sarah.new@example.com'])
      expect(mail.subject).to eq('Confirm your new email')
    end

    it 'names the new address and links to the confirm page under the app root, in the text part' do
      expect(mail.text_part.body.decoded.lines.map(&:chomp)).to include(
        'Confirm your new Comeals.com email, Sarah Chen',
        'To make sarah.new@example.com your email, follow this link: ' \
        'http://localhost:3036/confirm-email#token=abc123token'
      )
    end

    it_behaves_like 'an HTML part that is one HTML document'

    it 'keeps the name, the new address and the link in the HTML part' do
      body = html_body(mail)

      expect(body.text.squish).to eq(
        'Confirm your new Comeals.com email, Sarah Chen ' \
        'To make sarah.new@example.com your email, follow this link. ' \
        'The link works for 24 hours. Until you follow it, sign in with your old email. ' \
        'If you did not ask for this, you can ignore this email.'
      )
      expect(links_in(body)).to eq([['follow this link.', 'http://localhost:3036/confirm-email#token=abc123token']])
    end
  end

  describe '#email_change_notice_email' do
    let(:mail) do
      resident.pending_email = 'sarah.new@example.com'
      described_class.email_change_notice_email(resident, 'sarah@example.com')
    end

    it 'goes to the old address, with its subject' do
      expect(mail.to).to eq(['sarah@example.com'])
      expect(mail.subject).to eq('Your Comeals email is being changed')
    end

    it 'names the resident and the new address in the text part' do
      expect(mail.text_part.body.decoded.lines.map(&:chomp)).to include(
        'Your Comeals.com email is being changed, Sarah Chen',
        'Someone signed in as you asked to change your email to sarah.new@example.com.'
      )
    end

    it_behaves_like 'an HTML part that is one HTML document'

    it 'names the resident and the new address in the HTML part' do
      expect(html_body(mail).text.squish).to eq(
        'Your Comeals.com email is being changed, Sarah Chen ' \
        'Someone signed in as you asked to change your email to sarah.new@example.com. ' \
        'It changes only when the link sent to that address is followed. ' \
        'If that was you, there is nothing to do here. If it was not, sign in, ' \
        'open your profile, and put this address back, or ask an admin.'
      )
    end
  end

  # A rotation's period is the span of its meals' dates.
  def rotation_with_meals(*dates)
    create(:rotation, community: community).tap do |rotation|
      dates.each { |date| create(:meal, community: community, rotation: rotation, date: date) }
    end
  end

  describe '#rotation_signup_email' do
    let(:rotation) { rotation_with_meals(Date.new(2026, 4, 1), Date.new(2026, 4, 2), Date.new(2026, 4, 3)) }
    let(:open_dates) { [Date.new(2026, 4, 1), Date.new(2026, 4, 3)] }
    let(:mail) { described_class.rotation_signup_email(resident, rotation, open_dates, community) }

    it 'sends to the resident email' do
      expect(mail.to).to eq(['sarah@example.com'])
    end

    it 'has the correct subject' do
      expect(mail.subject).to eq('Sign up to Cook')
    end

    it 'gives the address of the app in the text part' do
      expect(mail.text_part.body.decoded.lines.map(&:chomp)).to include('Sign up now: http://localhost:3036.')
    end

    # The open dates are the point of this mail. They go in one list, and
    # the list ends after the last date, so the sign-up line and the
    # sign-off are not list items. The template once opened a second <ul>
    # where it should have closed the first (#90).
    it 'lists the open dates in one closed list' do
      html = Nokogiri::HTML(mail.html_part.body.decoded)

      expect(html.css('ul li').map { |li| li.text.strip }).to eq(%w[2026-04-01 2026-04-03])
      expect(html.css('ul').size).to eq(1)
      expect(html.css('ul p').map { |p| p.text.squish }).to eq([])
    end

    it 'lists the open dates in the text part too, one to a line' do
      lines = mail.text_part.body.decoded.lines.map(&:strip)

      expect(lines).to include('2026-04-01', '2026-04-03')
      expect(lines).not_to include('2026-04-02')
    end

    it 'names the period of the rotation that needs cooks, in both parts' do
      sentence = 'We still need cooks for the rotation happening Apr 1–3, 2026.'

      expect(Nokogiri::HTML(mail.html_part.body.decoded).text.squish).to include(sentence)
      expect(mail.text_part.body.decoded).to include(sentence)
    end

    it_behaves_like 'an HTML part that is one HTML document'

    # The HTML part writes the app's address as words, not as a link.
    it 'keeps the name, the period, the dates and the address in the HTML part' do
      body = html_body(mail)

      expect(body.text.squish).to eq(
        'Sarah Chen, please sign up to cook ' \
        'We still need cooks for the rotation happening Apr 1–3, 2026. ' \
        'The following dates are still available: 2026-04-01 2026-04-03 ' \
        "Sign up now: http://localhost:3036. Have a great day! ~Swan's Way"
      )
      expect(links_in(body)).to eq([])
    end
  end

  describe '#new_rotation_email' do
    let(:rotation) { rotation_with_meals(Date.new(2026, 4, 1), Date.new(2026, 5, 12)) }
    let(:mail) { described_class.new_rotation_email(resident, rotation, community) }

    it 'sends to the resident email' do
      expect(mail.to).to eq(['sarah@example.com'])
    end

    it 'has the correct subject' do
      expect(mail.subject).to eq('New Rotation Posted')
    end

    it 'includes the community name' do
      expect(mail.body.encoded).to include('Swan')
    end

    it 'names the period the new rotation covers, in both parts' do
      sentence = 'A new meal rotation has just been created for the period Apr 1 – May 12, 2026.'

      expect(Nokogiri::HTML(mail.html_part.body.decoded).text.squish).to include(sentence)
      expect(mail.text_part.body.decoded).to include(sentence)
    end

    it 'underlines the title of the text part with = signs and nothing else' do
      expect(mail.text_part.body.decoded.lines.first(2).map(&:chomp))
        .to eq(['New Rotation Posted', '=' * 'New Rotation Posted'.length])
    end

    it 'links to the configured app root in the text part' do
      expect(mail.text_part.body.decoded.lines.map(&:chomp))
        .to include('Sign up to cook and attend dinner now: http://localhost:3036.')
    end

    it_behaves_like 'an HTML part that is one HTML document'

    it 'keeps the period, the sign-up link and the community name in the HTML part' do
      body = html_body(mail)

      expect(body.text.squish).to eq(
        'New Rotation Posted ' \
        'A new meal rotation has just been created for the period Apr 1 – May 12, 2026. ' \
        "Sign up to cook and attend dinner now. Have a great day! ~Swan's Way"
      )
      expect(links_in(body)).to eq([['Sign up', 'http://localhost:3036']])
    end
  end
end
