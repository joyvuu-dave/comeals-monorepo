# frozen_string_literal: true

require 'openssl'
require_relative 'deploy_watch/shell'

# Reads the HTTPS certificate each public hostname sends, and says when one
# runs out soon or is not trusted for that name. It only reads: one TLS
# handshake per hostname, with `openssl s_client`. bin/deploy runs this file
# before it changes anything, and bin/watch-deploy reads it as one of its
# checks (#297).
#
# Heroku's Automatic Certificate Management renews each Let's Encrypt
# certificate about 30 days before it runs out. If a renewal fails, nothing
# else here notices, and when the certificate runs out residents see a
# browser security warning in place of the app. Better Stack watches only
# comeals.com, so this is the only check on the other hostnames.
module CertificateCheck
  class Unreadable < StandardError; end

  Reading = Struct.new(:host, :not_after, :verify)

  # Keep in step with HEALTH_URLS in bin/deploy. Staging has only its
  # herokuapp hostname, which uses Heroku's own certificate.
  HOSTS = {
    'comeals-monorepo' => %w[comeals.com www.comeals.com admin.comeals.com api.comeals.com],
    'comeals-staging' => %w[comeals-staging-ad51b8a1eb64.herokuapp.com]
  }.freeze
  # Heroku renews at about 30 days left, so fewer than 21 means a renewal
  # has failed for at least 9 days, and there are still 3 weeks to fix it.
  WITHIN_DAYS = 21
  COMMAND_TIMEOUT = 30
  PEM = /-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m
  VERIFY = /^Verify return code: (\d+) \((.*)\)$/

  module_function

  # -verify_hostname makes the verify code say whether the certificate is
  # trusted for this name. Without -verify_return_error the handshake still
  # finishes on a bad certificate, so its end date can be read too.
  def read(host)
    result = DeployWatch::Shell.run('openssl', 's_client', '-connect', "#{host}:443", '-servername', host,
                                    '-verify_hostname', host, timeout: COMMAND_TIMEOUT)
    pem = result.out[PEM]
    verify = result.out[VERIFY]
    raise Unreadable, "#{host}: no certificate in the answer (#{result.error})" unless pem && verify

    code, text = verify.match(VERIFY).captures
    Reading.new(host, OpenSSL::X509::Certificate.new(pem).not_after, code == '0' ? nil : text)
  rescue OpenSSL::X509::CertificateError => e
    raise Unreadable, "#{host}: the certificate could not be read (#{e.message})"
  end

  def days_left(reading, now) = ((reading.not_after - now) / 86_400).floor

  # One line for each thing wrong with a reading, or none.
  def problems(reading, now)
    days = days_left(reading, now)
    date = reading.not_after.utc.strftime('%Y-%m-%d')
    [
      ("#{reading.host}: the certificate is not trusted (#{reading.verify})" if reading.verify),
      if days.negative?
        "#{reading.host}: the certificate ran out on #{date}"
      elsif days < WITHIN_DAYS
        "#{reading.host}: the certificate runs out on #{date}, in #{days} #{days == 1 ? 'day' : 'days'}"
      end
    ].compact
  end

  # One line for a reading with no problem.
  def summary(reading, now)
    "#{reading.host}: runs out on #{reading.not_after.utc.strftime('%Y-%m-%d')}, in #{days_left(reading, now)} days"
  end

  # bin/deploy: 0 when every certificate is fine, 1 when one is not, and 2
  # when one could not be read.
  def main(argv, out: $stdout, now: Time.now)
    hosts = HOSTS.fetch(argv.first.to_s) { |app| raise Unreadable, "no hostnames for the app \"#{app}\"" }
    readings = hosts.map { |host| read(host) }
    bad = readings.flat_map { |reading| problems(reading, now) }
    lines = bad.empty? ? readings.map { |reading| summary(reading, now) } : bad
    out.puts(lines)
    bad.empty? ? 0 : 1
  rescue Unreadable => e
    out.puts("could not check: #{e.message}")
    2
  end
end

exit(CertificateCheck.main(ARGV)) if $PROGRAM_NAME == __FILE__
