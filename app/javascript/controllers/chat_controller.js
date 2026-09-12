import { Controller } from "@hotwired/stimulus"

// On-site chat. The conversation token lives in localStorage so a returning visitor
// sees the operator's reply; it identifies the thread, not the person.
//
// Polling only runs while the panel is open, so a page left in a tab does not sit
// hitting the server all day.
const TOKEN_KEY = "farmavea.chat.token"
// Open panel: frequent enough that a reply feels live. Closed panel: still polled,
// just slowly, so a badge appears without the visitor having to reload the page.
const POLL_MS_OPEN = 5000
const POLL_MS_CLOSED = 30000

export default class extends Controller {
  static targets = ["panel", "button", "label", "badge", "log", "empty",
                    "form", "message", "email", "emailRow", "status", "submit"]
  static values = { endpoint: String }

  connect() {
    this.token = this.readToken()
    this.pollTimer = null
    this.renderedCount = 0
    // What the visitor has actually looked at, as opposed to what is in the DOM -
    // messages render into the closed panel too, so renderedCount alone would clear
    // the badge before it was ever seen.
    this.seenCount = 0
    this.boundEscape = this.closeIfEscape.bind(this)

    // A returning visitor may have a reply waiting - check once without opening,
    // then keep polling slowly so a reply that arrives while they are reading the
    // page still surfaces without a refresh.
    if (this.token) {
      this.load({ quiet: true })
      this.startPolling()
    }
  }

  disconnect() {
    this.stopPolling()
    document.removeEventListener("keydown", this.boundEscape)
  }

  // --- open / close -------------------------------------------------------

  toggle() {
    this.panelTarget.hidden ? this.open() : this.close()
  }

  open() {
    this.panelTarget.hidden = false
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this.labelTarget.textContent = "Cerrar"
    this.badgeTarget.hidden = true
    // Opening the panel means everything currently rendered has now been seen.
    this.seenCount = this.renderedCount
    this.messageTarget.focus()
    document.addEventListener("keydown", this.boundEscape)
    if (this.token) this.load()
    this.startPolling()
  }

  close() {
    this.panelTarget.hidden = true
    this.buttonTarget.setAttribute("aria-expanded", "false")
    this.labelTarget.textContent = "Pregúntanos"
    document.removeEventListener("keydown", this.boundEscape)
    // Keep polling, just slowly - closing the panel should not stop a reply from
    // arriving, it should only change how loudly it announces itself.
    this.startPolling()
  }

  closeIfEscape(event) {
    if (event.key === "Escape") {
      this.close()
      this.buttonTarget.focus()
    }
  }

  // --- sending ------------------------------------------------------------

  maybeSend(event) {
    // Enter sends; Shift+Enter makes a new line, as people expect from a chat box.
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.send(event)
    }
  }

  async send(event) {
    event.preventDefault()
    const body = this.messageTarget.value.trim()
    if (body === "") return

    this.submitTarget.disabled = true
    this.statusTarget.textContent = "Enviando…"

    try {
      const response = await fetch(this.endpointValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({
          token: this.token,
          body: body,
          email: this.hasEmailTarget ? this.emailTarget.value.trim() : ""
        })
      })

      const data = await response.json()

      if (!response.ok) {
        this.statusTarget.textContent = data.error || "No se pudo enviar. Intenta de nuevo."
        return
      }

      this.token = data.token
      this.writeToken(data.token)
      this.messageTarget.value = ""
      this.appendMessage(data.message)
      this.seenCount = this.renderedCount
      this.statusTarget.textContent = "Mensaje enviado. Te responderemos en cuanto podamos."
      // The email is only needed once per conversation.
      if (this.hasEmailRowTarget && this.emailTarget.value.trim() !== "") {
        this.emailRowTarget.hidden = true
      }
      this.startPolling()
    } catch (error) {
      this.statusTarget.textContent = "No se pudo enviar. Revisa tu conexión."
    } finally {
      this.submitTarget.disabled = false
    }
  }

  // --- loading ------------------------------------------------------------

  async load({ quiet = false } = {}) {
    if (!this.token) return

    try {
      const url = `${this.endpointValue}?token=${encodeURIComponent(this.token)}`
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) return

      const data = await response.json()
      const messages = data.messages || []

      // A reply arrived while the panel was shut - badge the button. Counted
      // against everything the visitor has actually seen, not just this poll, so
      // several replies in a row accumulate rather than resetting to 1.
      if (quiet && messages.length > this.seenCount) {
        const unseen = messages.slice(this.seenCount).filter((m) => m.author === "operator")
        if (unseen.length > 0) {
          this.badgeTarget.textContent = unseen.length
          this.badgeTarget.hidden = false
        }
      }

      this.renderAll(messages)
    } catch (error) {
      // Silent: a failed poll should never disturb the page.
    }
  }

  renderAll(messages) {
    if (messages.length === 0) return
    // Nothing new - avoid tearing down and rebuilding the log on every poll, which
    // would fight the user's scroll position and any text selection.
    if (messages.length === this.renderedCount) return

    this.logTarget.innerHTML = ""
    messages.forEach((m) => this.appendMessage(m, { skipCount: true }))
    this.renderedCount = messages.length
    // With the panel open the visitor is looking at these as they arrive.
    if (!this.panelTarget.hidden) this.seenCount = messages.length
  }

  appendMessage(message, { skipCount = false } = {}) {
    if (this.hasEmptyTarget) this.emptyTarget.remove()

    const row = document.createElement("div")
    row.className = message.author === "visitor" ? "flex justify-end" : "flex justify-start"

    const bubble = document.createElement("div")
    bubble.className = message.author === "visitor"
      ? "bg-emerald-600 text-white rounded-2xl rounded-br-sm px-3 py-2 max-w-[85%] whitespace-pre-wrap break-words"
      : "bg-slate-100 text-slate-800 rounded-2xl rounded-bl-sm px-3 py-2 max-w-[85%] whitespace-pre-wrap break-words"
    bubble.textContent = message.body

    row.appendChild(bubble)
    this.logTarget.appendChild(row)
    this.logTarget.scrollTop = this.logTarget.scrollHeight

    if (!skipCount) this.renderedCount += 1
  }

  // --- polling ------------------------------------------------------------

  startPolling() {
    this.stopPolling()
    if (!this.token) return

    const open = !this.panelTarget.hidden
    const interval = open ? POLL_MS_OPEN : POLL_MS_CLOSED
    // `quiet` when closed, so a reply badges the button instead of silently
    // rendering into a panel nobody is looking at.
    this.pollTimer = setInterval(() => this.load({ quiet: !open }), interval)
  }

  stopPolling() {
    if (this.pollTimer) clearInterval(this.pollTimer)
    this.pollTimer = null
  }

  // --- storage ------------------------------------------------------------

  // Wrapped because storage throws outright in some privacy modes, and a chat
  // widget must not take the page down with it.
  readToken() {
    try {
      return window.localStorage.getItem(TOKEN_KEY)
    } catch (error) {
      return null
    }
  }

  writeToken(token) {
    try {
      window.localStorage.setItem(TOKEN_KEY, token)
    } catch (error) {
      // Chat still works for this page view; the thread just is not resumed later.
    }
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
