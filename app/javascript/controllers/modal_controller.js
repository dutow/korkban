import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  closeIfBackdrop(event) {
    if (event.target === this.element) this.close()
  }

  stop(event) { event.stopPropagation() }

  closeOnEsc(event) {
    if (event.key === "Escape") this.close()
  }

  close(event) {
    event?.preventDefault()
    const frame = document.querySelector("turbo-frame#modal")
    if (frame) frame.innerHTML = ""
  }
}
