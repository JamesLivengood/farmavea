# Receives the operator's replies from Telegram, so a conversation can be answered
# from a phone without opening the admin page.
#
# Telegram posts here whenever the operator messages the bot. The reply is matched
# to a conversation by Telegram's own reply-to relationship: the operator swipes to
# reply on the notification, and this looks up which conversation that notification
# was about.
class TelegramWebhooksController < ApplicationController
  # Telegram is not a browser and carries no CSRF token.
  skip_forgery_protection

  # The URL contains a secret path segment, and Telegram also sends back the secret
  # token configured with setWebhook. Both are checked: this endpoint can post
  # messages to visitors, so an open version of it would let anyone impersonate the
  # operator.
  before_action :verify_telegram_secret

  def create
    message = params.dig(:message)
    return head(:ok) if message.blank?

    text = message[:text].to_s.strip
    return head(:ok) if text.blank?

    conversation = conversation_for(message)
    if conversation.nil?
      notify_unmatched(message)
      return head(:ok)
    end

    # The operator writes English; the visitor reads Spanish. Falls back to the
    # original if translation is unavailable - a reply in the wrong language is
    # better than no reply.
    body = Chat::Translator.to_spanish(text) || text
    conversation.messages.create!(author: "operator", body: body)

    Chat::TelegramNotifier.confirm_reply(conversation, original: text, sent: body)
    head :ok
  rescue StandardError => e
    # Telegram retries non-2xx responses, which would resend the same reply. Log and
    # accept instead.
    Rails.logger.error("[TelegramWebhooks] #{e.class}: #{e.message.to_s[0, 300]}")
    head :ok
  end

  private

  # Matched from the notification the operator replied to. Each notification carries
  # the conversation id, so swiping to reply on it is unambiguous even with several
  # conversations in flight.
  def conversation_for(message)
    replied_to = message.dig(:reply_to_message, :text).to_s
    id = replied_to[%r{/admin/chats/(\d+)}, 1]
    return ChatConversation.find_by(id: id) if id.present?

    # No reply-to: fall back to the most recent conversation, which is almost always
    # the one being answered.
    ChatConversation.recent.first
  end

  def notify_unmatched(message)
    Chat::TelegramNotifier.send_text(
      "No encontré a qué conversación responder. Responde (swipe) sobre la " \
      "notificación del mensaje para que sepa a quién contestar."
    )
  end

  def verify_telegram_secret
    expected = ENV["TELEGRAM_WEBHOOK_SECRET"].to_s
    return head(:not_found) if expected.blank?

    provided = request.headers["X-Telegram-Bot-Api-Secret-Token"].to_s
    head(:unauthorized) unless ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end
end
