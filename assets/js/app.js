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

const IMG_URL_RE = /https?:\/\/\S+\.(?:jpg|jpeg|png|gif|webp|svg|avif)(?:\?\S*)?/gi
const URL_RE = /https?:\/\/\S+/gi
const WSS_RE = /wss?:\/\/\S+/gi
const NOSTR_REF_RE = /(?:nostr:)?(nevent1|naddr1|note1|npub1|nprofile1)[0-9a-z]+/gi
const HASHTAG_RE = /#[\p{L}\p{N}_]+/gu

const TRAILING_PUNCT_RE = /^(.*?)[)\],.;:!?'"]+$/

function trimTrailingPunct(url) {
  const m = url.match(TRAILING_PUNCT_RE)
  return m ? m[1] : url
}

function truncateMiddle(s, head = 14, tail = 8) {
  return s.length > head + tail + 1 ? `${s.slice(0, head)}…${s.slice(-tail)}` : s
}

// Renders note content into a container: image URLs inline, https links as
// clickable anchors, Nostr entities as anchors to njump.me (a renderer for
// Nostr events/addresses), and wss relay URLs as copy-to-clipboard chips.
// Uses DOM APIs exclusively (no innerHTML) so note content is never parsed
// as HTML — XSS-safe.
function renderNoteContent(container, text) {
  container.replaceChildren()
  if (!text) return

  const matches = []
  const collect = (re, type, priority, trim) => {
    re.lastIndex = 0
    let m
    while ((m = re.exec(text)) !== null) {
      const clean = trim ? trimTrailingPunct(m[0]) : m[0]
      if (clean) matches.push({ index: m.index, length: clean.length, text: clean, type, priority })
    }
  }

  // Lower priority wins at the same index: an image URL also matches the
  // generic URL regex, but only the image match is rendered.
  collect(IMG_URL_RE, "image", 0, false)
  collect(NOSTR_REF_RE, "nostr", 1, false)
  collect(WSS_RE, "wss", 2, true)
  collect(URL_RE, "url", 3, true)
  collect(HASHTAG_RE, "hashtag", 4, false)

  matches.sort((a, b) => a.index - b.index || a.priority - b.priority)

  let lastIndex = 0
  for (const match of matches) {
    if (match.index < lastIndex) continue

    if (match.index > lastIndex) {
      container.appendChild(document.createTextNode(text.slice(lastIndex, match.index)))
    }

    if (match.type === "image") {
      const img = document.createElement("img")
      img.src = match.text
      img.referrerPolicy = "no-referrer"
      img.loading = "lazy"
      img.alt = ""
      img.className = "rounded-lg max-w-full max-h-96 h-auto mx-auto border border-dark-border"
      img.onerror = () => { img.remove() }
      container.appendChild(img)
    } else if (match.type === "nostr") {
      const bare = match.text.replace(/^nostr:/, "")
      const a = document.createElement("a")
      a.href = `https://njump.me/${bare}`
      a.target = "_blank"
      a.rel = "noopener noreferrer"
      a.textContent = truncateMiddle(bare)
      a.title = bare
      a.className = "text-neon-green hover:underline font-mono text-xs"
      container.appendChild(a)
    } else if (match.type === "wss") {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.textContent = truncateMiddle(match.text)
      chip.title = `${match.text} — click to copy`
      chip.className = "font-mono text-xs text-neon-purple bg-dark-tertiary border border-dark-border rounded px-1.5 py-0.5 cursor-pointer hover:border-neon-purple"
      chip.addEventListener("click", () => {
        navigator.clipboard.writeText(match.text).then(() => {
          if (chip.dataset.orig == null) chip.dataset.orig = chip.textContent
          chip.textContent = "Copied!"
          setTimeout(() => { chip.textContent = chip.dataset.orig }, 1000)
        }).catch(() => {})
      })
      container.appendChild(chip)
    } else if (match.type === "hashtag") {
      const tag = document.createElement("span")
      tag.textContent = match.text
      tag.className = "text-neon-purple font-medium"
      container.appendChild(tag)
    } else {
      const a = document.createElement("a")
      a.href = match.text
      a.target = "_blank"
      a.rel = "noopener noreferrer"
      a.textContent = truncateMiddle(match.text, 50, 10)
      a.title = match.text
      a.className = "text-neon-green hover:underline break-all"
      container.appendChild(a)
    }

    lastIndex = match.index + match.length
  }

  if (lastIndex < text.length) {
    container.appendChild(document.createTextNode(text.slice(lastIndex)))
  }
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
      single: document.getElementById("graph-sidebar-single"),
      thread: document.getElementById("graph-sidebar-thread"),
      avatar: document.getElementById("graph-sidebar-avatar"),
      avatarPlaceholder: document.getElementById("graph-sidebar-avatar-placeholder"),
      author: document.getElementById("graph-sidebar-author"),
      time: document.getElementById("graph-sidebar-time"),
      body: document.getElementById("graph-sidebar-body"),
      stats: document.getElementById("graph-sidebar-stats"),
      id: document.getElementById("graph-sidebar-id")
    }

    // Broken avatar URLs fall back to the initial-letter placeholder
    sidebar.avatar.onerror = () => {
      sidebar.avatar.classList.add("hidden")
      sidebar.avatarPlaceholder.classList.remove("hidden")
    }

    this.graph.onNodeHover = (d) => {
      if (!sidebar.content) return
      sidebar.placeholder.classList.add("hidden")
      sidebar.thread.classList.add("hidden")
      sidebar.single.classList.remove("hidden")

      sidebar.author.textContent = d.author || ""
      sidebar.time.textContent = d.created_at ? formatRelativeTime(d.created_at) : ""
      sidebar.body.textContent = ""
      renderNoteContent(sidebar.body, d.content || "")

      if (d.picture) {
        sidebar.avatar.src = d.picture
        sidebar.avatar.classList.remove("hidden")
        sidebar.avatarPlaceholder.classList.add("hidden")
      } else {
        sidebar.avatar.classList.add("hidden")
        sidebar.avatarPlaceholder.classList.remove("hidden")
        sidebar.avatarPlaceholder.textContent = (d.author || "?").slice(0, 1).toUpperCase()
      }

      const stats = []
      if (d.reaction_count > 0) stats.push(`❤️ ${d.reaction_count}`)
      if (d.boost_count > 0) stats.push(`🔄 ${d.boost_count}`)
      if (d.zap_amount > 0) stats.push(`⚡ ${d.zap_amount} sats`)
      sidebar.stats.textContent = stats.join("   ")
      sidebar.id.textContent = `event ${d.id.slice(0, 12)}…`
    }

    // Pin: render the full conversation thread in the sidebar. Each note
    // becomes a card (avatar, name, time, content with images, stats). The
    // clicked note gets a neon-green border so it's identifiable.
    this.graph.onNodePin = (thread, pinnedId) => {
      if (!sidebar.content) return
      sidebar.placeholder.classList.add("hidden")
      sidebar.single.classList.add("hidden")
      sidebar.thread.classList.remove("hidden")
      sidebar.thread.replaceChildren()

      for (const note of thread) {
        const card = document.createElement("div")
        card.className = "bg-dark-tertiary rounded-lg p-3 border"
        card.style.borderColor = (note.id === pinnedId) ? "#39ff14" : "var(--color-dark-border, #333)"

        // Author row
        const header = document.createElement("div")
        header.className = "flex items-center gap-2 mb-2"

        if (note.picture) {
          const avatar = document.createElement("img")
          avatar.src = note.picture
          avatar.referrerPolicy = "no-referrer"
          avatar.className = "w-7 h-7 rounded-full object-cover shrink-0"
          avatar.onerror = () => { avatar.replaceWith(makeInitial(note.author)) }
          header.appendChild(avatar)
        } else {
          header.appendChild(makeInitial(note.author))
        }

        const meta = document.createElement("div")
        meta.className = "min-w-0 flex-1"
        const name = document.createElement("div")
        name.className = "text-xs font-medium text-neon-green truncate"
        name.textContent = note.author || "unknown"
        const time = document.createElement("div")
        time.className = "text-xs text-text-secondary font-mono"
        time.textContent = note.created_at ? formatRelativeTime(note.created_at) : ""
        meta.appendChild(name)
        meta.appendChild(time)
        header.appendChild(meta)
        card.appendChild(header)

        // Content
        const body = document.createElement("div")
        body.className = "text-text-primary text-sm leading-relaxed whitespace-pre-wrap break-words space-y-2"
        renderNoteContent(body, note.content || "")
        card.appendChild(body)

        // Stats
        const stats = []
        if (note.reaction_count > 0) stats.push(`❤️ ${note.reaction_count}`)
        if (note.boost_count > 0) stats.push(`🔄 ${note.boost_count}`)
        if (note.zap_amount > 0) stats.push(`⚡ ${note.zap_amount} sats`)
        if (stats.length > 0) {
          const statsEl = document.createElement("div")
          statsEl.className = "flex items-center gap-4 text-xs text-text-muted mt-2"
          statsEl.textContent = stats.join("   ")
          card.appendChild(statsEl)
        }

        sidebar.thread.appendChild(card)
      }
    }

    this.graph.onNodeUnpin = () => {
      sidebar.thread.replaceChildren()
      sidebar.thread.classList.add("hidden")
      sidebar.single.classList.remove("hidden")
    }

    function makeInitial(author) {
      const el = document.createElement("div")
      el.className = "w-7 h-7 rounded-full bg-gradient-to-br from-neon-green to-neon-purple flex items-center justify-center text-dark-primary font-bold text-xs shrink-0"
      el.textContent = (author || "?").slice(0, 1).toUpperCase()
      return el
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

    // Profile arrivals (kind-0 backfill) fill in avatars/petnames live
    this.handleEvent("graph_profile_update", ({pubkey, author, picture}) => {
      this.graph.updateNodeProfile(pubkey, {author, picture})
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

// List view note bodies: the server renders the raw note text (safe
// fallback), then this hook re-renders it through renderNoteContent — the
// same transformation the graph sidebar uses — so links, images, wss chips
// and nostr entities are clickable in both views.
Hooks.NoteContent = {
  mounted() { this.enhance() },
  updated() { this.enhance() },
  enhance() {
    renderNoteContent(this.el, this.el.dataset.content || "")
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