# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('bin/lib/certificate_check').to_s

RSpec.describe CertificateCheck do
  let(:now) { Time.utc(2026, 11, 16, 12) }

  def pem(not_after:, name: 'comeals.com')
    key = OpenSSL::PKey::EC.generate('prime256v1')
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.public_key = key
    cert.not_before = not_after - (90 * 86_400)
    cert.not_after = not_after
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    cert.to_pem
  end

  # What openssl s_client prints, cut down to the lines that are read.
  def answer(not_after:, verify: '0 (ok)')
    "CONNECTED(00000003)\n---\nServer certificate\n#{pem(not_after:)}subject=CN=comeals.com\n---\n" \
      "Verify return code: #{verify}\n---\n"
  end

  def shell(text, success: true, error: '')
    DeployWatch::Shell::Result.new(success, text, error)
  end

  describe '.read' do
    it 'asks openssl for the certificate and whether it is trusted for that name' do
      allow(DeployWatch::Shell).to receive(:run).and_return(shell(answer(not_after: Time.utc(2027, 1, 12, 2, 29))))

      reading = described_class.read('admin.comeals.com')

      expect(DeployWatch::Shell).to have_received(:run).with(
        'openssl', 's_client', '-connect', 'admin.comeals.com:443', '-servername', 'admin.comeals.com',
        '-verify_hostname', 'admin.comeals.com', timeout: 30
      )
      expect(reading.to_h).to eq(host: 'admin.comeals.com', not_after: Time.utc(2027, 1, 12, 2, 29), verify: nil)
    end

    it 'keeps the reason when the certificate is not trusted, and still reads its end date' do
      allow(DeployWatch::Shell).to receive(:run)
        .and_return(shell(answer(not_after: Time.utc(2027, 1, 1), verify: '62 (hostname mismatch)'), success: false))

      expect(described_class.read('admin.comeals.com').to_h)
        .to eq(host: 'admin.comeals.com', not_after: Time.utc(2027, 1, 1), verify: 'hostname mismatch')
    end

    it 'cannot read an answer with no certificate' do
      refused = shell("connect: Connection refused\n", success: false, error: 'connect:errno=61')
      allow(DeployWatch::Shell).to receive(:run).and_return(refused)

      expect { described_class.read('comeals.com') }
        .to raise_error(CertificateCheck::Unreadable, 'comeals.com: no certificate in the answer (connect:errno=61)')
    end

    it 'cannot read an answer with a certificate and no verify code' do
      allow(DeployWatch::Shell).to receive(:run).and_return(shell(pem(not_after: now), success: false,
                                                                                       error: 'no answer after 30 s'))

      expect { described_class.read('comeals.com') }
        .to raise_error(CertificateCheck::Unreadable,
                        'comeals.com: no certificate in the answer (no answer after 30 s)')
    end

    it 'cannot read a certificate that is broken' do
      broken = "-----BEGIN CERTIFICATE-----\nnot a certificate\n-----END CERTIFICATE-----\nVerify return code: 0 (ok)\n"
      allow(DeployWatch::Shell).to receive(:run).and_return(shell(broken))

      expect { described_class.read('comeals.com') }
        .to raise_error(CertificateCheck::Unreadable, /\Acomeals\.com: the certificate could not be read \(.+\)\z/)
    end
  end

  describe '.problems' do
    def reading(days, verify: nil, seconds: 0)
      CertificateCheck::Reading.new('api.comeals.com', now + (days * 86_400) + seconds, verify)
    end

    it 'finds nothing wrong with 21 days or more left' do
      expect(described_class.problems(reading(21), now)).to eq([])
    end

    it 'says when and in how many days a certificate runs out, with fewer than 21 days left' do
      expect(described_class.problems(reading(21, seconds: -1), now))
        .to eq(['api.comeals.com: the certificate runs out on 2026-12-07, in 20 days'])
    end

    it 'says "1 day", not "1 days"' do
      expect(described_class.problems(reading(1),
                                      now)).to eq(['api.comeals.com: the certificate runs out on 2026-11-17, in 1 day'])
    end

    it 'counts the last day as 0 days left' do
      expect(described_class.problems(reading(0, seconds: 1), now))
        .to eq(['api.comeals.com: the certificate runs out on 2026-11-16, in 0 days'])
    end

    it 'says when a certificate has run out' do
      expect(described_class.problems(reading(0, seconds: -1),
                                      now)).to eq(['api.comeals.com: the certificate ran out on 2026-11-16'])
    end

    it 'says when a certificate is not trusted for the name, even with time left' do
      expect(described_class.problems(reading(60, verify: 'hostname mismatch'), now))
        .to eq(['api.comeals.com: the certificate is not trusted (hostname mismatch)'])
    end
  end

  describe '.summary' do
    it 'gives the end date and the days left' do
      reading = CertificateCheck::Reading.new('comeals.com', Time.utc(2027, 1, 12, 2, 29), nil)

      expect(described_class.summary(reading, now)).to eq('comeals.com: runs out on 2027-01-12, in 56 days')
    end
  end

  describe '.main' do
    let(:out) { StringIO.new }

    def certificates(days)
      allow(DeployWatch::Shell).to receive(:run) do |*command, **|
        host = command[3].delete_suffix(':443')
        shell(answer(not_after: now + (days.fetch(host) * 86_400)))
      end
    end

    it 'reads every production hostname, and says 0 when all are fine' do
      certificates('comeals.com' => 56, 'www.comeals.com' => 56, 'admin.comeals.com' => 30, 'api.comeals.com' => 30)

      expect(described_class.main(['comeals-monorepo'], out:, now:)).to eq(0)
      expect(out.string.lines.map(&:chomp)).to eq(
        ['comeals.com: runs out on 2027-01-11, in 56 days', 'www.comeals.com: runs out on 2027-01-11, in 56 days',
         'admin.comeals.com: runs out on 2026-12-16, in 30 days', 'api.comeals.com: runs out on 2026-12-16, in 30 days']
      )
    end

    it 'shows only the problems, and says 1, when one certificate runs out soon' do
      certificates('comeals.com' => 56, 'www.comeals.com' => 56, 'admin.comeals.com' => 9, 'api.comeals.com' => 30)

      expect(described_class.main(['comeals-monorepo'], out:, now:)).to eq(1)
      expect(out.string).to eq("admin.comeals.com: the certificate runs out on 2026-11-25, in 9 days\n")
    end

    it 'reads the one staging hostname' do
      certificates('comeals-staging-ad51b8a1eb64.herokuapp.com' => 176)

      expect(described_class.main(['comeals-staging'], out:, now:)).to eq(0)
      expect(out.string).to eq("comeals-staging-ad51b8a1eb64.herokuapp.com: runs out on 2027-05-11, in 176 days\n")
    end

    it 'says 2, could not check, when a certificate cannot be read' do
      allow(DeployWatch::Shell).to receive(:run).and_return(shell('', success: false, error: 'no answer after 30 s'))

      expect(described_class.main(['comeals-staging'], out:, now:)).to eq(2)
      expect(out.string).to eq('could not check: comeals-staging-ad51b8a1eb64.herokuapp.com: ' \
                               'no certificate in the answer ' \
                               "(no answer after 30 s)\n")
    end

    it 'says 2 for an app it has no hostnames for, or no app' do
      expect([described_class.main(['comeals-other'], out:, now:), described_class.main([], out:, now:)]).to eq([2, 2])
      expect(out.string).to eq(%(could not check: no hostnames for the app "comeals-other"\n) +
                               %(could not check: no hostnames for the app ""\n))
    end
  end

  it 'runs as a script, with its answer as the exit status' do
    fakes = Dir.mktmpdir
    File.write(File.join(fakes, 'openssl'), "#!/bin/sh\necho 'connect: Connection refused' >&2\nexit 1\n")
    File.chmod(0o755, File.join(fakes, 'openssl'))

    script = Rails.root.join('bin/lib/certificate_check.rb').to_s
    out, status = run_ruby_script(RbConfig.ruby, script, 'comeals-staging',
                                  env: { 'PATH' => "#{fakes}:#{ENV.fetch('PATH')}" })

    expect([out, status.exitstatus]).to eq(
      ['could not check: comeals-staging-ad51b8a1eb64.herokuapp.com: no certificate in the answer ' \
       "(connect: Connection refused)\n", 2]
    )
  ensure
    FileUtils.remove_entry(fakes)
  end
end
