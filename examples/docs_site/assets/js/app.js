import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/oh_my_jido_docs"
import topbar from "../vendor/topbar"

const StudioConnection = {
  mounted() { this.setConnected(true) },
  disconnected() { this.setConnected(false) },
  reconnected() {
    this.setConnected(true)
    this.pushEvent("refresh", {})
  },
  setConnected(connected) {
    this.el.dataset.connected = String(connected)
    const status = this.el.querySelector("[data-connection-status]")
    if (status) status.textContent = connected ? "Connected to host" : "Reconnecting — host work continues"
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, StudioConnection},
})

topbar.config({barColors: {0: "#648e52"}, shadowColor: "rgba(32, 40, 32, .15)"})
window.addEventListener("phx:page-loading-start", () => topbar.show(250))
window.addEventListener("phx:page-loading-stop", () => topbar.hide())
liveSocket.connect()
