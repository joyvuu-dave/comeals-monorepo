# frozen_string_literal: true

module ChallengeDocs
  # The fingerprints of the files each challenge watches, in
  # docs/challenges/watched.txt, one line per file: "<id> <path> <sha256>".
  # When a watched file changes, its fingerprint no longer matches, and the
  # check fails until someone reads the doc again and marks it reviewed.
  module Watches
    FILE = 'watched.txt'

    module_function

    def recorded(dir)
      path = File.join(dir, FILE)
      File.exist?(path) ? File.readlines(path, chomp: true).reject(&:empty?) : []
    end

    def line(id, path, root)
      "#{format('%04d', id)} #{path} #{Digest::SHA256.file(File.join(root, path)).hexdigest}"
    end

    def problems(dir, docs, root)
      missing = []
      expected = []
      docs.each do |doc|
        doc.watches.each do |path|
          if File.exist?(File.join(root, path))
            expected << line(doc.front['id'], path, root)
          else
            missing << "#{doc.name} watches #{path}, which does not exist"
          end
        end
      end
      missing + changed(expected, recorded(dir)) + unwatched(expected, recorded(dir))
    end

    def changed(expected, recorded)
      (expected - recorded).map do |want|
        id, path = want.split
        if recorded.any? { |old| old.split[0, 2] == [id, path] }
          "#{path} changed since challenge #{id.to_i} was reviewed. Read what that doc says about it, " \
            "fix the doc, then run bin/challenges reviewed #{id.to_i}"
        else
          "Challenge #{id.to_i} watches #{path}, but was not reviewed since; run bin/challenges reviewed #{id.to_i}"
        end
      end
    end

    def unwatched(expected, recorded)
      keys = expected.map { |want| want.split[0, 2] }
      recorded.reject { |old| keys.include?(old.split[0, 2]) }.map do |old|
        id, path = old.split
        "#{FILE} has #{path} for challenge #{id.to_i}, which does not watch it; run bin/challenges reviewed #{id.to_i}"
      end
    end

    # Marks a challenge as read again today: its reviewed date, the
    # fingerprints of the files it watches, and the index. Returns nil, or
    # the problem that stopped it.
    def mark_reviewed(dir, id, root:, today:)
      doc = ChallengeDocs.docs(dir).find { |each| each.front && each.front['id'] == id }
      return "No challenge has id #{id}" unless doc

      File.write(doc.path, File.read(doc.path).sub(/^reviewed: .*$/, "reviewed: #{today}"))
      others = recorded(dir).reject { |old| old.split.first.to_i == id }
      mine = doc.watches.select { |path| File.exist?(File.join(root, path)) }.map { |path| line(id, path, root) }
      File.write(File.join(dir, FILE), (others + mine).sort.map { |each| "#{each}\n" }.join)
      Index.write(dir)
    end
  end
end
