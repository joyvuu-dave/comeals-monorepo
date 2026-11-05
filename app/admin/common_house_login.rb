# typed: false
# frozen_string_literal: true

# The login of the shared screen in the Common House (CommonHouseLogin).
# There is at most one, so the page works like Community's: the list page
# only redirects, "New" goes away once the row exists (SuperuserAdapter),
# and nothing deletes it, because the history names it. Only a superuser
# may set or change the password (SuperuserAdapter GOVERNANCE_MODELS).
ActiveAdmin.register CommonHouseLogin do
  # MENU
  menu label: 'Common House login'

  # STRONG PARAMS
  permit_params :password, :password_confirmation

  # ACTIONS
  actions :all, except: %i[destroy]

  # CONFIG
  config.filters = false

  controller do
    # No list: send it to the one login, or to the new form when there is
    # none yet.
    def index
      # Hand-written action: ActiveAdmin authorizes inside resource and
      # build_resource, neither of which runs here (the meal_resident.rb
      # trap, ADR 0004).
      authorize! :read, CommonHouseLogin

      if (login = CommonHouseLogin.first)
        redirect_to resource_path(login)
      else
        redirect_to new_resource_path
      end
    end

    # Two admins can press Create at the same moment. Both pass the
    # model's check, because neither row is saved yet, and the unique
    # index refuses the second insert. That admin gets the model's
    # sentence on the form, not an error page.
    def create
      super
    rescue ActiveRecord::RecordNotUnique
      resource.errors.add(:base, CommonHouseLogin::ALREADY_EXISTS)
      render :new, status: :unprocessable_content
    end
  end

  show do
    attributes_table do
      row('Sign-in email') { CommonHouseLogin::EMAIL }
      row('Password last changed', &:keys_valid_since)
    end

    para 'A screen signed in before this time is signed out. To sign the Common House screen ' \
         'out from here, change the password.'
  end

  form do |f|
    f.semantic_errors :base
    f.inputs 'Common House login' do
      # The admin who sets the password also tells people the address
      # to type with it, so the form shows both.
      li "Sign in on the Common House screen with #{CommonHouseLogin::EMAIL} and this password."
      f.input :password, hint: "At least #{CommonHouseLogin::MINIMUM_PASSWORD_LENGTH} characters. " \
                               'Changing it signs the Common House screen out.'
      f.input :password_confirmation
    end
    f.actions
  end
end
