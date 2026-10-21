# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# .mutant.yml says its subjects are every class in app/ and lib/, and
# docs/mutation-testing.md says a stage is the matching block of that
# list. A class missing from the list is in no stage, so no run ever
# mutates it, and nothing says so. BillsPayload, LivePushJob and
# DeployConfigCheck were each added after the list was written
# (2026-09-12) and were missing from it until 2026-09-28.
RSpec.describe '.mutant.yml subjects' do # -- a config file
  # Classes with no `def` of their own: mutant changes methods, so it has
  # nothing to change in them. The last example checks the list, so a
  # class here that gains a method fails this spec instead of staying
  # out of every run.
  let(:only_attributes) do
    %w[Current EventFormSerializer CommonHouseReservationFormSerializer GuestRoomReservationFormSerializer
       UnsupportedBrowserSeen BrowserCheckBroke]
  end
  let(:subjects) do
    Rails.root.join('.mutant.yml').read.scan(/^\s+- ([A-Z][A-Za-z0-9:]*)\*$/).flatten
  end
  # Each file in app/ and lib/ with the class it opens. ActiveAdmin pages
  # (the files directly in app/admin) are DSL blocks, and rake tasks have
  # no class. The tables in app/admin/components are classes.
  let(:classes) do
    Rails.root.glob('{app,lib}/**/*.rb').filter_map do |file|
      path = file.relative_path_from(Rails.root).to_s
      next if path.match?(%r{\Aapp/admin/[^/]+\.rb\z}) || path.start_with?('lib/tasks/')

      [class_in(file.read), path]
    end.to_h
  end

  # The first class or module a file opens. A controller under Api::V1
  # opens the Api and V1 modules first, so its name is joined from those.
  def class_in(source)
    names = source.scan(/^\s*(?:class|module) ([A-Z][A-Za-z0-9:]*)/).flatten
    wrappers = %w[Api V1]
    namespace = names.take_while { |name| wrappers.include?(name) }
    (namespace + [names.find { |name| wrappers.exclude?(name) }]).compact.join('::')
  end

  it 'lists every class in app/ and lib/ that has a method' do
    missing = classes.keys.reject { |name| subjects.include?(name) } - only_attributes

    expect(missing).to be_empty
  end

  it 'leaves out only classes that have no method of their own' do
    with_methods = only_attributes.select { |name| Rails.root.join(classes.fetch(name)).read.match?(/^\s*def /) }

    expect(subjects & only_attributes).to be_empty
    expect(with_methods).to be_empty
  end

  # Mutant picks its subjects from the classes that are loaded once it
  # has set the environment variables, added the includes and required
  # the requires in .mutant.yml, and run its env_infection_post hook
  # (config/mutant/hooks.rb). It loads the spec files only after that. A
  # subject whose class is not loaded by then matches nothing, and the run
  # does not say so. Until 2026-10-10 two kinds of class were never
  # mutated this way: the tables in app/admin/components, which load only
  # when ActiveAdmin loads its pages, and DeployConfigCheck, which only
  # its rake task and its spec require.
  #
  # This does the same steps in the same order, in a separate test
  # process, and prints the subjects whose class is still not loaded.
  it 'names only classes that are loaded when mutant picks its subjects' do
    probe = <<~'RUBY'
      config = YAML.load_file('.mutant.yml')
      config.fetch('environment_variables').each { |name, value| ENV[name] = value }
      config.fetch('includes').each { |dir| $LOAD_PATH << dir }
      config.fetch('requires').each { |library| require library }
      require 'mutant'
      config.fetch('hooks').each do |path|
        Mutant::Hooks.load_pathname(Pathname(path)).run(:env_infection_post, env: nil)
      end
      loaded = ObjectSpace.each_object(Module).filter_map { |scope| Module.instance_method(:name).bind_call(scope) }
      subjects = File.read('.mutant.yml').scan(/^\s+- ([A-Z][A-Za-z0-9:]*)\*$/).flatten
      puts (subjects - loaded).inspect
    RUBY
    output, status = Open3.capture2e({ 'RAILS_ENV' => 'test', 'RUBYOPT' => nil },
                                     'bundle', 'exec', 'ruby', '-ryaml', '-e', probe, chdir: Rails.root.to_s)

    expect(status).to be_success, output
    expect(output.lines.last.chomp).to eq('[]')
  end
end
