# frozen_string_literal: true

require 'rails_helper'
require 'prism'

# The first lesson of https://pawelurbanek.com/rails-thread-safety: state
# that lives on a class or on a thread is shared between requests, and a
# blocking call in one request is when another request overwrites it. A
# class variable (@@count), an instance variable on a class (@cache in a
# `def self.` method), and Thread.current are the three ways to write
# such state in Ruby. This reads every file in app/, lib/ and
# config/initializers with Prism and refuses all three, except for the
# one class-level memo the app has and has thought about.
#
# The exception: JwtAuth.secret memoizes the derived signing key. Two
# threads that race it both derive the same bytes and one of them wins;
# nothing can go wrong. A new entry here needs the same argument.
#
# Current (ActiveSupport::CurrentAttributes) is thread-local state too,
# but Rails resets it at the edges of every request and job —
# spec/concurrency/recycled_thread_spec.rb proves that — so it is the
# one allowed way to keep per-request state, and this does not flag it.
# Walks one file's tree and collects what it finds. `singleton` is true
# inside `class << self` or `def self.x` — where an instance variable is
# the class's, shared by every thread.
class ProcessWideStateFinder < Prism::Visitor
  attr_reader :class_variables, :thread_current, :class_level_writes

  def initialize(file)
    super()
    @file = file
    @singleton = false
    @class_variables = []
    @thread_current = []
    @class_level_writes = []
  end

  def visit_class_variable_write_node(node) = note(@class_variables, node, node.name) && super
  def visit_class_variable_operator_write_node(node) = note(@class_variables, node, node.name) && super
  def visit_class_variable_or_write_node(node) = note(@class_variables, node, node.name) && super
  def visit_class_variable_read_node(node) = note(@class_variables, node, node.name) && super

  def visit_call_node(node)
    if node.name == :current && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Thread
      note(@thread_current, node, 'Thread.current')
    end
    super
  end

  def visit_singleton_class_node(node) = within_singleton(true) { super }

  def visit_def_node(node)
    within_singleton(@singleton || !node.receiver.nil?) { super }
  end

  def visit_instance_variable_write_node(node) = note_class_level(node) && super
  def visit_instance_variable_or_write_node(node) = note_class_level(node) && super
  def visit_instance_variable_operator_write_node(node) = note_class_level(node) && super

  private

  def note_class_level(node)
    note(@class_level_writes, node, node.name) if @singleton
    true
  end

  def note(list, node, what)
    list << "#{@file}:#{node.location.start_line}: #{what}"
  end

  def within_singleton(value)
    was = @singleton
    @singleton = value
    yield
  ensure
    @singleton = was
  end
end

RSpec.describe 'process-wide mutable state in the app' do
  let(:allowed_class_level_memos) { ['app/services/jwt_auth.rb: @secret'] }
  let(:files) do
    Rails.root.glob('{app,lib,config/initializers}/**/*.rb').map { |f| f.relative_path_from(Rails.root).to_s }.sort
  end

  def scan
    files.each_with_object(ProcessWideStateFinder.new('')) do |file, all|
      finder = ProcessWideStateFinder.new(file)
      Prism.parse_file(Rails.root.join(file).to_s).value.accept(finder)
      all.class_variables.concat(finder.class_variables)
      all.thread_current.concat(finder.thread_current)
      all.class_level_writes.concat(finder.class_level_writes)
    end
  end

  it 'reads every app file' do
    expect(files).to include('app/services/jwt_auth.rb', 'app/services/live_update.rb', 'config/initializers/pusher.rb')
  end

  it 'has no class variables' do
    expect(scan.class_variables).to be_empty
  end

  it 'never touches Thread.current directly (Current is the one allowed thread-local)' do
    expect(scan.thread_current).to be_empty
  end

  it 'writes no instance variable on a class, except the one memo it has argued for' do
    writes = scan.class_level_writes.map { |line| line.sub(/:\d+: /, ': ') }
    expect(writes).to match_array(allowed_class_level_memos)
  end
end
