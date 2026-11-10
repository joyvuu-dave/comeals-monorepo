# frozen_string_literal: true

require 'rails_helper'

# config/mutant/accepted_survivors/ lists the mutations no example can
# kill, each with its reason, in one file for each class
# (docs/mutation-testing.md, "Accepted survivors"). bin/mutant and the
# Mutant workflow read it only after a run of hours, so a mistake in a
# file is checked here, in bin/check.
RSpec.describe 'config/mutant/accepted_survivors' do # -- a config folder
  let(:real) { Rails.root.join('config/mutant/accepted_survivors').to_s }
  let(:patterns) { Rails.root.join('.mutant.yml').read.scan(/^\s+- ([A-Z][A-Za-z0-9:]*)\*$/).flatten }
  let(:dir) { Dir.mktmpdir }
  let(:good) { { 'subject' => 'Foo#bar', 'kind' => 'same-answer', 'why' => 'A reason.', 'diff' => "@@ a\n" } }

  after { FileUtils.remove_entry(dir) }

  def file(name, content)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content.is_a?(String) ? content : content.to_yaml)
  end

  it 'has every key filled in, a known kind, each entry in its class file, and no entry twice' do
    expect(MutantSurvivors.list_problems(real)).to eq([])
  end

  it 'names only methods of classes that .mutant.yml mutates' do
    outside = MutantSurvivors.read_list(real).map(&:subject).reject do |subject|
      constant = subject[/\A[^#.]+/]
      patterns.any? { |pattern| constant.start_with?(pattern) }
    end

    expect(outside).to eq([])
  end

  describe 'MutantSurvivors.file_for' do
    it 'names a file for the class, a folder for each namespace, in snake case' do
      expect(%w[JwtAuth.encode Api::V1::MealsController#show MealCorrectionForm::Rows#x AdminUsers::X#y]
               .map { |subject| MutantSurvivors.file_for(subject) })
        .to eq(%w[jwt_auth.yml api/v1/meals_controller.yml meal_correction_form/rows.yml admin_users/x.yml])
    end
  end

  # The check itself, on folders with mistakes.
  describe 'MutantSurvivors.list_problems' do
    it 'finds nothing wrong with good entries, with or without only_on' do
      file('foo.yml', [good, good.merge('diff' => "@@ b\n", 'only_on' => 'linux')])

      expect(MutantSurvivors.list_problems(dir)).to eq([])
    end

    it 'names each mistake in an entry' do
      bad = { 'subject' => 'Foo#bar', 'kind' => 'fine', 'why' => ' ', 'diff' => 'a', 'only_on' => 'mac', 'note' => 'x' }
      file('foo.yml', [bad, 'text', good.except('why')])

      expect(MutantSurvivors.list_problems(dir)).to eq(
        ['foo.yml, entry 1 has unknown keys note',
         'foo.yml, entry 1 (Foo#bar): the kind must be one of same-answer, never-ends',
         'foo.yml, entry 1 (Foo#bar): why is empty',
         'foo.yml, entry 1 (Foo#bar): the diff does not start with @@',
         'foo.yml, entry 1 (Foo#bar): only_on must be one of linux',
         'foo.yml, entry 2 is not a mapping',
         'foo.yml, entry 3 has no why',
         'foo.yml, entry 3 (Foo#bar): why is empty']
      )
    end

    it 'names an entry in the wrong file, and a file with no entries' do
      file('bar.yml', [good])
      file('api/empty.yml', "[]\n")
      file('api/blank.yml', '')

      expect(MutantSurvivors.list_problems(dir)).to eq(
        ['api/blank.yml is not a list with at least one entry',
         'api/empty.yml is not a list with at least one entry',
         'bar.yml, entry 1 belongs in foo.yml']
      )
    end

    it 'names an entry that repeats another, even when only the spaces at its line ends differ' do
      file('foo.yml', [good, good.merge('diff' => "@@ a  \n\n")])

      expect(MutantSurvivors.list_problems(dir)).to eq(['foo.yml, entry 2 repeats foo.yml, entry 1'])
    end
  end
end
