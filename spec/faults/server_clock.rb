# frozen_string_literal: true

# Loaded into the fault suite's server process only (challenge 30), with
# RUBYOPT=-r. Time.now is the real time plus the seconds in the file
# FAULTS_CLOCK_FILE names, which Faults::Clock writes while the server
# runs. So Time.current, Community#today, token times and the throttle
# windows all move with it. The file is read again only when it changes.
#
# Not under spec/support: rails_helper loads every file there into the
# test process, and this one belongs in the server alone.
#
# The offset is kept on the module, behind a Mutex: one per server process.
# rubocop:disable-next ThreadSafety/ClassInstanceVariable
module FaultsServerClock
  FILE = ENV.fetch('FAULTS_CLOCK_FILE')
  @lock = Mutex.new
  @seen = nil
  @offset = 0

  def self.offset
    changed = File.mtime(FILE) rescue nil # rubocop:disable Style/RescueModifier -- no file yet means no offset
    return @offset if changed == @seen

    @lock.synchronize do
      @seen = changed
      @offset = changed ? Rational(File.read(FILE)) : 0
    end
  end

  def now(...) = super + FaultsServerClock.offset
end

Time.singleton_class.prepend(FaultsServerClock)
