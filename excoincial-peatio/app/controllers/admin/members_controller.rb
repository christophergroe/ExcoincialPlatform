# encoding: UTF-8
# frozen_string_literal: true

module Admin
  class MembersController < BaseController
    load_and_authorize_resource

    def index
      @search_field = params[:search_field]
      @search_term  = params[:search_term]
      @members      = Member.search(field: @search_field, term: @search_term).page(params[:page])
    end

    def show

    end

    def toggle
      # @member.toggle!(params[:api] ? :api_disabled : :disabled)
      if params[:web]
        begin
          RestClient.post( "#{ENV.fetch('BARONG_DOMAIN')}/users/api/v1/accounts/disable_account",{:disable => @member.disabled,:web => params[:web],:access_token => @member.auth('barong').token} )
        rescue
        end
      end
      @member.toggle!(:api_disabled) if params[:api]
      @member.toggle!(:disabled) if params[:web]
      @member.toggle!(:zero_fee) if params[:zero]
    end
  end
end
