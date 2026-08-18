// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
import "./network_graph.js"

function formatRelativeTime(unixSeconds) {
  const seconds = Math.max(0, Math.floor(Date.now() / 1000) - unixSeconds)
  if (seconds < 60) return "just now"
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

let Hooks = {}
Hooks.NetworkGraph = {
  mounted() {
    this.graph = new NetworkGraph(`#${this.el.id}`)

    // Hover sidebar: filled client-side from the node payload (full content,
    // author, counts) — no server roundtrip. Sticky until the next hover.
    const sidebar = {
      placeholder: document.getElementById("graph-sidebar-placeholder"),
      content: document.getElementById("graph-sidebar-content"),
      author: document.getElementById("graph-sidebar-author"),
      time: document.getElementById("graph-sidebar-time"),
      body: document.getElementById("graph-sidebar-body"),
      stats: document.getElementById("graph-sidebar-stats"),
      id: document.getElementById("graph-sidebar-id")
    }

    this.graph.onNodeHover = (d) => {
      if (!sidebar.content) return
      sidebar.placeholder.classList.add("hidden")
      sidebar.content.classList.remove("hidden")
      sidebar.author.textContent = d.author || `${d.pubkey.slice(0, 12)}…`
      sidebar.time.textContent = d.created_at ? formatRelativeTime(d.created_at) : ""
      sidebar.body.textContent = d.content || ""

      const stats = []
      if (d.reaction_count > 0) stats.push(`❤️ ${d.reaction_count}`)
      if (d.boost_count > 0) stats.push(`🔄 ${d.boost_count}`)
      if (d.zap_amount > 0) stats.push(`⚡ ${d.zap_amount} sats`)
      sidebar.stats.textContent = stats.join("   ")
      sidebar.id.textContent = `event ${d.id.slice(0, 12)}…`
    }

    // The container is phx-update="ignore" (d3 owns its DOM), so the graph
    // data is fetched once via this handshake and then kept up to date
    // exclusively through push_event channels.
    this.handleEvent("graph_reset", ({nodes, links, window_seconds}) => {
      this.graph.render({nodes, links, window_seconds})
    })

    // Incremental node/link updates from the server
    this.handleEvent("graph_update", ({nodes, links}) => {
      this.graph.updateIncremental({nodes, links})
    })

    // Count updates to existing nodes
    this.handleEvent("graph_count_update", ({note_id, counts}) => {
      this.graph.updateNodeCounts(note_id, counts)
    })

    this.pushEvent("request_graph", {})
  },

  destroyed() {
    if (this.graph) {
      this.graph.destroy()
    }
  }
}

Hooks.Copy = {
  mounted() {
    let { to } = this.el.dataset;
    this.el.addEventListener("click", (ev) => {
      ev.preventDefault();
      const originalContent = this.el.innerHTML
      let text = document.querySelector(to).textContent || document.querySelector(to).value;
      navigator.clipboard.writeText(text).then(() => {
        this.el.innerHTML = "Copied!"
        this.el.classList.add("text-neon-green")

        setTimeout(() => {
          this.el.innerHTML = originalContent
          this.el.classList.remove("text-neon-green")
        }, 1000)
      }).catch(() => {
        console.log("Failed to copy to clipboard")
      })
    });
  },
}

Hooks.NoteCountUpdater = {
  mounted() {
    this.handleEvent("update_note_counts", ({note_id, counts}) => {
      const noteEl = document.getElementById(`notes-${note_id}`)
      if (!noteEl) return

      const statsContainer = noteEl.querySelector(".interaction-stats")
      if (!statsContainer) return

      let html = ""
      if (counts.reaction_count > 0) {
        html += `<div class="flex items-center gap-1"><span>❤️</span><span>${counts.reaction_count}</span></div>`
      }
      if (counts.boost_count > 0) {
        html += `<div class="flex items-center gap-1"><span>🔄</span><span>${counts.boost_count}</span></div>`
      }
      if (counts.zap_amount > 0) {
        html += `<div class="flex items-center gap-1"><span class="text-yellow-400">⚡</span><span class="text-yellow-400">${counts.zap_amount} sats</span></div>`
      }
      statsContainer.innerHTML = html
    })
  }
}

Hooks.AutoDismissFlash = {
  mounted() {
    this.timer = setTimeout(() => {
      this.el.click()
    }, 3000)
  },
  destroyed() {
    if (this.timer) clearTimeout(this.timer)
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket