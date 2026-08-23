# frozen_string_literal: true

module Api
  module V1
    class BillsController < ApiController
      before_action :authenticate

      def show
        bill = Bill.find_by(id: params[:id])
        return not_found_api if bill.blank?

        render json: BillSerializer.new(bill)
      end
    end
  end
end
