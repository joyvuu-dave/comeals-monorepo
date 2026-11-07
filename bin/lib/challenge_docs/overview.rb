# frozen_string_literal: true

module ChallengeDocs
  module Html
    # The top of the page: the counts, the progress bar, the table by area,
    # and the lists of what is left and what is finished.
    module Overview
      module_function

      def unknowns(doc) = doc.sections['Where we stand'].to_s.scan(UNKNOWN).size

      def unread_sources(doc) = doc.sections['Outside facts'].to_s.scan(UNREAD_SOURCE).size

      def badges(doc)
        found = []
        count = unknowns(doc)
        found << "<span class=\"badge\">#{count} not checked</span>" if count.positive?
        count = unread_sources(doc)
        found << "<span class=\"badge\">#{count} outside fact#{'s' if count > 1} to read</span>" if count.positive?
        found.join
      end

      def link(doc)
        front = doc.front
        "<a href=\"#challenge-#{front['id']}\"><span class=\"num\">#{front['id']}</span> #{Html.h(front['title'])}</a>"
      end

      def list_item(doc, area: true)
        "<li>#{link(doc)} #{Html.chip('area', doc.front['area']) if area}#{badges(doc)}</li>"
      end

      def summary(docs)
        counts = Hash.new(0).merge(docs.map { |doc| doc.front['status'] }.tally)
        total = docs.size
        left = REMAINING.sum { |status| counts[status] }
        bar = (FINISHED + REMAINING).map do |status|
          width = total.zero? ? 0 : (counts[status] * 100.0 / total).round(2)
          "<span class=\"seg status-#{status}\" style=\"width: #{width}%\" " \
            "title=\"#{STATUS_WORDS[status]}: #{counts[status]}\"></span>"
        end
        legend = (FINISHED + REMAINING).map do |status|
          "<li>#{Html.chip('status', status, STATUS_WORDS[status])} #{counts[status]}</li>"
        end
        <<~HTML
          <section class="cards">
            <div class="card big"><div class="n">#{left}</div><div>still to do, of #{total}</div></div>
            <div class="card"><div class="n">#{counts['done'] + counts['declined']}</div><div>finished (done or declined)</div></div>
            <div class="card"><div class="n">#{docs.sum { |doc| unknowns(doc) }}</div><div>things marked "not checked"</div></div>
            <div class="card"><div class="n">#{docs.sum { |doc| unread_sources(doc) }}</div><div>outside facts whose source nobody has read</div></div>
          </section>
          <div class="bar" role="img" aria-label="#{counts['done'] + counts['declined']} of #{total} finished">#{bar.join}</div>
          <ul class="legend">#{legend.join}</ul>
        HTML
      end

      def areas(docs)
        rows = AREAS.filter_map do |area|
          mine = docs.select { |doc| doc.front['area'] == area }
          next if mine.empty?

          cells = (FINISHED + REMAINING).map { |status| mine.count { |doc| doc.front['status'] == status } }
          left = mine.count { |doc| REMAINING.include?(doc.front['status']) }
          "<tr><th>#{Html.chip('area', area)}</th>#{cells.map { |n| "<td>#{n unless n.zero?}</td>" }.join}" \
            "<td class=\"left\">#{left}</td></tr>"
        end
        heads = (FINISHED + REMAINING).map { |status| "<th>#{STATUS_WORDS[status]}</th>" }.join
        <<~HTML
          <div class="scroll"><table class="areas">
            <thead><tr><th>Area</th>#{heads}<th>Still to do</th></tr></thead>
            <tbody>#{rows.join("\n")}</tbody>
          </table></div>
        HTML
      end

      # The items under a small heading for each area, in the order of AREAS.
      def by_area(docs)
        AREAS.filter_map do |area|
          mine = docs.select { |doc| doc.front['area'] == area }
          next if mine.empty?

          "<li class=\"area-head\">#{Html.h(area)}</li>#{mine.map { |doc| list_item(doc, area: false) }.join}"
        end.join
      end

      def remaining(docs)
        columns = REMAINING.map do |status|
          mine = docs.select { |doc| doc.front['status'] == status }
          items = mine.empty? ? '<li class="none">None.</li>' : by_area(mine)
          "<div class=\"column column-#{status}\"><h3>#{Html.chip('status', status, STATUS_WORDS[status])} " \
            "#{mine.size}</h3><ul>#{items}</ul></div>"
        end
        finished = docs.select { |doc| FINISHED.include?(doc.front['status']) }
        done = finished.empty? ? '<li class="none">None yet.</li>' : finished.map { |doc| list_item(doc) }.join
        "<div class=\"columns\">#{columns.join}</div>\n<h3>Finished</h3><ul class=\"finished\">#{done}</ul>"
      end
    end
  end
end
