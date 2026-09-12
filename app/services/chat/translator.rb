module Chat
  # Translates a chat message so the operator sees both languages in one Telegram
  # notification.
  #
  # Uses Claude Haiku: a chat message is ~40 input and ~40 output tokens, so roughly
  # $0.0003 each - about $0.30 per 10,000 messages. Chosen over a generic translation
  # API because the vocabulary here is medical ("me arde el estómago", dosages,
  # presentations), and a mistranslated symptom or dose is the kind of error that
  # matters on this site.
  #
  # Never raises: a translation is a convenience on top of a notification, and
  # neither is worth losing a visitor's message over.
  class Translator
    MODEL = "claude-haiku-4-5-20251001".freeze
    MAX_TOKENS = 1000
    TIMEOUT = 10

    # Below this there is nothing worth a round trip ("ok", "gracias").
    MIN_LENGTH = 4

    class << self
      def configured?
        ENV["ANTHROPIC_API_KEY"].present?
      end

      # Returns the translated text, or nil when translation is unavailable,
      # unnecessary, or failed. Callers must handle nil by showing the original.
      def to_english(text)
        translate(text, target: "English", source_hint: "Spanish")
      end

      def to_spanish(text)
        translate(text, target: "Spanish", source_hint: "English")
      end

      private

      def translate(text, target:, source_hint:)
        return nil unless configured?

        body = text.to_s.strip
        return nil if body.length < MIN_LENGTH

        response = client.messages.create(
          model: MODEL,
          max_tokens: MAX_TOKENS,
          system: system_prompt(target: target, source_hint: source_hint),
          messages: [ { role: "user", content: body } ]
        )

        translated = response.content.filter_map { |part| part.text if part.respond_to?(:text) }.join.strip
        return nil if translated.blank?
        # The model was told to emit this when the text is already in the target
        # language, so the operator is not shown a pointless duplicate.
        return nil if translated == ALREADY_IN_TARGET

        translated
      rescue StandardError => e
        Rails.logger.warn("[Chat::Translator] #{e.class}: #{e.message.to_s[0, 200]}")
        nil
      end

      ALREADY_IN_TARGET = "SAME".freeze

      def system_prompt(target:, source_hint:)
        <<~PROMPT
          You translate messages from a Mexican medication price-comparison website's
          customer chat into #{target}. Messages are usually #{source_hint} and often
          concern medicines, symptoms, dosages and pharmacy stock.

          Rules:
          - Output ONLY the translation. No preamble, quotes, or notes.
          - Translate medical terms accurately and plainly, the way a pharmacist
            would say them - do not soften, embellish, or add advice.
          - Keep drug names, brand names, dosages and numbers exactly as written.
          - Preserve the tone, including informality or urgency.
          - If the message is ALREADY in #{target}, output exactly: #{ALREADY_IN_TARGET}
        PROMPT
      end

      def client
        @client ||= Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
      end
    end
  end
end
