# frozen_string_literal: true

module ChallengeDocs
  # The command line: bin/challenges <command>. Each command returns the
  # exit status: 0 when it worked, 1 when it found a problem, 2 for usage.
  module CLI
    Context = Struct.new(:dir, :root, :today, :out)
    COMMANDS = { 'check' => :check, 'index' => :index, 'reviewed' => :reviewed, 'new' => :create }.freeze
    USAGE = <<~USAGE
      Usage:
        bin/challenges check              check every rule in docs/challenges/README.md
        bin/challenges index              write the index table in README.md
        bin/challenges reviewed ID [ID]   mark challenges as read again today
        bin/challenges new AREA TITLE     start a new challenge from the template
    USAGE

    module_function

    def run(argv, dir:, root:, today:, out: $stdout)
      command, *rest = argv
      method = COMMANDS[command]
      return usage(out) unless method

      public_send(method, rest, Context.new(dir, root, today, out))
    end

    def check(_rest, context)
      found = ChallengeDocs.problems(context.dir, root: context.root, today: context.today)
      found.each { |problem| context.out.puts(problem) }
      return 1 if found.any?

      context.out.puts("ok: #{ChallengeDocs.docs(context.dir).size} challenges, no problems")
      0
    end

    def index(_rest, context) = finish(Index.write(context.dir), context.out)

    def reviewed(ids, context)
      return usage(context.out) if ids.empty? || !ids.all?(/\A\d+\z/)

      problems = ids.filter_map do |id|
        Watches.mark_reviewed(context.dir, id.to_i, root: context.root, today: context.today)
      end
      finish(problems.first, context.out)
    end

    def create(rest, context)
      area, *words = rest
      return usage(context.out) if words.empty?

      title = words.join(' ')
      problem = new_problem(area, title)
      return finish(problem, context.out) if problem

      context.out.puts(write_new(context, area, title))
      0
    end

    def new_problem(area, title)
      return "Use one of these areas: #{AREAS.join(', ')}" unless AREAS.include?(area)

      'Give the challenge a title' if slug(title).empty?
    end

    def slug(title) = title.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')

    # A new challenge from the template, numbered after the last one.
    def write_new(context, area, title)
      dir = context.dir
      id = ChallengeDocs.docs(dir).filter_map { |doc| doc.front && doc.front['id'] }.max.to_i + 1
      path = File.join(dir, "#{format('%04d', id)}-#{slug(title)}.md")
      File.write(path, template(id, area, title, context.today))
      Index.write(dir)
      path
    end

    def template(id, area, title, today)
      sections = ['The challenge', 'The case that breaks it', 'Where we stand', 'Options']
      <<~DOC
        ---
        id: #{id}
        title: #{title}
        area: #{area}
        status: open
        opened: #{today}
        reviewed: #{today}
        watches: []
        ---

        # #{title}

        #{sections.map { |name| "## #{name}\n\nNot written yet.\n\n" }.join}## History

        - #{today}: Opened.
      DOC
    end

    def finish(problem, out)
      out.puts(problem || 'ok')
      problem ? 1 : 0
    end

    def usage(out)
      out.puts(USAGE)
      2
    end
  end
end
