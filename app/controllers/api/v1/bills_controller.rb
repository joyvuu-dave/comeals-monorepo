# frozen_string_literal: true

module Api
  module V1
    class BillsController < ApiController
      before_action :authenticate

      # GET /bills?start=12345&end=12345
      def index
        bills = if params[:start].present? && params[:end].present?
                  Bill.includes(:meal, { resident: :unit })
                      .joins(:meal)
                      .where(meals: { date: (params[:start]).. })
                      .where(meals: { date: ..(params[:end]) })
                else
                  Bill.includes(:meal, { resident: :unit })
                      .joins(:meal)
                      .all
                end

        render json: bills
      end

      def show
        bill = Bill.find_by(id: params[:id])
        return not_found_api if bill.blank?

        render json: bill
      end

      private

      def authenticate
        not_authenticated_api unless signed_in_resident_api?
      end
    end
  end
end
