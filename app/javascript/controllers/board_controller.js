import { Controller } from "@hotwired/stimulus"

// Owns the global board state: text search, status-pill highlight,
// people-filter (set from the people controller), and hover tooltip.
// Each card has data-search/data-assignee/data-display-status driving the match.
export default class extends Controller {
  static targets = ["statusPill", "statusClear", "search", "root", "tooltip"]
  static values = {
    statuses: Array,
    assignees: Array,
    query: String
  }

  connect() {
    this.loadFromHash()
    this.syncStatusUI()
    if (this.hasSearchTarget) this.searchTarget.value = this.queryValue
    this.apply()
    this._onWinResize = () => this._positionTooltip()
    window.addEventListener("scroll", this._onWinResize, true)
    window.addEventListener("resize", this._onWinResize)
  }

  disconnect() {
    window.removeEventListener("scroll", this._onWinResize, true)
    window.removeEventListener("resize", this._onWinResize)
  }

  // ---------- search ----------
  search(event) {
    this.queryValue = event.target.value || ""
    this.persist()
    this.apply()
  }

  // ---------- status pills ----------
  toggleStatus(event) {
    const el = event.currentTarget
    const id = el.dataset.state
    const set = new Set(this.statusesValue)
    set.has(id) ? set.delete(id) : set.add(id)
    this.statusesValue = [...set]
    this.persist()
    this.syncStatusUI()
    this.apply()
  }

  clearStatuses() {
    this.statusesValue = []
    this.persist()
    this.syncStatusUI()
    this.apply()
  }

  syncStatusUI() {
    const sel = new Set(this.statusesValue)
    const anyOn = sel.size > 0
    this.statusPillTargets.forEach((el) => {
      const on = sel.has(el.dataset.state)
      const color = el.dataset.color
      el.dataset.on = on ? "1" : "0"
      el.dataset.muted = (anyOn && !on) ? "1" : "0"
      if (on) {
        el.style.background = color
        el.style.borderColor = color
        // recolor inner dot to white when active
        const dot = el.querySelector(".pg-pill-dot")
        if (dot) dot.style.background = "#fff"
      } else {
        el.style.background = ""
        el.style.borderColor = ""
        const dot = el.querySelector(".pg-pill-dot")
        if (dot) dot.style.background = color
      }
    })
    if (this.hasStatusClearTarget) this.statusClearTarget.hidden = !anyOn
  }

  // ---------- people filter (called by people controller) ----------
  setAssignees(list) {
    this.assigneesValue = list
    this.persist()
    this.apply()
  }

  // ---------- core filter pass ----------
  apply() {
    const q = (this.queryValue || "").trim().toLowerCase()
    const sel = new Set(this.statusesValue)
    const pset = new Set(this.assigneesValue)
    const anyFilter = q.length > 0 || sel.size > 0 || pset.size > 0

    const cards = this.element.querySelectorAll(".pg-card")
    cards.forEach((c) => {
      const search = c.dataset.search || ""
      const status = c.dataset.displayStatus || ""
      const assignee = c.dataset.assignee || ""
      const matchQ = !q || search.includes(q)
      const matchS = sel.size === 0 || sel.has(status)
      const matchP = pset.size === 0 || pset.has(assignee)
      const match = matchQ && matchS && matchP
      if (anyFilter) {
        c.dataset.dim = match ? "0" : "1"
        c.dataset.spotlight = (match && (sel.size > 0 || pset.size > 0 || q.length > 0)) ? "1" : "0"
      } else {
        c.dataset.dim = "0"
        c.dataset.spotlight = "0"
      }
    })

    document.querySelectorAll("[data-controller~=stack]").forEach((el) => {
      if (el.stackController) el.stackController.refreshHits()
    })
  }

  // ---------- hover tooltip ----------
  showTooltip(event) {
    const card = event.currentTarget
    clearTimeout(this._ttTimer)
    this._ttTimer = setTimeout(() => this._renderTooltip(card), 140)
  }

  hideTooltip() {
    clearTimeout(this._ttTimer)
    if (this.hasTooltipTarget) this.tooltipTarget.hidden = true
    this._ttAnchor = null
  }

  _renderTooltip(card) {
    if (!this.hasTooltipTarget) return
    const ds = card.dataset
    const stateColor = ds.tooltipStateColor || "#94a3b8"
    const stale = ds.tooltipStale && ds.tooltipStale !== "fresh"
    const staleClass = stale ? ds.tooltipStale : null
    const staleColor = ds.tooltipStale === "critical" ? "#fca5a5"
                    : ds.tooltipStale === "stale" ? "#fdba74" : "#e8ecf2"
    this.tooltipTarget.innerHTML = `
      <div class="pg-tt-row">
        <span class="pg-tt-id">${ds.tooltipId || ""}</span>
        <span class="pg-tt-state-pill" style="background:${stateColor}">${ds.tooltipState || ""}</span>
      </div>
      <div class="pg-tt-title">${this._esc(ds.tooltipTitle || "")}</div>
      <div class="pg-tt-grid">
        <span class="lbl">Type</span><span class="val">${this._esc(ds.tooltipType || "—")}</span>
        <span class="lbl">Assignee</span><span class="val">${this._esc(ds.tooltipAssignee || "Unassigned")}</span>
        <span class="lbl">In state</span><span class="val" style="color:${staleColor}">${ds.tooltipDays ? ds.tooltipDays + " days" : "—"}${stale ? " · " + staleClass : ""}</span>
        <span class="lbl">Priority</span><span class="val">${this._esc(ds.tooltipPriority || "Medium")}</span>
        <span class="lbl">Jira status</span><span class="val">${this._esc(ds.tooltipStatusRaw || "—")}</span>
      </div>
      <div class="pg-tt-hint">Click to open · ↗ Jira</div>
    `
    this._ttAnchor = card
    this.tooltipTarget.hidden = false
    this._positionTooltip()
  }

  _positionTooltip() {
    if (!this.hasTooltipTarget || !this._ttAnchor || this.tooltipTarget.hidden) return
    const tt = this.tooltipTarget
    const r = this._ttAnchor.getBoundingClientRect()
    const W = 270
    let left = r.right + 10
    if (left + W > window.innerWidth - 8) left = r.left - W - 10
    let top = r.top
    top = Math.min(top, window.innerHeight - 240)
    top = Math.max(8, top)
    tt.style.left = left + "px"
    tt.style.top = top + "px"
    tt.style.width = W + "px"
  }

  _esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]))
  }

  // ---------- persistence ----------
  persist() {
    const state = {
      q: this.queryValue,
      s: this.statusesValue,
      a: this.assigneesValue
    }
    location.hash = encodeURIComponent(JSON.stringify(state))
  }

  loadFromHash() {
    if (!location.hash) return
    try {
      const state = JSON.parse(decodeURIComponent(location.hash.slice(1)))
      this.queryValue = state.q || ""
      this.statusesValue = state.s || []
      this.assigneesValue = state.a || []
    } catch {}
  }
}
