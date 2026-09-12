import { Controller } from "@hotwired/stimulus"

// On-site chat. The conversation token lives in localStorage so a returning visitor
// sees the operator's reply; it identifies the thread, not the person.
//
// Polling runs whether or not the panel is open - just slower when closed - because
// a reply that only appears after a manual refresh may as well not have arrived.
const TOKEN_KEY = "farmavea.chat.token"
const SEEN_KEY = "farmavea.chat.seen"
// Open panel: frequent enough that a reply feels live. Closed panel: still polled,
// just slowly, so a badge appears without the visitor having to reload the page.
const POLL_MS_OPEN = 5000
const POLL_MS_CLOSED = 30000

export default class extends Controller {
  static targets = ["panel", "button", "label", "badge", "log", "empty",
                    "form", "message", "email", "phone", "contactRow", "contactPrompt",
                    "presence", "presenceDot", "presenceLabel", "presenceNote",
                    "status", "submit"]
  static values = { endpoint: String }

  connect() {
    this.token = this.readToken()
    this.pollTimer = null
    this.renderedCount = 0
    // What the visitor has actually looked at, as opposed to what is in the DOM -
    // messages render into the closed panel too, so renderedCount alone would clear
    // the badge before it was ever seen.
    //
    // Persisted because navigating to another page tears the controller down and
    // builds a new one: starting from 0 would re-badge every message they had
    // already read on the previous page.
    this.seenCount = this.readSeenCount()
    // Assume offline until told otherwise: requiring contact details when they are
    // not needed is a minor annoyance, but letting a message vanish unanswered is not.
    this.online = false
    this.boundEscape = this.closeIfEscape.bind(this)
    // Mobile browsers throttle or suspend timers in a background tab, and some kill
    // them outright - so a phone left on the page can come back with a dead poller.
    // Fetching on refocus is what makes a reply appear without a manual refresh.
    this.boundVisibility = () => {
      if (document.hidden) return
      this.load({ quiet: this.panelTarget.hidden })
      this.startPolling()
    }
    document.addEventListener("visibilitychange", this.boundVisibility)
    window.addEventListener("focus", this.boundVisibility)
    // Turbo restores pages from its cache without re-running connect(), so a
    // back-navigation would otherwise show a stale log with no poller running.
    document.addEventListener("turbo:load", this.boundVisibility)

    // A returning visitor may have a reply waiting - check once without opening,
    // then keep polling slowly so a reply that arrives while they are reading the
    // page still surfaces without a refresh.
    if (this.token) {
      this.load({ quiet: true })
      this.startPolling()
    } else {
      // No conversation yet, but presence still matters: someone deciding whether
      // to type needs to know if anyone is there to answer.
      this.loadPresence()
    }
  }

  disconnect() {
    this.stopPolling()
    document.removeEventListener("keydown", this.boundEscape)
    document.removeEventListener("visibilitychange", this.boundVisibility)
    window.removeEventListener("focus", this.boundVisibility)
    document.removeEventListener("turbo:load", this.boundVisibility)
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
    this.writeSeenCount(this.seenCount)
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

    if (this.needsContact()) {
      this.statusTarget.textContent = "Déjanos tu correo o teléfono para poder responderte."
      if (this.hasContactPromptTarget) this.contactPromptTarget.classList.remove("hidden")
      if (this.hasEmailTarget) this.emailTarget.focus()
      return
    }

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
          email: this.hasEmailTarget ? this.emailTarget.value.trim() : "",
          phone: this.hasPhoneTarget ? this.phoneTarget.value.trim() : ""
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
      this.writeSeenCount(this.seenCount)
      this.statusTarget.textContent = "Mensaje enviado. Te responderemos en cuanto podamos."
      // Contact details are only needed once per conversation.
      const gaveContact = (this.hasEmailTarget && this.emailTarget.value.trim() !== "") ||
                          (this.hasPhoneTarget && this.phoneTarget.value.trim() !== "")
      if (gaveContact) this.contactGiven = true
      if (this.hasContactRowTarget && gaveContact) this.contactRowTarget.hidden = true
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
      if (typeof data.online === "boolean") this.renderPresence(data.online)
      if (data.contact_given) {
        this.contactGiven = true
        if (this.hasContactRowTarget) this.contactRowTarget.hidden = true
      }

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

  // Presence only - used before a conversation exists, where load() would bail for
  // want of a token.
  async loadPresence() {
    try {
      const response = await fetch(this.endpointValue, { headers: { Accept: "application/json" } })
      if (!response.ok) return

      const data = await response.json()
      if (typeof data.online === "boolean") this.renderPresence(data.online)
      if (data.contact_given) {
        this.contactGiven = true
        if (this.hasContactRowTarget) this.contactRowTarget.hidden = true
      }
    } catch (error) {
      // Leave the neutral placeholder rather than guessing.
    }
  }

  renderPresence(online) {
    this.online = online
    if (!this.hasPresenceLabelTarget) return

    this.presenceLabelTarget.textContent = online ? "En línea" : "Desconectado"
    this.presenceDotTarget.className = online
      ? "w-1.5 h-1.5 rounded-full bg-emerald-300"
      : "w-1.5 h-1.5 rounded-full bg-slate-300"

    if (this.hasPresenceNoteTarget) {
      this.presenceNoteTarget.textContent = online
        ? "Escríbenos y te respondemos"
        : "Déjanos tu mensaje y te contactamos en cuanto podamos"
    }

    // Offline, the contact fields are how they get an answer at all - so say so
    // rather than leaving them looking optional.
    if (this.hasContactPromptTarget) {
      this.contactPromptTarget.classList.toggle("hidden", online)
    }

    // "(opcional)" would be a lie while one of them is required.
    if (this.hasEmailTarget) {
      this.emailTarget.placeholder = online ? "Tu correo (opcional)" : "Tu correo"
    }
    if (this.hasPhoneTarget) {
      this.phoneTarget.placeholder = online ? "Tu teléfono o WhatsApp (opcional)" : "Tu teléfono o WhatsApp"
    }
  }

  // True when this visitor still owes us a way to reach them. Mirrors the server
  // check in ChatsController#requires_contact? - this one exists to catch it before
  // the round trip, not instead of it.
  needsContact() {
    if (this.online) return false
    if (this.contactGiven) return false

    const email = this.hasEmailTarget ? this.emailTarget.value.trim() : ""
    const phone = this.hasPhoneTarget ? this.phoneTarget.value.trim() : ""
    return email === "" && phone === ""
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
    if (!this.panelTarget.hidden) {
      this.seenCount = messages.length
      this.writeSeenCount(this.seenCount)
    }
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

  readSeenCount() {
    try {
      return parseInt(window.localStorage.getItem(SEEN_KEY) || "0", 10) || 0
    } catch (error) {
      return 0
    }
  }

  writeSeenCount(count) {
    try {
      window.localStorage.setItem(SEEN_KEY, String(count))
    } catch (error) {
      // Worst case the badge reappears for a message already read.
    }
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
