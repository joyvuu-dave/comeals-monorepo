# frozen_string_literal: true

# Reads a mail's HTML part the way a mail program shows it.
module MailParts
  # The <body> of the HTML part, parsed the way a browser parses it.
  def html_body(mail)
    Nokogiri::HTML5(mail.html_part.body.decoded).at('body')
  end

  # Each link in a node, as [its words, its URL].
  def links_in(node)
    node.css('a').map { |link| [link.text, link['href']] }
  end
end

RSpec.configure do |config|
  config.include MailParts, type: :mailer
end
