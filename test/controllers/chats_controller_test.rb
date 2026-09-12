require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  # These tests are about sending, rate limiting and reading messages back. The
  # offline contact requirement is covered explicitly further down, so default to
  # online here rather than having every unrelated test carry an email.
  setup { ChatStatus.set!(true) }

  test "a first message creates a conversation and returns its token" do
    post chat_path, params: { body: "¿Tienen paracetamol más barato?" }, as: :json

    assert_response :created
    body = JSON.parse(@response.body)
    assert body["token"].present?
    assert_equal "¿Tienen paracetamol más barato?", body["message"]["body"]
    assert_equal "visitor", body["message"]["author"]
  end

  test "a follow-up message joins the existing conversation" do
    post chat_path, params: { body: "Primera" }, as: :json
    token = JSON.parse(@response.body)["token"]

    post chat_path, params: { token: token, body: "Segunda" }, as: :json

    assert_response :created
    assert_equal 1, ChatConversation.count
    assert_equal 2, ChatConversation.first.messages.count
  end

  test "an empty message is rejected" do
    post chat_path, params: { body: "   " }, as: :json

    assert_response :unprocessable_entity
    assert_equal 0, ChatConversation.count
  end

  test "an over-long message is rejected rather than truncated" do
    post chat_path, params: { body: "a" * (ChatMessage::MAX_LENGTH + 1) }, as: :json

    assert_response :unprocessable_entity
    assert_equal 0, ChatMessage.count
  end

  # A public endpoint that writes rows and pushes a phone notification needs a
  # ceiling, or one person can fill the table and the operator's notifications.
  test "a conversation is rate limited after too many messages" do
    post chat_path, params: { body: "Primera" }, as: :json
    token = JSON.parse(@response.body)["token"]

    ChatsController::MAX_MESSAGES_PER_WINDOW.times do |i|
      post chat_path, params: { token: token, body: "Mensaje #{i}" }, as: :json
    end

    assert_response :too_many_requests
  end

  test "a phone number is stored and reaches the operator alongside the email" do
    post chat_path, params: { body: "¿Tienen omeprazol?", email: "a@example.com", phone: "+52 443 123 4567" },
         as: :json

    conversation = ChatConversation.last
    assert_equal "a@example.com", conversation.visitor_email
    assert_equal "+52 443 123 4567", conversation.visitor_phone
    # This string is what gets sent to Telegram.
    assert_equal "a@example.com · +52 443 123 4567", conversation.contact_line
  end

  test "a phone number alone is enough to be reachable" do
    post chat_path, params: { body: "¿Tienen omeprazol?", phone: "4431234567" }, as: :json

    assert_equal "4431234567", ChatConversation.last.visitor_phone
    assert_equal "4431234567", ChatConversation.last.contact_line
  end

  test "leaving no contact details is allowed while someone is online to answer" do
    ChatStatus.set!(true)

    post chat_path, params: { body: "¿Tienen omeprazol?" }, as: :json

    assert_response :created
    assert_equal "sin contacto", ChatConversation.last.contact_line
  end

  # Offline, a message with no way to reply is a dead end - the visitor would never
  # learn why they heard nothing back.
  test "offline, a message without contact details is refused" do
    ChatStatus.set!(false)

    post chat_path, params: { body: "¿Tienen omeprazol?" }, as: :json

    assert_response :unprocessable_entity
    assert JSON.parse(@response.body)["requires_contact"]
    assert_equal 0, ChatConversation.count, "nothing should be stored for a refused message"
  end

  test "offline, an email alone is enough" do
    ChatStatus.set!(false)

    post chat_path, params: { body: "¿Tienen omeprazol?", email: "a@example.com" }, as: :json

    assert_response :created
  end

  test "offline, a phone alone is enough" do
    ChatStatus.set!(false)

    post chat_path, params: { body: "¿Tienen omeprazol?", phone: "4431234567" }, as: :json

    assert_response :created
  end

  # Once details are on file, asking again on every message would be obstructive.
  test "offline, a follow-up needs no details when the conversation already has them" do
    ChatStatus.set!(false)
    post chat_path, params: { body: "Primera", email: "a@example.com" }, as: :json
    token = JSON.parse(@response.body)["token"]

    post chat_path, params: { token: token, body: "Segunda" }, as: :json

    assert_response :created
    assert_equal 2, ChatConversation.find_by(token: token).messages.count
  end

  test "a malformed email is rejected with a readable message" do
    ChatStatus.set!(true)

    post chat_path, params: { body: "¿Tienen omeprazol?", email: "no-es-un-correo" }, as: :json

    assert_response :unprocessable_entity
    assert JSON.parse(@response.body)["error"].present?
  end

  # A visitor deciding whether to type needs to know if anyone is there, before any
  # conversation exists.
  test "presence is reported even with no conversation" do
    ChatStatus.set!(true)

    get chat_path

    assert_equal true, JSON.parse(@response.body)["online"]
  end

  test "the email is stored only when the visitor supplies one" do
    post chat_path, params: { body: "Sin correo" }, as: :json
    assert_nil ChatConversation.last.visitor_email

    post chat_path, params: { body: "Con correo", email: "alguien@example.com" }, as: :json
    assert_equal "alguien@example.com", ChatConversation.last.visitor_email
  end

  test "showing a conversation returns its messages so a reply is visible on return" do
    post chat_path, params: { body: "¿Precio de ibuprofeno?" }, as: :json
    token = JSON.parse(@response.body)["token"]
    ChatConversation.find_by(token: token).messages.create!(author: "operator", body: "Cuesta $45.")

    get chat_path, params: { token: token }

    body = JSON.parse(@response.body)
    assert_equal 2, body["messages"].size
    assert_equal "operator", body["messages"].last["author"]
  end

  test "an unknown token returns no messages rather than an error" do
    get chat_path, params: { token: "not-a-real-token" }

    assert_response :success
    assert_empty JSON.parse(@response.body)["messages"]
  end

  # The token is the only thing guarding a conversation, so it must not be
  # guessable from anything the visitor is or does.
  test "conversation tokens are random and unique" do
    2.times { |i| post chat_path, params: { body: "Mensaje #{i}" }, as: :json }

    tokens = ChatConversation.pluck(:token)
    assert_equal tokens.size, tokens.uniq.size
    assert tokens.all? { |t| t.length >= 20 }
  end
end
