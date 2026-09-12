require "test_helper"

class TelegramWebhooksControllerTest < ActionDispatch::IntegrationTest
  SECRET = "test-webhook-secret".freeze

  setup do
    @original_secret = ENV["TELEGRAM_WEBHOOK_SECRET"]
    ENV["TELEGRAM_WEBHOOK_SECRET"] = SECRET
    # No API key means Chat::Translator short-circuits to nil instead of calling
    # Anthropic, so these tests never touch the network - and they exercise the
    # fallback path, where the operator's own text is posted untranslated.
    @original_api_key = ENV.delete("ANTHROPIC_API_KEY")
    @original_bot_token = ENV.delete("TELEGRAM_BOT_TOKEN")

    @conversation = ChatConversation.create!
    @conversation.messages.create!(author: "visitor", body: "¿Tienen ibuprofeno?")
  end

  teardown do
    @original_secret ? ENV["TELEGRAM_WEBHOOK_SECRET"] = @original_secret : ENV.delete("TELEGRAM_WEBHOOK_SECRET")
    ENV["ANTHROPIC_API_KEY"] = @original_api_key if @original_api_key
    ENV["TELEGRAM_BOT_TOKEN"] = @original_bot_token if @original_bot_token
  end

  def post_webhook(text:, reply_to: nil, secret: SECRET)
    message = { text: text }
    message[:reply_to_message] = { text: reply_to } if reply_to

    post telegram_webhook_path,
         params: { message: message },
         headers: { "X-Telegram-Bot-Api-Secret-Token" => secret },
         as: :json
  end

  # This endpoint can post messages that visitors will read as coming from the
  # operator, so an unauthenticated version of it would let anyone impersonate them.
  test "a request without the secret token is rejected" do
    post_webhook(text: "Hello", secret: "wrong-secret")

    assert_response :unauthorized
    assert_equal 1, @conversation.messages.count
  end

  test "the endpoint is invisible when no secret is configured" do
    ENV.delete("TELEGRAM_WEBHOOK_SECRET")

    post_webhook(text: "Hello", secret: "anything")

    assert_response :not_found
  end

  test "a reply is matched to its conversation by the admin link in the notification" do
    post_webhook(text: "Yes, we have it for $45",
                 reply_to: "💬 Nuevo mensaje\n\nResponder: https://farmavea.com/admin/chats/#{@conversation.id}")

    assert_response :success
    assert_equal 2, @conversation.messages.count
    assert_equal "operator", @conversation.messages.last.author
  end

  test "a blank message is ignored rather than posted" do
    post_webhook(text: "   ")

    assert_response :success
    assert_equal 1, @conversation.messages.count
  end

  test "a non-message update is ignored" do
    post telegram_webhook_path,
         params: { edited_message: { text: "something" } },
         headers: { "X-Telegram-Bot-Api-Secret-Token" => SECRET },
         as: :json

    assert_response :success
    assert_equal 1, @conversation.messages.count
  end

  # Without an API key the translator returns nil, so the operator's own words are
  # posted. A reply in the wrong language beats no reply.
  test "an untranslatable reply is still delivered in the operator's own words" do
    post_webhook(text: "Yes, $45 at Benavides",
                 reply_to: "Responder: https://farmavea.com/admin/chats/#{@conversation.id}")

    assert_equal "Yes, $45 at Benavides", @conversation.messages.last.body
  end

  # A reply with no reply-to falls back to the newest conversation, which is almost
  # always the one being answered.
  test "a reply without a reply-to goes to the most recent conversation" do
    newer = ChatConversation.create!
    newer.messages.create!(author: "visitor", body: "¿Y paracetamol?")

    post_webhook(text: "We have it")

    assert_equal "operator", newer.reload.messages.last.author
    assert_equal 1, @conversation.reload.messages.count
  end
end
