# frozen_string_literal: true

# ActiveAdmin 3.5 renders the page body inside <div id="main_content_wrapper">
# with no landmark role, which fails the WCAG "main landmark" check. Override
# just the wrapper method to add role="main".
Rails.application.config.to_prepare do
  ActiveAdmin::Views::Pages::Base.class_eval do
    private

    def build_main_content_wrapper
      div id: 'main_content_wrapper', role: 'main' do
        div id: 'main_content' do
          main_content
        end
      end
    end
  end
end
