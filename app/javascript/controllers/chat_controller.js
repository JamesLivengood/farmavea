import { Controller } from "@hotwired/stimulus"

// On-site chat. The conversation token lives in localStorage so a returning visitor
// sees the operator's reply; it identifies the thread, not the person.
//
// Polling only runs while the panel is open, so a page left in a tab does not sit
// hitting the server all day.
const TOKEN_KEY = "farmavea.chat.token"
const POLL_MS = 15000

export default class extends Controller {
  static targets = ["panel", "button", "label", "badge", "log", "empty",
                    "form", "message", "email", "emailRow", "status", "submit"]
  static values = { endpoint: String }

  connect() {
    this.token = this.readToken()
    this.pollTimer = null
    this.renderedCount = 0
    this.boundEscape = this.closeIfEscape.bind(this)

    // A returning visitor may have a reply waiting - check once without opening.
    if (this.token) this.load({ quiet: true })
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
    this.stopPolling()
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

      // A reply arrived while the panel was shut - badge the button.
      if (quiet && messages.length > this.renderedCount) {
        const unseen = messages.slice(this.renderedCount).filter((m) => m.author === "operator")
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

    this.logTarget.innerHTML = ""
    messages.forEach((m) => this.appendMessage(m, { skipCount: true }))
    this.renderedCount = messages.length
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
    this.pollTimer = setInterval(() => this.load(), POLL_MS)
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
