require "test_helper"

class ChatStatusTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  test "starts offline so the site never claims someone is there by default" do
    assert_not ChatStatus.online?
  end

  test "setting the status flips it and clears the cache" do
    ChatStatus.set!(true)
    assert ChatStatus.online?

    ChatStatus.set!(false)
    assert_not ChatStatus.online?
  end

  test "only ever keeps one row" do
    3.times { ChatStatus.set!(true) }

    assert_equal 1, ChatStatus.count
  end

  # The operator types these one-handed on a phone, so a few spellings are accepted -
  # a status that silently fails to change is worse than one that is forgiving.
  test "recognises status words in both languages" do
    assert_equal true, ChatStatus.parse_command("online")
    assert_equal true, ChatStatus.parse_command("  ONLINE  ")
    assert_equal true, ChatStatus.parse_command("disponible")
    assert_equal false, ChatStatus.parse_command("offline")
    assert_equal false, ChatStatus.parse_command("Desconectado")
  end

  # A reply that happens to contain the word must not be mistaken for a command,
  # or it would be swallowed instead of reaching the visitor.
  test "a sentence containing a status word is not a command" do
    assert_nil ChatStatus.parse_command("Estoy online ahora, ¿en qué te ayudo?")
    assert_nil ChatStatus.parse_command("Sí, tenemos ese medicamento")
  end
end
