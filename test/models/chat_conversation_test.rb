require "test_helper"

class ChatConversationTest < ActiveSupport::TestCase
  test "a token is generated automatically and is not guessable" do
    conversation = ChatConversation.create!

    assert conversation.token.present?
    assert_operator conversation.token.length, :>=, 20
  end

  test "a blank email is allowed but a malformed one is not" do
    assert ChatConversation.new.valid?
    assert ChatConversation.new(visitor_email: "alguien@example.com").valid?
    assert_not ChatConversation.new(visitor_email: "no-es-un-correo").valid?
  end

  # The privacy notice tells visitors their messages are deleted after the
  # retention window; this is the code that has to make that true.
  test "conversations past the retention window are purged" do
    old = ChatConversation.create!
    old.messages.create!(author: "visitor", body: "Mensaje viejo")
    old.update_column(:last_message_at, (ChatConversation::RETENTION + 1.day).ago)

    recent = ChatConversation.create!
    recent.messages.create!(author: "visitor", body: "Mensaje reciente")

    ChatConversation.purge_old!

    assert_not ChatConversation.exists?(old.id)
    assert ChatConversation.exists?(recent.id)
  end

  test "purging a conversation removes its messages too" do
    conversation = ChatConversation.create!
    conversation.messages.create!(author: "visitor", body: "Algo sobre mi salud")
    conversation.update_column(:last_message_at, (ChatConversation::RETENTION + 1.day).ago)

    ChatConversation.purge_old!

    assert_equal 0, ChatMessage.count, "message text must not outlive its conversation"
  end

  test "a conversation that never got a message is purged on age alone" do
    stale = ChatConversation.create!
    stale.update_column(:created_at, (ChatConversation::RETENTION + 1.day).ago)

    ChatConversation.purge_old!

    assert_not ChatConversation.exists?(stale.id)
  end

  test "unread_count counts only visitor messages" do
    conversation = ChatConversation.create!
    conversation.messages.create!(author: "visitor", body: "Hola")
    conversation.messages.create!(author: "operator", body: "Hola, ¿en qué te ayudo?")

    assert_equal 1, conversation.unread_count
  end
end
