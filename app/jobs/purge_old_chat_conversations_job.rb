# Deletes conversations past ChatConversation::RETENTION.
#
# The privacy notice tells visitors their messages are removed after that window,
# so this is the thing that makes the promise true. Scheduled in
# config/recurring.yml.
class PurgeOldChatConversationsJob < ApplicationJob
  queue_as :default

  def perform
    purged = ChatConversation.purge_old!
    Rails.logger.info("[PurgeOldChatConversationsJob] removed #{purged.size} conversations") if purged.any?
  end
end
