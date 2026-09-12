class ChatMessage < ApplicationRecord
  belongs_to :chat_conversation, inverse_of: :messages

  AUTHORS = %w[visitor operator].freeze
  MAX_LENGTH = 2000

  validates :author, inclusion: { in: AUTHORS }
  validates :body, presence: true, length: { maximum: MAX_LENGTH }

  after_create_commit :touch_conversation

  scope :from_visitors, -> { where(author: "visitor") }
  scope :from_operator, -> { where(author: "operator") }

  def visitor? = author == "visitor"
  def operator? = author == "operator"

  private

  def touch_conversation
    chat_conversation.update_column(:last_message_at, created_at)
  end
end
