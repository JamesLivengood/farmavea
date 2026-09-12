# Notifies the operator out of band so a slow or failing Telegram call never delays
# the visitor's request.
class NotifyOperatorOfChatMessageJob < ApplicationJob
  queue_as :default

  # No retries: a notification that is minutes late is worthless, and the message is
  # already saved and visible in the admin inbox regardless.
  discard_on StandardError

  def perform(chat_message_id)
    message = ChatMessage.find_by(id: chat_message_id)
    return if message.nil? || message.operator?

    Chat::TelegramNotifier.notify_new_message(message)
  end
end
