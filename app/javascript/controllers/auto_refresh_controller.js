import { Controller } from "@hotwired/stimulus"

// Periodically reloads the page through Turbo, so a list stays current without the
// operator refreshing by hand. Turbo swaps the body rather than doing a full
// navigation, which keeps scroll position.
//
// Used on the admin inbox. Deliberately not used on a page with a form in progress -
// see admin_chat_controller for the conversation view, which appends new messages
// instead of reloading so a half-written reply is never lost.
export default class extends Controller {
  static values = { interval: { type: Number, default: 30000 } }

  connect() {
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  refresh() {
    // Nothing to update while the tab is in the background, and reloading there
    // just burns requests.
    if (document.hidden) return
    // Never yank the page out from under someone who is typing.
    const active = document.activeElement
    if (active && ["INPUT", "TEXTAREA", "SELECT"].includes(active.tagName)) return

    Turbo.visit(window.location.href, { action: "replace" })
  }
}
