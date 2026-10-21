# typed: strict
# frozen_string_literal: true

# The push_token a request from the meal page's sign-up list sends: a
# sign-up, a take-off, a Late or Veg change, a guest add or a guest
# removal (#237). LiveUpdate puts it in the meal page's push and sends
# that push to the sender too, so a page whose request was written after
# it gave up on it is told (LiveUpdate.meal).
#
# The page sends a new UUID with each request. Taken: 1 to 64 letters,
# digits and hyphens, because it goes into a Pusher message that every
# screen on the meal reads. Anything else is read as no token, and the
# request is pushed the way a request with no token is: to every screen
# but the sender's socket. It is not refused: the token decides only who
# is told to load the meal again, never what is written.
module PushToken
  extend T::Sig

  FORM = T.let(/\A[0-9A-Za-z-]{1,64}\z/, Regexp)
  private_constant :FORM

  sig { params(raw: T.untyped).returns(T.nilable(String)) }
  def self.read(raw)
    raw if raw.is_a?(String) && raw.match?(FORM)
  end
end
