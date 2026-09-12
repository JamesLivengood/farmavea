require "net/http"

module Chat
  # Pushes a new visitor message to the operator's Telegram.
  #
  # Telegram rather than WhatsApp because WhatsApp's Cloud API requires Meta
  # business verification (days to weeks, and it wants registered-business
  # documents) plus a dedicated number that cannot also be on the regular WhatsApp
  # app. Telegram needs a token from @BotFather and nothing else. If WhatsApp is
  # ever set up, only this class changes - nothing else knows how notification
  # happens.
  #
  # Failures never propagate: a visitor's message must be saved and acknowledged
  # even when the notification channel is down. The operator can still see it in the
  # admin inbox.
  class TelegramNotifier
    API_HOST = "api.telegram.org".freeze
    TIMEOUT = 5

    class << self
      def configured?
        token.present? && chat_id.present?
      end

      def notify_new_message(message)
        return false unless configured?

        conversation = message.chat_conversation
        contact = conversation.visitor_email.presence || "sin correo"
        original = message.body.truncate(900)

        # Shown alongside the original rather than replacing it: the operator needs
        # the visitor's own words to reply in, and a translation is a reading aid,
        # not a substitute. nil when unavailable or already in English.
        english = Translator.to_english(original)

        text = +"💬 Nuevo mensaje en Farmavea\n\n"
        text << "🇲🇽 #{original}\n"
        text << "🇺🇸 #{english}\n" if english.present?
        text << "\nContacto: #{contact}\n"
        text << "Responder: #{admin_url(conversation)}"

        deliver(text)
      end

      private

      def token = ENV["TELEGRAM_BOT_TOKEN"].presence
      def chat_id = ENV["TELEGRAM_CHAT_ID"].presence

      def admin_url(conversation)
        base = ENV.fetch("APP_HOST", ApplicationHelper::CANONICAL_HOST)
        "#{base}/admin/chats/#{conversation.id}"
      end

      def deliver(text)
        uri = URI("https://#{API_HOST}/bot#{token}/sendMessage")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                   open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          http.request(Net::HTTP::Post.new(uri).tap do |req|
            req.set_form_data(chat_id: chat_id, text: text, disable_web_page_preview: "true")
          end)
        end

        return true if response.is_a?(Net::HTTPSuccess)

        Rails.logger.error("[Chat::TelegramNotifier] HTTP #{response.code}: #{response.body.to_s[0, 200]}")
        false
      rescue StandardError => e
        # Deliberately broad: a notification failure must never lose a visitor's
        # message or show them an error.
        Rails.logger.error("[Chat::TelegramNotifier] #{e.class}: #{e.message}")
        false
      end
    end
  end
end
