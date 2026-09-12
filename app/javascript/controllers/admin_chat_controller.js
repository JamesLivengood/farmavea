import { Controller } from "@hotwired/stimulus"

// Keeps the operator's conversation view current without a manual refresh.
//
// Polls the same JSON endpoint the visitor widget uses, addressed by the
// conversation's token. Only appends messages that are not already on the page, so
// a reply being typed into the textarea is never disturbed.
const POLL_MS = 5000

export default class extends Controller {
  static targets = ["log", "form", "body"]
  static values = { endpoint: String, token: String }

  connect() {
    this.renderedCount = this.logTarget.querySelectorAll("[data-message]").length
    this.timer = setInterval(() => this.load(), POLL_MS)
    // Coming back to the tab should show what arrived while it was hidden, without
    // waiting out the interval.
    this.boundVisibility = () => { if (!document.hidden) this.load() }
    document.addEventListener("visibilitychange", this.boundVisibility)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
    document.removeEventListener("visibilitychange", this.boundVisibility)
  }

  async load() {
    try {
      const url = `${this.endpointValue}?token=${encodeURIComponent(this.tokenValue)}`
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) return

      const data = await response.json()
      const messages = data.messages || []
      if (messages.length <= this.renderedCount) return

      messages.slice(this.renderedCount).forEach((m) => this.append(m))
      this.renderedCount = messages.length
    } catch (error) {
      // Silent: a failed poll must not disturb a reply being written.
    }
  }

  append(message) {
    const visitor = message.author === "visitor"

    const row = document.createElement("div")
    row.className = `flex ${visitor ? "justify-start" : "justify-end"}`
    row.setAttribute("data-message", "")

    const bubble = document.createElement("div")
    bubble.className = visitor
      ? "bg-slate-100 text-slate-800 rounded-2xl px-3.5 py-2 max-w-[80%]"
      : "bg-emerald-600 text-white rounded-2xl px-3.5 py-2 max-w-[80%]"

    const text = document.createElement("p")
    text.className = "text-sm whitespace-pre-wrap break-words"
    text.textContent = message.body

    const stamp = document.createElement("p")
    stamp.className = `${visitor ? "text-slate-400" : "text-emerald-100"} text-[10px] mt-1`
    stamp.textContent = new Date(message.at).toLocaleString("es-MX", {
      day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit"
    })

    bubble.appendChild(text)
    bubble.appendChild(stamp)
    row.appendChild(bubble)
    this.logTarget.appendChild(row)
    this.logTarget.scrollTop = this.logTarget.scrollHeight
  }
}
