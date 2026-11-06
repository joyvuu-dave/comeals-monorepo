# typed: true
# frozen_string_literal: true

# A resident's save of their own profile (ADR 0014): their name, their
# vegetarian setting and their email, and the name and vegetarian
# setting of each child in their unit who has no email
# (Resident#children_i_can_edit). One save, one transaction: either all
# of it is saved or none of it.
#
# The email is not changed here. A new address waits for its link
# (EmailChange), and the old one keeps working until then. Sending the
# old address again takes a waiting change off; sending the waiting
# address again leaves it waiting, with the link already sent.
#
# No password is asked for (decided 2026-11-05). Being signed in as the
# resident is enough.
class ProfileUpdate
  extend T::Sig

  ONLY_YOUR_CHILDREN = 'You can only change the children in your unit who have no email.'
  EMAIL_BLANK = 'Email cannot be blank.'

  # A child's part of a save.
  class Child < T::Struct
    const :id, Integer
    const :name, String
    const :vegetarian, T::Boolean
  end

  # What a save asks for, read from the request (read).
  class Fields < T::Struct
    const :name, String
    const :vegetarian, T::Boolean
    const :email, String
    const :children, T::Array[Child]
  end

  # A save that committed. profile is the answer, built inside the
  # transaction: a write action runs no query after its commit
  # (spec/requests/no_query_after_commit_spec.rb). email_token is set when
  # the save started a change of email, whose emails go out after the
  # commit (EmailChange.send_emails).
  class Saved < T::Struct
    const :resident, Resident
    const :profile, T::Hash[Symbol, T.untyped]
    const :email_token, T.nilable(String)
    const :old_email, T.nilable(String)
  end

  # The fields of a save, or the message of a 400. Every field is
  # required; children may be left out, and then no child changes. A child
  # sent is changed; a child left out is not.
  sig { params(params: ActionController::Parameters).returns(T.any(Fields, String)) }
  def self.read(params)
    problems = []
    problems << 'Name must be text.' unless params[:name].is_a?(String)
    problems << 'Email must be text.' unless params[:email].is_a?(String)
    vegetarian = TrueOrFalse.read(params[:vegetarian])
    problems << "#{TrueOrFalse.refusal(:vegetarian)}." if vegetarian.nil?

    children = read_children(params[:children])
    problems << children if children.is_a?(String)
    return problems.join("\n") if problems.any?

    Fields.new(name: params[:name], vegetarian: T.must(vegetarian), email: params[:email],
               children: T.cast(children, T::Array[Child]))
  end

  sig { params(raw: T.untyped).returns(T.any(T::Array[Child], String)) }
  def self.read_children(raw)
    return [] if raw.nil?
    return 'Children must be a list.' unless raw.is_a?(Array)

    children = raw.map do |child|
      unless child.is_a?(ActionController::Parameters)
        return 'Each child must have an id, a name and a vegetarian setting.'
      end

      id = whole_number(child[:id])
      vegetarian = TrueOrFalse.read(child[:vegetarian])
      name = child[:name]
      if id.nil? || vegetarian.nil? || !name.is_a?(String)
        return 'Each child must have an id, a name and a vegetarian setting.'
      end

      Child.new(id: id, name: name, vegetarian: vegetarian)
    end
    return 'Each child can be sent only once.' if children.map(&:id).uniq.size < children.size

    children
  end
  private_class_method :read_children

  # A JSON number, or the same as text. Anything else is no id.
  sig { params(raw: T.untyped).returns(T.nilable(Integer)) }
  def self.whole_number(raw)
    return raw if raw.is_a?(Integer)
    return raw.to_i if raw.is_a?(String) && raw.match?(/\A\d+\z/)

    nil
  end
  private_class_method :whole_number

  # The profile a resident sees: theirs, and the children they may edit.
  sig { params(resident: Resident).returns(T::Hash[Symbol, T.untyped]) }
  def self.profile(resident)
    # username is the short name the headers show, which the web app
    # keeps in a cookie from the sign-in (login.jsx). A save that changes
    # the name hands the page the new one.
    { id: resident.id, name: resident.name, username: ResidentNameShortener.short(resident.name),
      email: resident.email, pending_email: resident.pending_email, vegetarian: resident.vegetarian,
      children: resident.children_i_can_edit.map do |child|
        { id: child.id, name: child.name, vegetarian: child.vegetarian }
      end }
  end

  # Saves the fields for this resident. Returns Saved, or the message of
  # a 400. Run it inside RetryOnConflict: it reads the rows fresh in its
  # own transaction, and sends nothing until the caller sees it commit.
  sig { params(resident_id: Integer, fields: Fields).returns(T.any(Saved, String)) }
  def self.save(resident_id, fields)
    outcome = T.let(nil, T.nilable(T.any(Saved, String)))
    Resident.transaction do
      outcome = save_in_transaction(Resident.find(resident_id), fields)
      raise ActiveRecord::Rollback if outcome.is_a?(String)
    end
    T.must(outcome)
  end

  sig { params(resident: Resident, fields: Fields).returns(T.any(Saved, String)) }
  def self.save_in_transaction(resident, fields)
    editable = resident.children_i_can_edit.index_by(&:id)
    return ONLY_YOUR_CHILDREN unless fields.children.all? { |child| editable.key?(child.id) }

    old_email = resident.email
    email = change_email(resident, fields.email.strip.downcase)
    problem = email.problem
    return problem if problem

    resident.name = fields.name.strip
    resident.vegetarian = fields.vegetarian
    children = fields.children.map do |child|
      row = T.must(editable[child.id])
      row.name = child.name.strip
      row.vegetarian = child.vegetarian
      row
    end

    problems = save_all(resident, children)
    return problems if problems

    Saved.new(resident: resident, profile: profile(resident), email_token: email.token, old_email: old_email)
  end
  private_class_method :save_in_transaction

  # What the email part of a save did: started a change (token), refused
  # the address (problem), or neither.
  class EmailStep < T::Struct
    const :token, T.nilable(String), default: nil
    const :problem, T.nilable(String), default: nil
  end

  # Puts the email part of a save on the resident, unsaved.
  sig { params(resident: Resident, email: String).returns(EmailStep) }
  def self.change_email(resident, email)
    return EmailStep.new(problem: EMAIL_BLANK) if email.empty?

    if email == resident.email
      EmailChange.cancel(resident)
      return EmailStep.new
    end
    return EmailStep.new if email == resident.pending_email

    problem = email_problem(resident, email)
    return EmailStep.new(problem: problem) if problem

    EmailStep.new(token: EmailChange.start(resident, email))
  end
  private_class_method :change_email

  # Why the model would refuse this address as the resident's email, or
  # nil. The model's own checks run, so the rules live in one place: the
  # form of an address, its length, the .invalid addresses, and an address
  # another resident has. The email is put back before anything is saved.
  sig { params(resident: Resident, email: String).returns(T.nilable(String)) }
  def self.email_problem(resident, email)
    stored = resident.email
    resident.email = email
    resident.validate
    reasons = resident.errors.full_messages_for(:email)
    resident.email = stored
    resident.errors.clear
    reasons.empty? ? nil : reasons.join("\n")
  end
  private_class_method :email_problem

  # Saves the resident and then each child, or returns every reason one
  # of them was refused, one to a line. A child's reasons start with the
  # child's name as it was, so the person can tell whose they are.
  sig { params(resident: Resident, children: T::Array[Resident]).returns(T.nilable(String)) }
  def self.save_all(resident, children)
    reasons = resident.save ? [] : resident.errors.full_messages
    children.each do |child|
      next if child.save

      before = child.attribute_in_database(:name)
      reasons.concat(child.errors.full_messages.map { |reason| "#{before}: #{reason}" })
    end
    reasons.empty? ? nil : reasons.join("\n")
  end
  private_class_method :save_all
end
