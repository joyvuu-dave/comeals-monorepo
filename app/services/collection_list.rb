# typed: strict
# frozen_string_literal: true

# What the common house collects and pays out after a settlement (ADR
# 0011 rule 9), for its email: each unit, with what it owes or is owed
# in total and what each person who lives there owes or is owed, then
# each person who had moved out and still has a balance.
#
# The amounts and the units are the settlement's own lines, saved on the
# day it was made (rule 7), so the list never changes later. A person who
# came out at $0.00 has no line. If they live here now, they are listed
# at $0.00 in the unit they live in now, so nobody thinks they were
# skipped. A unit with nobody to list is left out.
#
# A settlement made before units were saved has no moved-out list, and
# counts everyone in their saved unit, like its admin page
# (Reconciliation#records_who_moved_out?).
class CollectionList
  extend T::Sig

  # One person and what they owe or are owed in the settlement.
  class Person < T::Struct
    const :name, String
    const :amount, BigDecimal
  end

  # One unit: its total, which is the settlement page's unit balance, and
  # its people. The people's amounts add up to the total.
  class Unit < T::Struct
    const :name, String
    const :total, BigDecimal
    const :people, T::Array[Person]
  end

  sig { returns(T::Array[Unit]) }
  attr_reader :units

  sig { returns(T::Array[Person]) }
  attr_reader :moved_out

  sig { params(reconciliation: Reconciliation).void }
  def initialize(reconciliation)
    lines = reconciliation.reconciliation_balances.includes(:resident).to_a
    moved_out_known = reconciliation.records_who_moved_out?
    lived_here, gone = lines.partition { |line| line.lived_here || !moved_out_known }

    people = people_by_unit(lived_here, Resident.active.where.not(id: lines.map(&:resident_id)).to_a)
    @units = T.let(reconciliation.unit_balances.filter_map do |(unit_id, unit_name), total|
      in_unit = people.fetch(unit_id, [])
      Unit.new(name: unit_name, total: total, people: by_name(in_unit)) if in_unit.any?
    end, T::Array[Unit])
    @moved_out = T.let(by_name(gone.map { |line| person(line) }), T::Array[Person])
  end

  private

  # The people to list in each unit, by unit id: each line's person in the
  # line's saved unit, and each person at $0.00 in the unit they live in.
  sig do
    params(lines: T::Array[ReconciliationBalance], at_zero: T::Array[Resident])
      .returns(T::Hash[Integer, T::Array[Person]])
  end
  def people_by_unit(lines, at_zero)
    people = T.let(Hash.new { |hash, unit_id| hash[unit_id] = [] }, T::Hash[Integer, T::Array[Person]])
    lines.each { |line| T.must(people[T.must(line.unit_id)]) << person(line) }
    at_zero.each do |resident|
      T.must(people[T.must(resident.unit_id)]) << Person.new(name: T.must(resident.name), amount: BigDecimal('0'))
    end
    people
  end

  sig { params(line: ReconciliationBalance).returns(Person) }
  def person(line)
    Person.new(name: T.must(T.must(line.resident).name), amount: T.must(line.amount))
  end

  # Names in the order a person reads them, whatever their case. Two
  # residents' names never differ only in case (the unique index on
  # lower(residents.name)), so no two people tie.
  sig { params(list: T::Array[Person]).returns(T::Array[Person]) }
  def by_name(list)
    # downcase(:fold), not downcase: plain downcase leaves ß as one letter
    # that sorts after every other, so "Straße" came after "Strauss".
    # Folding reads it as "ss", the order the database and a person use.
    # T.unsafe: Sorbet's String#downcase takes no argument, though Ruby's
    # takes :fold, and a shim may not change a core method's arguments.
    list.sort_by { |person| T.unsafe(person.name).downcase(:fold) }
  end
end
