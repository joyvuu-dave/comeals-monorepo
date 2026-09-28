# frozen_string_literal: true

# The mailer layout (app/views/layouts/mailer.html.erb) writes the
# DOCTYPE, <html>, <head> and <body> of every HTML mail. A template
# writes only what goes inside <body>. Each HTML template once wrote a
# whole document of its own too, so every HTML mail held two, one inside
# the other's <body>. The including spec defines `mail`.
RSpec.shared_examples 'an HTML part that is one HTML document' do
  let(:html_source) { mail.html_part.body.decoded }

  it 'has one DOCTYPE, one <html>, one <head> and one <body>' do
    expect(html_source.scan(/<!DOCTYPE/i).size).to eq(1)
    expect(html_source.scan(/<html[\s>]/i).size).to eq(1)
    expect(html_source.scan(/<head[\s>]/i).size).to eq(1)
    expect(html_source.scan(/<body[\s>]/i).size).to eq(1)
  end

  # A second DOCTYPE, <html>, <head> or <body> inside <body> is a parse
  # error, and so is any other tag in the wrong place.
  it 'parses as HTML5 with no errors' do
    expect(Nokogiri::HTML5(html_source, max_errors: 10).errors.map(&:to_s)).to eq([])
  end
end
