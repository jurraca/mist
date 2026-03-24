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

let Hooks = {}
Hooks.NetworkGraph = {
  mounted() {
    this.graph = new NetworkGraph(`#${this.el.id}`)
    this.lastNodeCount = 0
    this.updateGraph()
    
    // Listen for incremental node/link updates from the server
    this.handleEvent("graph_update", ({nodes, links}) => {
      this.graph.updateIncremental({nodes, links})
    })
    
    // Listen for count updates to existing nodes
    this.handleEvent("graph_count_update", ({note_id, counts}) => {
      this.graph.updateNodeCounts(note_id, counts)
    })

    // Listen for filter resets from the server
    this.handleEvent("graph_reset", ({nodes, links}) => {
      this.graph.render({nodes, links})
      this.lastNodeCount = nodes.length
    })
  },

  updateGraph() {
    const graphData = JSON.parse(this.el.dataset.graph)
    this.lastNodeCount = graphData.nodes.length
    
    if (graphData.nodes.length > 0) {
      this.graph.render(graphData)
    } else if (graphData.nodes.length === 0) {
      // Clear the graph when no nodes
      this.graph.render({nodes: [], links: []})
    }
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