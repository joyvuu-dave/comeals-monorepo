# typed: false
# frozen_string_literal: true

ActiveAdmin.register CommonHouseReservation do
  menu label: 'Common House'

  # STRONG PARAMS
  permit_params :resident_id, :start_date, :end_date, :title

  # CONFIG
  config.filters = false

  # FORM
  form do |f|
    f.inputs do
      f.input :resident_id, as: :select, include_blank: false, label: 'Host', collection: Resident.includes(:unit).adult.order('units.name ASC').map { |r|
        ["#{r.name} - #{r.unit.name}", r.id]
      }
      f.input :title, input_html: { placeholder: 'optional' }
      f.input :start_date
      f.input :end_date
    end
    f.actions
    f.semantic_errors
  end
end
