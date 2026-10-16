# typed: strict
# frozen_string_literal: true

# The admin form that corrects a settled dinner (ADR 0011 rule 6,
# app/views/admin/meals/correct.html.arb), read into MealCorrecting's
# edits.
#
# The form shows the dinner as it is now: each cook's cost, each eater,
# each guest, and a row to add a cook, eaters and a guest. It sends
# every row, changed or not. This reads what was sent, refuses what it
# cannot read with a sentence for the form, and keeps only the rows
# that change something, so the correction's record lists only what the
# admin changed. Nothing is written here: apply runs the edits, inside
# MealCorrecting's preview or save.
#
# The rows are read in one order (Rows.of), so a preview and the save
# that follows it make the same edits in the same order, and their
# fingerprints agree: by name, which is unique
# (index_residents_on_lower_name), and a host's guests in the order they
# were added.
#
# Because the form sends every row, a row the admin did not touch still
# sends what the page showed. If someone saved a correction after this
# page was opened, that row would write the old value back. So the page
# carries a code made from the rows it shows (Rows#seen, in the hidden
# field correction[seen]), and the form is refused when the dinner's
# rows now make another code: once when the form is read, and again
# under the meal's lock, just before the edits run.
class MealCorrectionForm
  extend T::Sig

  # Something the form sent cannot be read, or names a row the dinner no
  # longer has. Nothing was changed.
  class Invalid < StandardError; end

  # What an eater's row asks for: nothing, take them off, or charge them
  # the price for their age on the dinner's date.
  EATER_CHOICES = T.let(%w[keep remove reprice].freeze, T::Array[String])

  # A row the form sent is no longer on the dinner: another correction
  # took it off after the form was opened.
  CHANGED = T.let('This dinner changed after the form was opened. Open the form again.', String)

  # The dinner's rows are not the ones the page showed when it was
  # opened, or the page sent no code for them.
  STALE = T.let('Someone changed this dinner after you opened the form. Nothing was saved. ' \
                'Reload the page and enter your correction again.', String)

  # The dinner's rows the form shows, read from the database, in the
  # order the form shows them. The page and this reader both use them.
  class Rows < T::Struct
    extend T::Sig

    const :bills, T::Array[Bill]
    const :eaters, T::Array[MealResident]
    const :guests, T::Array[Guest]

    # Read from the database, not from the meal's loaded associations: a
    # preview adds rows and rolls them back, and a loaded association can
    # still hold what it added.
    sig { params(meal: Meal).returns(Rows) }
    def self.of(meal)
      new(
        bills: Bill.where(meal_id: meal.id).includes(:resident).sort_by { |bill| name_of(bill.resident) },
        eaters: MealResident.where(meal_id: meal.id).includes(resident: :community)
                            .sort_by { |row| name_of(row.resident) },
        guests: Guest.where(meal_id: meal.id).includes(:resident)
                     .sort_by { |guest| [name_of(guest.resident), guest.id] }
      )
    end

    # A row's resident, who is always there (a NOT NULL foreign key).
    sig { params(resident: T.nilable(Resident)).returns(String) }
    def self.name_of(resident)
      T.must(resident).name.to_s
    end

    # A code made from what the form shows of each row: each cook and
    # their cost, each eater and their price, and each guest, its host
    # and its price. The price for an eater's age is left out: it comes
    # from the resident, not from the dinner, and the preview shows the
    # price a change to it would set.
    sig { returns(String) }
    def seen
      Digest::SHA256.hexdigest(
        [bills.map { |bill| [bill.resident_id, T.must(bill.amount).to_s('F'), bill.no_cost] },
         eaters.map { |row| [row.resident_id, row.multiplier] },
         guests.map { |guest| [guest.id, guest.resident_id, guest.multiplier] }].to_json
      )
    end
  end

  Values = T.type_alias { T::Hash[String, T.untyped] }
  Step = T.type_alias { T.proc.params(edits: MealCorrecting::Edits).void }

  # What the admin wrote as the reason. MealCorrecting.save! refuses a
  # blank one; a preview does not need it.
  sig { returns(String) }
  attr_reader :reason

  sig { params(meal: Meal, values: Values).void }
  def initialize(meal, values)
    @meal = meal
    @values = values
    @reason = T.let(values['reason'].to_s.strip, String)
    @seen = T.let(values['seen'].to_s, String)
    @steps = T.let([], T::Array[Step])
    rows = Rows.of(meal)
    refuse_unless_seen(rows)
    @bills = T.let(rows.bills, T::Array[Bill])
    @eaters = T.let(rows.eaters, T::Array[MealResident])
    @guests = T.let(rows.guests, T::Array[Guest])
    read_cooks
    read_new_cook
    read_eaters
    read_new_eaters
    read_guests
    read_new_guest
  end

  # Make the edits the form asked for, in the order they were read. This
  # runs under the meal's lock (MealCorrecting), so the rows are checked
  # again here: a correction saved after the form was read and before the
  # lock was taken refuses this one.
  sig { params(edits: MealCorrecting::Edits).void }
  def apply(edits)
    refuse_unless_seen(Rows.of(@meal))
    @steps.each { |step| step.call(edits) }
  end

  private

  # A blank or missing code never matches, so a page opened before this
  # rule cannot skip it.
  sig { params(rows: Rows).void }
  def refuse_unless_seen(rows)
    raise Invalid, STALE unless rows.seen == @seen
  end

  # Each cook's row: Remove, or a cost (an amount or No cost). A row
  # whose cost is the one the cook has now changes nothing.
  sig { void }
  def read_cooks
    sent = section('cooks')
    refuse_unknown(sent, @bills.map(&:resident_id))
    @bills.each do |bill|
      row = sent[bill.resident_id.to_s]
      next unless row.is_a?(Hash)

      cook = T.must(bill.resident)
      if checked?(row['remove'])
        @steps << ->(edits) { edits.remove_cook(cook) }
        next
      end
      amount, no_cost = cost(row, cook)
      next if amount == bill.amount && no_cost == bill.no_cost

      @steps << ->(edits) { edits.cost(cook, amount: amount, no_cost: no_cost) }
    end
  end

  # The row that adds a cook: a resident who is not a cook on the dinner
  # yet, and their cost.
  sig { void }
  def read_new_cook
    row = section('new_cook')
    cook = resident(row['resident_id'])
    return if cook.nil?

    if @bills.any? { |bill| bill.resident_id == cook.id }
      raise Invalid, "#{cook.name} is already a cook on this dinner. Change their cost in their own row."
    end

    amount, no_cost = cost(row, cook)
    @steps << ->(edits) { edits.cost(cook, amount: amount, no_cost: no_cost) }
  end

  # Each eater's row: keep, remove, or the price for their age.
  sig { void }
  def read_eaters
    sent = section('eaters')
    refuse_unknown(sent, @eaters.map(&:resident_id))
    @eaters.each do |row|
      choice = sent.fetch(row.resident_id.to_s, 'keep').to_s
      raise Invalid, "The form sent \"#{choice}\" for an eater. #{CHANGED}" unless EATER_CHOICES.include?(choice)

      eater = T.must(row.resident)
      case choice
      when 'remove' then @steps << ->(edits) { edits.remove_eater(eater) }
      when 'reprice' then @steps << ->(edits) { edits.reprice_eater(eater) }
      end
    end
  end

  # The residents to sign up, at the price for their age on the dinner's
  # date.
  sig { void }
  def read_new_eaters
    eaters = residents(Array(@values['new_eater_ids']))
    already = eaters.select { |eater| @eaters.any? { |row| row.resident_id == eater.id } }
    raise Invalid, "#{already.map(&:name).to_sentence} already ate this dinner." if already.any?

    eaters.each { |eater| @steps << ->(edits) { edits.add_eater(eater) } }
  end

  # Each guest's row: keep it, or Remove.
  sig { void }
  def read_guests
    sent = section('guests')
    refuse_unknown(sent, @guests.map(&:id))
    @guests.each do |guest|
      row = sent[guest.id.to_s]
      @steps << ->(edits) { edits.remove_guest(guest) } if row.is_a?(Hash) && checked?(row['remove'])
    end
  end

  # The row that adds a guest: the host, and an adult or a child.
  sig { void }
  def read_new_guest
    row = section('new_guest')
    host = resident(row['host_id'])
    return if host.nil?

    multiplier = T.let(Integer(row['multiplier'].to_s, 10, exception: false), T.nilable(Integer))
    raise Invalid, 'A guest is an adult or a child.' unless Multiplier::GUEST_PRICES.include?(multiplier)

    @steps << ->(edits) { edits.add_guest(host, multiplier: multiplier) }
  end

  # A cost from a cook's row: an amount in whole cents, or No cost. A
  # cook on a settled dinner needs one or the other: a blank cost is the
  # one thing a settlement waits for (ADR 0011 rule 3).
  sig { params(row: Values, cook: Resident).returns([BigDecimal, T::Boolean]) }
  def cost(row, cook)
    text = row['amount'].to_s.strip
    unless text.empty? || BillsPayload::WHOLE_CENTS_AMOUNT.match?(text)
      raise Invalid, "#{cook.name}: \"#{text}\" is not a cost. A cost is whole cents, 0 to 9999.99, like 25.50."
    end

    amount = text.empty? ? BigDecimal('0') : BigDecimal(text)
    no_cost = checked?(row['no_cost'])
    raise Invalid, "#{cook.name}: #{Bill::NO_COST_MEANS_NO_AMOUNT}" if no_cost && amount.positive?
    raise Invalid, "#{cook.name}: enter a cost, or tick No cost." if !no_cost && amount.zero?

    [amount, no_cost]
  end

  # One part of the form, by name, as sent. A part that is missing or is
  # not a list of rows reads as empty.
  sig { params(name: String).returns(Values) }
  def section(name)
    value = @values[name]
    value.is_a?(Hash) ? value : {}
  end

  # A row the form sent that the dinner does not have now.
  sig { params(sent: Values, ids: T::Array[T.nilable(Integer)]).void }
  def refuse_unknown(sent, ids)
    raise Invalid, CHANGED if (sent.keys - ids.map(&:to_s)).any?
  end

  # The residents a menu with many choices named, by name, in one query.
  sig { params(raw: T::Array[T.untyped]).returns(T::Array[Resident]) }
  def residents(raw)
    texts = raw.map(&:to_s).reject(&:empty?).uniq
    ids = texts.map { |text| T.let(Integer(text, 10, exception: false), T.nilable(Integer)) }
    found = Resident.where(id: ids).sort_by { |resident| Rows.name_of(resident) }
    raise Invalid, "The form named a resident who does not exist. #{CHANGED}" if found.size != texts.size

    found
  end

  # The resident a menu named, or nil when it named none.
  sig { params(raw: T.untyped).returns(T.nilable(Resident)) }
  def resident(raw)
    text = raw.to_s
    return if text.empty?

    id = T.let(Integer(text, 10, exception: false), T.nilable(Integer))
    found = Resident.find_by(id: id)
    raise Invalid, "The form named a resident who does not exist. #{CHANGED}" if found.nil?

    found
  end

  sig { params(value: T.untyped).returns(T::Boolean) }
  def checked?(value)
    value.to_s == '1'
  end
end
