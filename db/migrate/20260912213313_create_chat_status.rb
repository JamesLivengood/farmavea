class CreateChatStatus < ActiveRecord::Migration[8.1]
  def change
    # A single row holding whether someone is available to answer. Kept in the
    # database rather than an env var so it can be flipped from a phone by sending
    # the bot "online" / "offline", without a deploy.
    create_table :chat_statuses do |t|
      t.boolean :online, null: false, default: false
      t.datetime :changed_at
      t.timestamps
    end

    # A visitor may leave a phone number as well as (or instead of) an email, so
    # there is a way to reach them once they close the page. Same treatment as the
    # email: optional, only stored when typed in, and covered by the 90-day
    # retention - a phone number attached to a medication question is personal
    # health data under the LFPDPPP.
    add_column :chat_conversations, :visitor_phone, :string
  end
end
