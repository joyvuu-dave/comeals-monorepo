# typed: true
# frozen_string_literal: true

# For an ActiveAdmin resource whose model can refuse a destroy
# (restrict_with_error, a before_destroy guard): show the model's own
# sentence, "Cannot delete record because dependent bills exist", instead
# of ActiveAdmin's generic "could not be destroyed". Included in the
# resource's `controller do` block. A resource that wants the refusal to
# go somewhere other than the list overrides refused_destroy_path.
# What the including controller provides (destroy!, resource, flash,
# redirect_to, collection_path) is declared in sorbet/rbi/shims/concerns.rbi.
module RefusedDestroyMessage
  extend T::Sig

  sig { void }
  def destroy
    destroy! do |_success, failure|
      failure.html do
        flash[:alert] = resource.errors.full_messages.to_sentence
        redirect_to refused_destroy_path
      end
    end
  end

  private

  sig { returns(String) }
  def refused_destroy_path
    collection_path
  end
end
