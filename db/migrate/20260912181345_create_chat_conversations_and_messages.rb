class CreateChatConversationsAndMessages < ActiveRecord::Migration[8.1]
  def change
    # A conversation is identified by a random token held in the visitor's browser,
    # NOT by anything derived from who they are. That is deliberate: the rest of this
    # app hashes visitor identity with a daily-rotating salt precisely so nobody can
    # be followed over time, and a chat table keyed to a person would undo it.
    #
    # What people type here is health-adjacent by nature ("can I take this with my
    # blood pressure pills?"), which is sensitive personal data under the LFPDPPP.
    # Hence: no IP address, no user agent, email optional and only when the visitor
    # types it in, and a retention window (see ChatConversation::RETENTION).
    create_table :chat_conversations do |t|
      t.string :token, null: false
      t.string :visitor_email
      t.string :status, null: false, default: "open"
      t.datetime :last_message_at
      t.timestamps
    end
    add_index :chat_conversations, :token, unique: true
    add_index :chat_conversations, :last_message_at

    create_table :chat_messages do |t|
      t.references :chat_conversation, null: false, foreign_key: true
      # "visitor" or "operator" - who wrote it, not who they are.
      t.string :author, null: false
      t.text :body, null: false
      t.datetime :read_at
      t.timestamps
    end
    add_index :chat_messages, [ :chat_conversation_id, :created_at ]
  end
end
