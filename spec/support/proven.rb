# frozen_string_literal: true

require 'open3'

# The Python that Dafny made from the proofs in proofs/ (docs/proofs.md,
# "The Ruby against the proofs"). A spec hands it every input at once;
# it answers each with the one answer the proven rules allow, or with
# {"refused" => true} for an input that no proof covers.
#
# The proofs show that only one answer follows each rule. So when the
# Ruby gives the same answer on an input, the Ruby follows the proven
# rule on that input.
#
# The requests and the answers are described in proofs/run_proven.py.
# Amounts are whole units of 10^-8 dollars.
#
# Like spec/support/oracle/plain_ledger.rb, the proofs are a separate copy
# of the rules. Never edit them to match the Ruby.
module Proven
  SCRIPT = File.expand_path('../../proofs/run_proven.py', __dir__)

  # One answer per request, in the same order. Starts the Python once.
  # -I: only the generated code can be imported. -B: no __pycache__ in
  # proofs/generated-py.
  def self.answers(requests)
    Open3.popen3('python3', '-I', '-B', SCRIPT) do |stdin, stdout, stderr, wait|
      # Written from a second thread while this one reads, so neither
      # side waits on a full pipe.
      writer = Thread.new do
        requests.each { |request| stdin.puts(JSON.generate(request)) }
      rescue Errno::EPIPE
        nil # the Python stopped; its status and stderr say why
      ensure
        stdin.close
      end
      errors = Thread.new { stderr.read }
      answers = stdout.each_line.map { |line| JSON.parse(line) }
      writer.join
      status = wait.value

      raise "proofs/run_proven.py failed (#{status}):\n#{errors.value}" unless status.success?
      raise "sent #{requests.size} requests, got #{answers.size} answers" unless answers.size == requests.size

      answers
    end
  end

  # A dollar amount as whole units, the way the proofs take it. Not
  # MealLedger.units, which is the code being compared.
  def self.units(amount)
    scaled = amount * 100_000_000
    raise ArgumentError, "#{amount.to_s('F')} is not a whole number of 10^-8 dollars" unless scaled.frac.zero?

    scaled.to_i
  end

  # The request for one meal's lines, from the rows MealLedger reads.
  def self.dinner_request(meal)
    {
      dinner: {
        cooks: meal.bills.map { |bill| [bill.resident_id, units(bill.amount), bill.no_cost] },
        eaters: meal.meal_residents.map { |row| [row.resident_id, false, row.id, row.multiplier] } +
          meal.guests.map { |row| [row.resident_id, true, row.id, row.multiplier] },
        cap: meal.cap && units(meal.cap),
        cancelled: meal.cancelled?
      }
    }
  end

  # The lines in an answer to a dinner request, in the shape
  # .ledger_lines gives MealLedger's: [kind, resident id, multiplier,
  # signed units], sorted. A charge is negated, as on a debit line.
  def self.dinner_lines(answer)
    credits = answer.fetch('credits').map { |resident_id, amount| ['credit', resident_id, nil, amount] }
    charges = answer.fetch('charges').map do |resident_id, guest, _row_id, multiplier, amount|
      [guest ? 'guest_debit' : 'debit', resident_id, multiplier, -amount]
    end
    sort_lines(credits + charges)
  end

  # MealLedger's lines of one meal in the same shape. A line names the
  # resident and the multiplier, not the row, so two guests of one host
  # with the same multiplier cannot be told apart; nothing stored can
  # tell them apart either (meal_charges has no guest id).
  def self.ledger_lines(lines)
    sort_lines(lines.map { |line| [line.kind.to_s, line.resident_id, line.multiplier, units(line.amount)] })
  end

  def self.sort_lines(lines)
    lines.sort_by { |kind, resident_id, multiplier, amount| [kind, resident_id, multiplier || -1, amount] }
  end
end
