require "test_helper"

module Admin
  class ChatsControllerTest < ActionDispatch::IntegrationTest
    # This page shows what visitors asked about their own medication - sensitive
    # personal data under the LFPDPPP. With no password configured it must refuse to
    # serve rather than expose those questions to anyone who finds the URL.
    test "the inbox refuses to load when no admin password is configured" do
      original = ENV.delete("ADMIN_PASSWORD")

      get admin_chats_path

      assert_response :service_unavailable
      assert_match(/no está configurado/, @response.body)
    ensure
      ENV["ADMIN_PASSWORD"] = original if original
    end

    test "a conversation page also refuses without a password" do
      original = ENV.delete("ADMIN_PASSWORD")
      conversation = ChatConversation.create!
      conversation.messages.create!(author: "visitor", body: "¿Puedo tomar esto con mi presión?")

      get admin_chat_path(conversation)

      assert_response :service_unavailable
      assert_not_includes @response.body, "presión"
    ensure
      ENV["ADMIN_PASSWORD"] = original if original
    end
  end
end
