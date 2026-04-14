# frozen_string_literal: true

namespace :reconciliations do
  desc 'Recalculate settlement balances for all reconciliations using largest-remainder allocation.'
  task recalculate_balances: :environment do
    reconciliations = Reconciliation.order(:date).to_a
    total = reconciliations.size

    puts "Recalculating settlement balances for #{total} reconciliations..."

    reconciliations.each_with_index do |reconciliation, i|
      reconciliation.persist_balances!
      puts "  [#{i}/#{total}] Reconciliation ##{reconciliation.id} (#{reconciliation.date}) — OK"
    end

    puts "Done. All #{total} reconciliations recalculated."
  end
end
