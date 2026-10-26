# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Skills checked into this repo live in .agents/skills, where Codex and
# Gemini CLI read them. Claude Code reads only .claude/skills, so each
# skill needs a link there (AGENTS.md, "Skills in this repo"). Without the
# link, Claude Code does not see the skill and nothing says so. A link
# whose target is gone shows Claude Code a skill that is not there.
RSpec.describe 'Agent skill links' do
  # Every way the two folders under root disagree, one sentence each.
  def skill_link_problems(root)
    shared = File.join(root, '.agents/skills')
    claude = File.join(root, '.claude/skills')
    skills = Dir.children(shared).select { |name| File.directory?(File.join(shared, name)) }

    missing = skills.filter_map do |name|
      link = File.join(claude, name)
      target = "../../.agents/skills/#{name}"
      next if File.symlink?(link) && File.readlink(link) == target

      ".claude/skills/#{name} must be a link to #{target}"
    end

    broken = (File.directory?(claude) ? Dir.children(claude) : []).filter_map do |name|
      next if File.exist?(File.join(claude, name, 'SKILL.md'))

      ".claude/skills/#{name} points nowhere: it has no SKILL.md"
    end

    missing + broken
  end

  it 'has a link in .claude/skills for every skill in .agents/skills, and no other' do
    expect(skill_link_problems(Rails.root.to_s)).to eq([])
  end

  context 'with a copy of the two folders' do
    let(:root) { Dir.mktmpdir }
    let(:link) { File.join(root, '.claude/skills/hunt') }

    before do
      FileUtils.mkdir_p(File.join(root, '.agents/skills/hunt'))
      File.write(File.join(root, '.agents/skills/hunt/SKILL.md'), "---\nname: hunt\n---\n")
      FileUtils.mkdir_p(File.join(root, '.claude/skills'))
    end

    after { FileUtils.remove_entry(root) }

    it 'finds nothing wrong when the link is right' do
      File.symlink('../../.agents/skills/hunt', link)

      expect(skill_link_problems(root)).to eq([])
    end

    it 'names a skill that has no link' do
      expect(skill_link_problems(root)).to eq(
        ['.claude/skills/hunt must be a link to ../../.agents/skills/hunt']
      )
    end

    it 'names a link with an absolute target, which works on one laptop only' do
      File.symlink(File.join(root, '.agents/skills/hunt'), link)

      expect(skill_link_problems(root)).to eq(
        ['.claude/skills/hunt must be a link to ../../.agents/skills/hunt']
      )
    end

    it 'names a copy of the skill in place of a link' do
      FileUtils.cp_r(File.join(root, '.agents/skills/hunt'), link)

      expect(skill_link_problems(root)).to eq(
        ['.claude/skills/hunt must be a link to ../../.agents/skills/hunt']
      )
    end

    it 'names a link whose skill was removed' do
      File.symlink('../../.agents/skills/gone', File.join(root, '.claude/skills/gone'))
      File.symlink('../../.agents/skills/hunt', link)

      expect(skill_link_problems(root)).to eq(
        ['.claude/skills/gone points nowhere: it has no SKILL.md']
      )
    end
  end
end
