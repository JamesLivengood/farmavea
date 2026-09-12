require "test_helper"

module Chat
  class TranslatorTest < ActiveSupport::TestCase
    # A translation is a reading aid on top of a notification. Neither is worth
    # losing a visitor's message over, so every failure path must return nil rather
    # than raise - the caller then shows the original text.
    test "returns nil when no API key is configured" do
      original = ENV.delete("ANTHROPIC_API_KEY")

      assert_not Translator.configured?
      assert_nil Translator.to_english("¿Tienen paracetamol?")
    ensure
      ENV["ANTHROPIC_API_KEY"] = original if original
    end

    test "very short messages are not sent for translation" do
      original = ENV["ANTHROPIC_API_KEY"]
      ENV["ANTHROPIC_API_KEY"] = "test-key-not-used"

      # Under MIN_LENGTH: no round trip is worth making for "ok" or "si".
      assert_nil Translator.to_english("ok")
      assert_nil Translator.to_english("si")
    ensure
      original ? ENV["ANTHROPIC_API_KEY"] = original : ENV.delete("ANTHROPIC_API_KEY")
    end

    test "blank input is never sent for translation" do
      assert_nil Translator.to_english("")
      assert_nil Translator.to_english(nil)
      assert_nil Translator.to_english("   ")
    end
  end
end
