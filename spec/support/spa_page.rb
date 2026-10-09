# frozen_string_literal: true

# FallbackController sends public/index.html, and only a front-end build
# writes that file. A run with no build (a new worktree) has none. Until
# #142 one spec wrote a stand-in page and the rest relied on it, so a spec
# that ran before that one failed with ActionController::MissingFile. Now
# every request example gets the stand-in when the file is missing,
# whatever order the specs run in.
#
# The stand-in stays after the run. A later build overwrites it. Deleting
# it would break any other process that runs specs in this checkout at the
# same time and already found the file there (mutant runs several).
#
# Two such processes can both find the file missing. So the page is
# written whole to a file of its own first and then linked in under the
# real name. The link fails if a file has that name by then, so no request
# reads a half-written page, and a real build is never replaced.
module SpaPage
  PATH = Rails.public_path.join('index.html')
  STAND_IN = '<!doctype html><title>Comeals</title><div id="root"></div>'

  def self.write_unless_present
    return if PATH.exist?

    # The draft must be on the same disk as public/ for the link to work,
    # so it goes in the app's tmp/, not the system's.
    drafts = Rails.root.join('tmp')
    drafts.mkpath
    Tempfile.create(%w[spa-page .html], drafts) do |draft|
      draft.write(STAND_IN)
      # Tempfile makes the file 0600. A build writes 0644, and a later
      # build writes into this file and keeps its mode.
      draft.chmod(0o644)
      draft.close
      File.link(draft.path, PATH)
    rescue Errno::EEXIST
      nil # Another process linked its own page in first. That page is whole too.
    end
  end
end

RSpec.configure do |config|
  config.before(type: :request) { SpaPage.write_unless_present }
end
