import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    assignees: Array,
    statuses: Array,
    freshOnly: Boolean,
    staleOnly: Boolean
  }

  connect() {
    this.loadFromHash()
    this.apply()
  }

  toggleAssignee(event) {
    const name = event.params.name
    this.assigneesValue = this.toggle(this.assigneesValue, name)
    this.persist()
    this.apply()
  }

  toggleStatus(event) {
    const name = event.params.name
    this.statusesValue = this.toggle(this.statusesValue, name)
    this.persist()
    this.apply()
  }

  toggleFreshOnly() {
    this.freshOnlyValue = !this.freshOnlyValue
    this.staleOnlyValue = false
    this.persist()
    this.apply()
  }

  toggleStaleOnly() {
    this.staleOnlyValue = !this.staleOnlyValue
    this.freshOnlyValue = false
    this.persist()
    this.apply()
  }

  toggle(arr, name) {
    return arr.includes(name) ? arr.filter(x => x !== name) : [...arr, name]
  }

  apply() {
    const postits = this.element.querySelectorAll(".postit")
    postits.forEach(p => {
      const assignee = p.dataset.assignee
      const status   = p.dataset.displayStatus
      const stale    = p.classList.contains("bg-red-100") || p.classList.contains("bg-yellow-100")
      const fresh    = !stale

      const passAssignee = this.assigneesValue.length === 0 || this.assigneesValue.includes(assignee)
      const passStatus   = this.statusesValue.length   === 0 || this.statusesValue.includes(status)
      const passFresh    = !this.freshOnlyValue || fresh
      const passStale    = !this.staleOnlyValue || stale

      p.classList.toggle("hidden", !(passAssignee && passStatus && passFresh && passStale))
    })
  }

  persist() {
    const state = {
      a: this.assigneesValue,
      s: this.statusesValue,
      f: this.freshOnlyValue,
      x: this.staleOnlyValue
    }
    location.hash = encodeURIComponent(JSON.stringify(state))
  }

  loadFromHash() {
    if (!location.hash) return
    try {
      const state = JSON.parse(decodeURIComponent(location.hash.slice(1)))
      this.assigneesValue = state.a || []
      this.statusesValue  = state.s || []
      this.freshOnlyValue = !!state.f
      this.staleOnlyValue = !!state.x
    } catch {}
  }
}
