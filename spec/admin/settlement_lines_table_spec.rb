# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SettlementLinesTable' do
  before { ActiveAdmin.application.load! }

  it 'refuses a first column it does not know, even with nothing to render' do
    component = SettlementLinesTable.new(Arbre::Context.new)

    expect { component.build([], first_column: :cook) }
      .to raise_error(ArgumentError, 'first_column must be :resident or :meal, got :cook')
  end
end
