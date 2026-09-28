# frozen_string_literal: true

require 'rails_helper'

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
    %w[Current EventFormSerializer CommonHouseReservationFormSerializer GuestRoomReservationFormSerializer]
  end
  let(:subjects) do
    Rails.root.join('.mutant.yml').read.scan(/^\s+- ([A-Z][A-Za-z0-9:]*)\*$/).flatten
  end
  # Each file in app/ and lib/ with the class it opens. ActiveAdmin pages
  # are DSL blocks, and rake tasks have no class.
  let(:classes) do
    Rails.root.glob('{app,lib}/**/*.rb').filter_map do |file|
      path = file.relative_path_from(Rails.root).to_s
      next if path.start_with?('app/admin/', 'lib/tasks/')

      [class_in(file.read), path]
    end.to_h
  end

  # The first class or module a file opens. A controller under Api::V1
  # opens the Api and V1 modules first, so its name is joined from those.
  def class_in(source)
    names = source.scan(/^\s*(?:class|module) ([A-Z][A-Za-z0-9:]*)/).flatten
    namespace = names.take_while { |name| %w[Api V1].include?(name) }
    (namespace + [names.find { |name| %w[Api V1].exclude?(name) }]).compact.join('::')
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
end
