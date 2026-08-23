# frozen_string_literal: true

# Every row in these tables points at the one Community row. The app serves
# exactly one community (see CLAUDE.md: the communities table can never hold
# a second row), so nothing should ever have to pass community_id around.
# This concern fills it in. Forms, controllers, factories, and rake tasks can
# all leave it out.
#
# The foreign key column stays: it is NOT NULL with a foreign key constraint,
# and Community#calendar_cache_key and the Pusher channel names include the
# id. What goes away is the ceremony of setting it.
#
# AdminUser does not include this. The bootstrap admin is created before the
# community exists, so it needs Community.first (which can be nil), not
# Community.instance (which raises). See AdminUser.
module BelongsToTheCommunity
  extend ActiveSupport::Concern

  included do
    belongs_to :community

    # ||= so a caller that does set the community (a spec, a nested
    # attributes hash) keeps what it set.
    before_validation { self.community ||= Community.instance }
  end
end
