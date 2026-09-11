import { Controller } from "@hotwired/stimulus"

// Search box dropdown with two modes: an empty input shows the visitor's own recent
// searches (client-side only, localStorage - a per-visitor convenience, not shared
// or persisted server-side); typing shows live medication-name suggestions fetched
// from /autocomplete.
export default class extends Controller {
  static targets = ["input", "menu"]
  static values = { url: String }

  static STORAGE_KEY = "farmavea_recent_searches"
  static MAX_ENTRIES = 8
  static DEBOUNCE_MS = 200

  connect() {
    this.boundHideOnClickOutside = this.hideOnClickOutside.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this.boundHideOnClickOutside)
    clearTimeout(this.debounceTimer)
  }

  onFocus() {
    if (this.inputTarget.value.trim()) {
      this.onInput()
    } else {
      this.showRecent()
    }
  }

  onInput() {
    const query = this.inputTarget.value.trim()
    clearTimeout(this.debounceTimer)

    if (!query) {
      this.showRecent()
      return
    }

    this.debounceTimer = setTimeout(() => this.fetchSuggestions(query), this.constructor.DEBOUNCE_MS)
  }

  async fetchSuggestions(query) {
    let response
    try {
      response = await fetch(`${this.urlValue}?q=${encodeURIComponent(query)}`, {
        headers: { Accept: "application/json" }
      })
    } catch {
      return // offline/network hiccup - just leave whatever menu state was showing
    }
    if (!response.ok) return

    // Guard against an earlier, slower request finishing after the visitor has
    // since changed the input further.
    if (this.inputTarget.value.trim() !== query) return

    const suggestions = await response.json()
    if (suggestions.length === 0) {
      this.menuTarget.hidden = true
      return
    }

    this.menuTarget.innerHTML = suggestions.map((s) => this.renderSuggestion(s)).join("")
    this.menuTarget.hidden = false
    document.addEventListener("click", this.boundHideOnClickOutside)
  }

  showRecent() {
    const recent = this.readRecent()
    if (recent.length === 0) {
      this.menuTarget.hidden = true
      return
    }

    this.menuTarget.innerHTML = recent
      .map((term) => this.renderItem(term))
      .join("")
    this.menuTarget.hidden = false
    document.addEventListener("click", this.boundHideOnClickOutside)
  }

  selectItem(event) {
    const term = event.currentTarget.dataset.term
    this.inputTarget.value = term
    this.menuTarget.hidden = true
    this.element.requestSubmit()
  }

  selectSuggestion(event) {
    window.location.href = event.currentTarget.dataset.url
  }

  removeItem(event) {
    event.stopPropagation()
    const term = event.currentTarget.dataset.term
    const remaining = this.readRecent().filter((t) => t !== term)
    this.writeRecent(remaining)
    if (remaining.length === 0) {
      this.menuTarget.hidden = true
    } else {
      this.showRecent()
    }
  }

  recordSearch() {
    const term = this.inputTarget.value.trim()
    if (!term) return

    const recent = this.readRecent().filter((t) => t.toLowerCase() !== term.toLowerCase())
    recent.unshift(term)
    this.writeRecent(recent.slice(0, this.constructor.MAX_ENTRIES))
  }

  hideOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.menuTarget.hidden = true
      document.removeEventListener("click", this.boundHideOnClickOutside)
    }
  }

  readRecent() {
    try {
      const raw = localStorage.getItem(this.constructor.STORAGE_KEY)
      const parsed = raw ? JSON.parse(raw) : []
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }

  writeRecent(list) {
    try {
      localStorage.setItem(this.constructor.STORAGE_KEY, JSON.stringify(list))
    } catch {
      // Storage unavailable (private browsing, quota, etc.) - recent searches just
      // won't persist this session, not worth surfacing to the visitor.
    }
  }

  renderItem(term) {
    const escaped = term.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    return `
      <div class="flex items-center justify-between gap-2 px-3.5 py-2 hover:bg-slate-50 cursor-pointer text-sm text-slate-700"
           data-action="click->search-history#selectItem" data-term="${escaped}">
        <span class="flex items-center gap-2 min-w-0">
          <svg class="w-3.5 h-3.5 text-slate-300 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
          <span class="truncate">${escaped}</span>
        </span>
        <button type="button" class="shrink-0 text-slate-300 hover:text-slate-500 px-1"
                data-action="click->search-history#removeItem" data-term="${escaped}" aria-label="Eliminar">
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>
    `
  }

  renderSuggestion(suggestion) {
    const escapedLabel = String(suggestion.label)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    const escapedUrl = String(suggestion.url).replace(/"/g, "&quot;")
    return `
      <div class="flex items-center gap-2 px-3.5 py-2 hover:bg-slate-50 cursor-pointer text-sm text-slate-700"
           data-action="click->search-history#selectSuggestion" data-url="${escapedUrl}">
        <svg class="w-3.5 h-3.5 text-emerald-400 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M21 21l-4.35-4.35M17 10.5a6.5 6.5 0 11-13 0 6.5 6.5 0 0113 0z" />
        </svg>
        <span class="truncate">${escapedLabel}</span>
      </div>
    `
  }
}
