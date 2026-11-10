# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# config/mutant/method_name_check.rb: mutant 0.17.1 raises on a module
# whose `name` is a fake value with an apostrophe, such as Faker::Name's,
# and stops before it mutates anything. Each example runs in its own
# process, because loading mutant prints a warning about the parser gem.
RSpec.describe 'config/mutant/method_name_check.rb' do # -- a fix to a gem, loaded by config/mutant/hooks.rb
  def probe(code)
    script = <<~RUBY
      require 'mutant'
      require './config/mutant/method_name_check'
      #{code}
    RUBY
    output, status = Open3.capture2e({ 'RUBYOPT' => nil }, 'bundle', 'exec', 'ruby', '-e', script,
                                     chdir: Rails.root.to_s)
    expect(status).to be_success, output
    output.lines.last.chomp
  end

  it 'shows that mutant raises on the fake name without the fix' do
    expect(probe(<<~RUBY)).to eq('Parser::SyntaxError')
      begin
        Mutant::Expression::Method.try_parse("Mr. Patrick O'Keefe")
        puts 'no error'
      rescue Parser::SyntaxError => e
        puts e.class
      end
    RUBY
  end

  it 'reads the fake name as no expression with the fix, and a real method name as one' do
    expect(probe(<<~RUBY)).to eq('[nil, "Settlement.allocate_to_cents"]')
      MutantMethodNameCheck.apply
      p [Mutant::Expression::Method.try_parse("Mr. Patrick O'Keefe"),
         Mutant::Expression::Method.try_parse('Settlement.allocate_to_cents').syntax]
    RUBY
  end

  it 'refuses to apply to another version of mutant' do
    expect(probe(<<~RUBY)).to eq('mutant is 0.18.0, not 0.17.1: read config/mutant/method_name_check.rb')
      Mutant.send(:remove_const, :VERSION)
      Mutant.const_set(:VERSION, '0.18.0')
      begin
        MutantMethodNameCheck.apply
      rescue RuntimeError => e
        puts e.message
      end
    RUBY
  end
end
