import * as d3 from "d3";

// Layout model: time-biased self-organization with trailing vines. The X
// axis is time — each conversation (connected component over reply links)
// gets a weak forceX pull toward its time-anchored x (left = new, right =
// old). Replies cascade left-and-down from the root by BFS depth, so
// conversations look like vines trailing from their root. Y is emergent from
// physics with a depth-based downward bias. A weak local charge spreads
// nearby nodes; forceCollide prevents overlap at any zoom. Edge lengths are
// time-weighted (instant reply → tight, delayed → loose). The simulation
// runs perpetually at a low alphaTarget so nodes gently float without ever
// freezing. Dragged nodes stay briefly then release back into the float.
// Node radii counter-scale with zoom (r/k) for constant hoverable screen size.

const PAD = 60;          // viewport padding (all sides)
const FLOAT_INTERVAL_MS = 60_000;
const FLOAT_ALPHA_TARGET = 0.04; // perpetual gentle motion
const VELOCITY_DECAY = 0.3;      // less friction = smoother glide, faster drift
const EDGE_DIST_MIN = 20;        // instant reply → 20px
const EDGE_DIST_MAX = 70;        // cap for very old replies
const COLLIDE_PAD = 6;           // extra spacing between nodes
const DRAG_RELEASE_MS = 3000;    // dragged nodes rejoin the float after 3s
const COMPONENT_PAD = 25;        // gap between conversation bounding circles
const COMPONENT_REPEL = 2.5;     // how hard overlapping clusters push apart
const TRAIL_X_BIAS = 15;         // per-depth leftward offset (replies trail left)
const TRAIL_Y_BIAS = 30;         // per-depth downward offset (replies cascade down)

class NetworkGraph {
  constructor(containerId) {
    this.container = d3.select(containerId);
    this.width = 0;
    this.height = 0;
    this.svg = null;
    this.root = null;
    this.zoom = null;
    this.simulation = null;
    this.nodes = [];
    this.links = [];
    this.nodeElements = null;
    this.linkElements = null;
    // Set by the LiveView hook: called with the hovered node's data so the
    // sidebar can display the full note (client-side, no server roundtrip).
    this.onNodeHover = null;
    this.onNodePin = null;
    this.onNodeUnpin = null;
    this.hoveredEl = null;
    this.hoveredNodeId = null;
    this.pinnedNodeId = null;
    // Once the user pans/zooms manually, stop auto-fitting the view.
    this.userInteracted = false;
    this.warmingUp = false;
    this.resizeObserver = null;
    // Time-axis layout state
    this.windowSeconds = 36 * 3600;
    this.compOf = {};      // nodeId -> component id
    this.compX = {};       // component id -> time-anchored x (gentle bias target)
    this.anchorOf = {};    // component id -> root node id (the pinned node)
    this.depthOf = {};     // nodeId -> BFS depth from its component's root
    this.zoomK = 1;
    this.floatTimer = null;
  }

  init() {
    const el = this.container.node();
    this.width = el.clientWidth || 800;
    this.height = el.clientHeight || 600;

    this.svg = this.container
      .append("svg")
      .attr("width", this.width)
      .attr("height", this.height);

    this.zoom = d3.zoom()
      .scaleExtent([0.1, 3])
      .on("start", (event) => {
        // Programmatic transforms have no sourceEvent.
        if (event.sourceEvent) this.userInteracted = true;
      })
      .on("zoom", (event) => {
        this.root.attr("transform", event.transform);
        this.zoomK = event.transform.k;
        this.applyNodeSizes();
      });

    this.svg.call(this.zoom);

    // Click on the SVG background (not a node) unpins the sidebar.
    this.svg.on("click", (event) => {
      if (event.target === this.svg.node() || event.target === this.root.node()) {
        this.unpinNode();
      }
    });

    // Main group that pan/zoom transforms apply to
    this.root = this.svg.append("g");

    // Time axis indicator (screen-space, not affected by pan/zoom).
    this.svg.append("text")
      .attr("x", 12)
      .attr("y", 20)
      .attr("fill", "rgba(255,255,255,0.25)")
      .attr("font-size", "11px")
      .attr("font-family", "monospace")
      .attr("pointer-events", "none")
      .text("← newest    oldest →");

    // Force simulation: time-biased self-organization. No forceCenter, no
    // global charge. forceX gives a gentle time-area bias; forceY is a
    // root-only whisper toward center. Local charge spreads nearby nodes;
    // collide prevents overlap; link shapes conversations internally.
    this.simulation = d3.forceSimulation([])
      .velocityDecay(VELOCITY_DECAY)
      .force("link", d3.forceLink([]).id(d => d.id).distance(l => this.edgeDistance(l)))
      .force("charge", d3.forceManyBody().strength(-20).distanceMax(120))
      .force("collide", d3.forceCollide(d => this.collideRadius(d)).iterations(2))
      .force("componentRepel", this.componentRepelForce())
      .force("x", d3.forceX(this.width / 2).strength(0.06))
      .force("y", d3.forceY(this.height / 2).strength(0.03));

    // Register the tick handler ONCE here. Selections are read dynamically
    // (this.*) so later renders don't need to re-register — registering per
    // render would accumulate stale handlers and multiply position updates.
    this.simulation.on("tick", () => this.syncPositions());

    this.root.append("g").attr("class", "links");
    this.root.append("g").attr("class", "nodes");

    // Shared circular clip path for profile pics (objectBoundingBox units
    // scale the clip to each image's bounding box — one clip for all nodes).
    this.svg.append("defs")
      .append("clipPath")
      .attr("id", "circle-clip")
      .attr("clipPathUnits", "objectBoundingBox")
      .append("circle")
      .attr("cx", 0.5)
      .attr("cy", 0.5)
      .attr("r", 0.5);

    // Keep the SVG sized to its container (graph mode fills the viewport).
    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(el);

    // The float: as time passes, conversations drift right along the axis.
    this.floatTimer = setInterval(() => this.float(), FLOAT_INTERVAL_MS);
  }

  baseRadius(d) {
    return Math.max(8, Math.min(24, 8 + Math.sqrt(d.count) * 2));
  }

  zapRadius(d) {
    return this.baseRadius(d) + 2;
  }

  // Collision radius in graph space — consistent with positions and edge
  // lengths so the visual graph is coherent at any zoom.
  collideRadius(d) {
    return this.baseRadius(d) + COLLIDE_PAD;
  }

  // Edge length weighted by the time gap between reply and parent:
  // instant reply → EDGE_DIST_MIN, logarithmic growth, capped at EDGE_DIST_MAX.
  // The reply is the link target (newer); the parent is the source (older).
  edgeDistance(link) {
    const s = link.source.created_at;
    const t = link.target.created_at;
    if (s == null || t == null) return 40;
    const dt = Math.max(0, t - s);
    return EDGE_DIST_MIN + Math.min(Math.log10(Math.max(1, dt)) * 15, EDGE_DIST_MAX - EDGE_DIST_MIN);
  }

  // Component-level collision: pushes overlapping conversation clusters
  // apart as rigid translations (all nodes in a component get the same
  // velocity delta), so internal structure is preserved. Each component's
  // bounding circle is its centroid + max node distance + padding.
  componentRepelForce() {
    const self = this;
    let nodes;

    function force(alpha) {
      if (!nodes || nodes.length === 0) return;

      const byComp = {};
      const bounds = {};

      for (const n of nodes) {
        const c = self.compOf[n.id];
        if (!c) continue;
        (byComp[c] = byComp[c] || []).push(n);
        if (!bounds[c]) bounds[c] = { sx: 0, sy: 0 };
        bounds[c].sx += n.x;
        bounds[c].sy += n.y;
      }

      const ids = Object.keys(bounds);
      if (ids.length < 2) return;

      // Centroids + bounding radii (max distance from centroid to any node)
      const centroids = {};
      for (const c of ids) {
        const members = byComp[c];
        const cx = bounds[c].sx / members.length;
        const cy = bounds[c].sy / members.length;
        let maxR = 30;
        for (const n of members) {
          const dx = n.x - cx, dy = n.y - cy;
          maxR = Math.max(maxR, Math.sqrt(dx * dx + dy * dy));
        }
        centroids[c] = { x: cx, y: cy, r: maxR + COMPONENT_PAD };
      }

      // Push overlapping pairs apart along their centroid axis
      for (let i = 0; i < ids.length; i++) {
        for (let j = i + 1; j < ids.length; j++) {
          const a = centroids[ids[i]];
          const b = centroids[ids[j]];
          const dx = b.x - a.x;
          const dy = b.y - a.y;
          const dist = Math.sqrt(dx * dx + dy * dy) || 1;
          const minDist = a.r + b.r;

          if (dist < minDist) {
            const overlap = minDist - dist;
            const push = overlap * alpha * COMPONENT_REPEL;
            const fx = (dx / dist) * push;
            const fy = (dy / dist) * push;

            // Rigid translation: same velocity to all nodes in each component
            for (const n of byComp[ids[i]]) { n.vx -= fx; n.vy -= fy; }
            for (const n of byComp[ids[j]]) { n.vx += fx; n.vy += fy; }
          }
        }
      }
    }

    force.initialize = function(n) { nodes = n; };
    return force;
  }

  // Decompose the graph into conversations (connected components over reply
  // links) and compute each one's time-anchored x.
  computeLayout() {
    const normalizeId = (val) => (typeof val === 'object' && val.id) ? val.id : val;

    // union-find
    const parent = {};
    const find = (x) => {
      while (parent[x] !== x) { parent[x] = parent[parent[x]]; x = parent[x]; }
      return x;
    };
    const union = (a, b) => {
      const ra = find(a), rb = find(b);
      if (ra !== rb) parent[ra] = rb;
    };

    this.nodes.forEach(n => { if (!(n.id in parent)) parent[n.id] = n.id; });
    this.links.forEach(l => union(normalizeId(l.source), normalizeId(l.target)));

    this.compOf = {};
    this.nodes.forEach(n => { this.compOf[n.id] = find(n.id); });

    // Anchor = first reply time: min created_at over notes that are the
    // reply side (link target) of an in-component edge. Fallback: min note
    // created_at (singletons from flat sources).
    const nodeById = new Map(this.nodes.map(n => [n.id, n]));
    const anchorReply = {};
    const anchorAny = {};

    this.links.forEach(l => {
      const target = nodeById.get(normalizeId(l.target));
      if (!target || target.created_at == null) return;
      const c = this.compOf[target.id];
      anchorReply[c] = Math.min(anchorReply[c] ?? Infinity, target.created_at);
    });

    this.nodes.forEach(n => {
      if (n.created_at == null) return;
      const c = this.compOf[n.id];
      anchorAny[c] = Math.min(anchorAny[c] ?? Infinity, n.created_at);
    });

    const now = Math.floor(Date.now() / 1000);
    this.compX = {};

    Object.keys(anchorAny).forEach(c => {
      const anchor = anchorReply[c] ?? anchorAny[c];
      const age = Math.max(0, now - anchor);
      const frac = Math.min(age / this.windowSeconds, 1);
      this.compX[c] = PAD + frac * Math.max(this.width - 2 * PAD, 1);
    });

    // The pinned node per conversation: the root (a note that parents
    // something but replies to nothing in-component). Fallback: oldest note.
    const isSource = {};
    const isTarget = {};
    this.links.forEach(l => {
      isSource[normalizeId(l.source)] = true;
      isTarget[normalizeId(l.target)] = true;
    });

    const rootOf = {};
    const rootTs = {};
    const oldestOf = {};
    this.nodes.forEach(n => {
      const c = this.compOf[n.id];
      const ts = n.created_at ?? Infinity;
      if (isSource[n.id] && !isTarget[n.id]) {
        if (!(c in rootTs) || ts < rootTs[c]) {
          rootOf[c] = n.id;
          rootTs[c] = ts;
        }
      }
      if (!(c in oldestOf) || ts < oldestOf[c].ts) {
        oldestOf[c] = { id: n.id, ts };
      }
    });

    this.anchorOf = {};
    Object.keys(oldestOf).forEach(c => {
      this.anchorOf[c] = rootOf[c] ?? oldestOf[c].id;
    });

    // BFS depth from each component's root over reply links. Depth gives
    // replies a left-down directional bias so conversations cascade like a
    // vine: root at top-right, replies trailing left and down.
    this.depthOf = {};
    const childrenOf = {};
    this.links.forEach(l => {
      const s = normalizeId(l.source), t = normalizeId(l.target);
      (childrenOf[s] = childrenOf[s] || []).push(t);
    });

    const visited = new Set();
    const queue = [];
    Object.values(this.anchorOf).forEach(rootId => {
      if (!visited.has(rootId)) {
        this.depthOf[rootId] = 0;
        visited.add(rootId);
        queue.push(rootId);
      }
    });

    let queueIdx = 0;
    while (queueIdx < queue.length) {
      const id = queue[queueIdx++];
      const depth = this.depthOf[id];
      for (const child of (childrenOf[id] || [])) {
        if (!visited.has(child)) {
          this.depthOf[child] = depth + 1;
          visited.add(child);
          queue.push(child);
        }
      }
    }

    // Nodes unreachable through directed BFS (malformed reply direction,
    // missing parent, cycles) get max depth in their component + 1 so they
    // don't land at root-level placement.
    const maxDepthByComp = {};
    for (const [id, depth] of Object.entries(this.depthOf)) {
      const c = this.compOf[id];
      maxDepthByComp[c] = Math.max(maxDepthByComp[c] ?? 0, depth);
    }
    this.nodes.forEach(n => {
      if (!(n.id in this.depthOf)) {
        const c = this.compOf[n.id];
        this.depthOf[n.id] = (maxDepthByComp[c] ?? 0) + 1;
      }
    });
  }

  // forceX/forceY: depth-based directional bias. The root sits at its
  // time-anchored x; each reply trails left and down by depth * bias, so
  // conversations cascade like a vine from top-right to bottom-left. The
  // pull is gentle (0.03) so physics still shapes the details.
  applyLayoutForces() {
    this.simulation.force("x",
      d3.forceX(d => {
        const compX = this.compX[this.compOf[d.id]] ?? this.width / 2;
        const depth = this.depthOf[d.id] || 0;
        return compX - depth * TRAIL_X_BIAS;
      }).strength(0.06));

    this.simulation.force("y",
      d3.forceY(d => {
        const depth = this.depthOf[d.id] || 0;
        return this.height / 2 + depth * TRAIL_Y_BIAS;
      }).strength(0.03));
  }

  // 60s heartbeat: ages advance, conversations glide right. Y is untouched —
  // any vertical motion comes out of the physics kick.
  float() {
    if (!this.simulation || !this.nodes.length) return;
    this.computeLayout();
    this.applyLayoutForces();
    this.simulation.alpha(0.05).restart();
  }

  syncPositions() {
    if (this.warmingUp || !this.nodeElements || !this.linkElements) return;

    this.linkElements
      .attr("d", d => {
        const sx = d.source.x, sy = d.source.y;
        const tx = d.target.x, ty = d.target.y;
        const mx = (sx + tx) / 2;
        const my = (sy + ty) / 2 + 10;
        return `M${sx},${sy} Q${mx},${my} ${tx},${ty}`;
      });

    this.nodeElements
      .attr("transform", d => `translate(${d.x},${d.y})`);
  }

  // Visible circles use graph-space radii (edges always longer than node
  // diameters at any zoom). An invisible hit circle on top is counter-scaled
  // (r/k) so nodes remain easy to hover/drag even when zoomed far out.
  applyNodeSizes() {
    if (!this.nodeElements) return;
    const k = this.zoomK || 1;

    this.nodeElements.select(".main-circle")
      .attr("r", d => this.baseRadius(d))
      .attr("stroke-width", 2);

    this.nodeElements.select(".zap-border")
      .attr("r", d => this.zapRadius(d))
      .attr("stroke-width", d => d.zap_amount > 0 ? 3 : 0);

    this.nodeElements.select(".hit-circle")
      .attr("r", d => (this.baseRadius(d) + 12) / k);

    const r = this.baseRadius;
    this.nodeElements.select(".profile-pic")
      .attr("x", d => -r(d))
      .attr("y", d => -r(d))
      .attr("width", d => r(d) * 2)
      .attr("height", d => r(d) * 2);
  }

  resize() {
    if (this._resizeDebounce) clearTimeout(this._resizeDebounce);
    this._resizeDebounce = setTimeout(() => this._doResize(), 150);
  }

  _doResize() {
    this._resizeDebounce = null;
    const el = this.container.node();
    const w = el.clientWidth;
    const h = el.clientHeight;
    if (!w || !h || (w === this.width && h === this.height)) return;

    this.width = w;
    this.height = h;
    this.svg.attr("width", w).attr("height", h);

    this.computeLayout();
    this.applyLayoutForces();
    this.simulation.alpha(0.1).restart();
  }

  // Scale/translate so every node is visible without manual panning.
  fitToView(animate = true) {
    if (!this.nodes.length || !this.width || !this.height) return;

    const minX = d3.min(this.nodes, d => d.x);
    const maxX = d3.max(this.nodes, d => d.x);
    const minY = d3.min(this.nodes, d => d.y);
    const maxY = d3.max(this.nodes, d => d.y);
    const w = Math.max(maxX - minX, 1);
    const h = Math.max(maxY - minY, 1);

    const [minK] = this.zoom.scaleExtent();
    const k = Math.max(minK, Math.min((this.width - 2 * PAD) / w, (this.height - 2 * PAD) / h, 1.25));
    const tx = this.width / 2 - k * (minX + w / 2);
    const ty = this.height / 2 - k * (minY + h / 2);
    const t = d3.zoomIdentity.translate(tx, ty).scale(k);

    if (animate) {
      this.svg.transition().duration(400).call(this.zoom.transform, t);
    } else {
      this.svg.call(this.zoom.transform, t);
    }
  }

  render(data) {
    if (!this.svg) this.init();

    if (data.window_seconds) this.windowSeconds = data.window_seconds;

    const { nodes, links } = this.processNotes(data);

    // Replace all data and rebuild
    this.nodes = nodes;
    this.links = links;

    // Full render = fresh start: clear stale pin/hover state so dangling
    // references don't block future interactions.
    this.pinnedNodeId = null;
    this.hoveredNodeId = null;
    this.hoveredEl = null;

    this.updateSimulation();
    this.computeLayout();
    this.applyLayoutForces();

    // Settle the layout synchronously (no DOM writes) so the first paint
    // already shows a stable arrangement that can be fitted to the viewport.
    if (this.nodes.length > 0) {
      this.warmingUp = true;
      this.simulation.alpha(1).stop();
      const iterations = Math.min(300, Math.max(100, this.nodes.length * 2));
      for (let i = 0; i < iterations; i++) this.simulation.tick();
      this.warmingUp = false;
    }

    this.updateVisualization();
    this.syncPositions();

    // Fresh data resets any previous manual pan/zoom.
    this.userInteracted = false;
    this.fitToView(false);

    // Perpetual gentle float: alpha decays to alphaTarget (not 0) so the
    // simulation never freezes — nodes keep oscillating around their
    // force-equilibrium positions, retaining configuration while floating.
    this.simulation.velocityDecay(VELOCITY_DECAY);
    this.simulation.alphaTarget(FLOAT_ALPHA_TARGET);
    this.simulation.alpha(0.2).restart();
  }

  updateIncremental(newData) {
    if (!this.svg) this.init();

    const { nodes: newNodes, links: newLinks } = this.processNotes(newData);

    // Normalize ID helper (same as in updateVisualization)
    const normalizeId = (val) => (typeof val === 'object' && val.id) ? val.id : val;

    // Track existing node IDs for shimmer effect
    const existingNodeIds = new Set(this.nodes.map(n => n.id));
    const addedNodes = [];

    // Add new nodes (avoid duplicates)
    newNodes.forEach(node => {
      if (!existingNodeIds.has(node.id)) {
        node.isNew = true; // Mark for shimmer effect
        this.nodes.push(node);
        addedNodes.push(node);
      }
    });

    // Add new links (avoid duplicates) - normalize IDs for comparison
    newLinks.forEach(link => {
      const linkSourceId = normalizeId(link.source);
      const linkTargetId = normalizeId(link.target);

      const isDuplicate = this.links.find(l =>
        normalizeId(l.source) === linkSourceId &&
        normalizeId(l.target) === linkTargetId
      );

      if (!isDuplicate) {
        this.links.push(link);
      }
    });

    // Compute layout BEFORE binding to the simulation so new nodes can be
    // placed at their conversation's position instead of d3's default
    // phyllotaxis scatter around the origin.
    this.computeLayout();

    addedNodes.forEach(node => {
      if (node.x == null) {
        const comp = this.compOf[node.id];
        const depth = this.depthOf[node.id] || 0;
        const compX = this.compX[comp] ?? this.width / 2;
        node.x = (compX - depth * TRAIL_X_BIAS) + (Math.random() - 0.5) * 60;
        node.y = (this.height / 2 + depth * TRAIL_Y_BIAS) + (Math.random() - 0.5) * 80;
      }
    });

    // Update simulation and visualization incrementally
    this.updateSimulation();
    this.applyLayoutForces();
    this.updateVisualization();

    // Nudge alpha up to accommodate new nodes, then settle back to float
    this.simulation.alphaTarget(FLOAT_ALPHA_TARGET);
    this.simulation.alpha(0.5).restart();
  }

  updateSimulation() {
    // Update simulation nodes and links
    this.simulation.nodes(this.nodes);
    this.simulation.force("link").links(this.links);
  }

  updateNodeCounts(note_id, counts) {
    const node = this.nodes.find(n => n.id === note_id);
    if (node) {
      Object.assign(node, counts);
      node.count = (node.reaction_count || 0) + (node.boost_count || 0) + Math.floor((node.zap_amount || 0) / 1000);

      this.updateVisualization();
      this.simulation.force("collide").initialize(this.simulation.nodes());
      this.simulation.alpha(0.1).restart();
    }
  }

  updateVisualization() {
    // Normalize link IDs for consistent keying (D3 mutates source/target to objects)
    const normalizeId = (val) => (typeof val === 'object' && val.id) ? val.id : val;

    // Update links using enter/update/exit pattern
    const linkSelection = this.root.select(".links")
      .selectAll("path")
      .data(this.links, d => `${normalizeId(d.source)}-${normalizeId(d.target)}`);

    // Remove old links
    linkSelection.exit().remove();

    // Add new links
    const linkEnter = linkSelection.enter().append("path")
      .attr("fill", "none")
      .attr("stroke", "#999")
      .attr("stroke-opacity", 0.6)
      .attr("stroke-width", d => Math.sqrt(d.value || 1));

    // Update existing + new links
    this.linkElements = linkEnter.merge(linkSelection);

    // Update nodes using enter/update/exit pattern
    const nodeSelection = this.root.select(".nodes")
      .selectAll("g")
      .data(this.nodes, d => d.id);

    // Remove old nodes
    nodeSelection.exit().remove();

    if (this.hoveredEl && !this.hoveredEl.node()?.isConnected) {
      this.hoveredEl = null;
    }

    // Add new nodes
    const nodeEnter = nodeSelection.enter().append("g")
      .call(this.drag())
      .on("mouseenter", (event, d) => this.highlight(event.currentTarget, d))
      .on("mouseleave", (event, d) => this.unhighlight(d))
      .on("click", (event, d) => {
        event.stopPropagation();
        if (!d._dragged) this.pinNode(d);
        d._dragged = false;
      });

    // Initialize main circle for new nodes
    nodeEnter.append("circle")
      .attr("class", "main-circle");

    // Initialize zap border circle for new nodes
    nodeEnter.append("circle")
      .attr("class", "zap-border");

    // Profile pic: clipped to a circle, sits on top of main-circle. Hidden
    // when no picture URL or on image load failure (falls back to colored circle).
    nodeEnter.append("image")
      .attr("class", "profile-pic")
      .attr("clip-path", "url(#circle-clip)")
      .attr("preserveAspectRatio", "xMidYMid slice")
      .attr("width", 0)
      .attr("height", 0)
      .attr("href", d => d.picture || "")
      .style("display", d => d.picture ? null : "none")
      .on("error", function(event, d) {
        d3.select(this).style("display", "none");
        d._pic_failed = true;
      });

    // Invisible hit circle on top: counter-scaled for easy hover/drag at any
    // zoom. pointer-events:all so it captures mouse events; fill:transparent
    // so it's never seen.
    nodeEnter.append("circle")
      .attr("class", "hit-circle")
      .attr("fill", "transparent")
      .attr("pointer-events", "all");

    // Update existing + new nodes
    this.nodeElements = nodeEnter.merge(nodeSelection);

    // Nodes with a loaded profile pic show the image instead of a colored fill;
    // the main-circle becomes a thin border (purple for roots, white otherwise).
    this.nodeElements.select(".main-circle")
      .attr("fill", d => (d.picture && !d._pic_failed) ? "transparent" : this.getNodeColor(d))
      .attr("stroke", d => this.anchorOf[this.compOf[d.id]] === d.id ? "#8b5cf6" : "#fff");

    this.nodeElements.select(".profile-pic")
      .attr("href", d => (d.picture && !d._pic_failed) ? d.picture : "")
      .style("display", d => (d.picture && !d._pic_failed) ? null : "none");

    this.nodeElements.select(".zap-border")
      .attr("fill", "none")
      .attr("stroke", d => d.zap_amount > 0 ? "#DAA520" : "none")
      .attr("opacity", d => d.zap_amount > 0 ? 0.8 : 0);

    this.applyNodeSizes();

    // Apply shimmer effect to new nodes
    nodeEnter
      .filter(d => d.isNew)
      .classed("graph-node-shimmer", true)
      .transition()
      .delay(800)
      .duration(0)
      .on("end", function() {
        d3.select(this).classed("graph-node-shimmer", false);
      });

    // Clear isNew flag after shimmer
    this.nodes.forEach(n => n.isNew = false);
  }

  highlight(el, d) {
    if (this.hoveredEl) {
      this.hoveredEl.select(".main-circle")
        .attr("stroke", "#fff")
        .attr("stroke-width", 2);
    }

    const node = d3.select(el);
    node.select(".main-circle")
      .attr("stroke", "#39ff14")
      .attr("stroke-width", 3);
    node.raise();

    this.hoveredEl = node;
    this.hoveredNodeId = d.id;

    // When a node is pinned, keep visual highlight but don't update the
    // sidebar — the thread view stays until the user clicks the background.
    if (!this.pinnedNodeId && this.onNodeHover) this.onNodeHover(d);
  }

  unhighlight(d) {
    if (this.pinnedNodeId === d.id) return;
    if (this.hoveredEl) {
      const isRoot = this.anchorOf[this.compOf[d.id]] === d.id;
      this.hoveredEl.select(".main-circle")
        .attr("stroke", isRoot ? "#8b5cf6" : "#fff")
        .attr("stroke-width", 2);
    }
    this.hoveredEl = null;
    this.hoveredNodeId = null;
  }

  // Pin a node: collect all nodes in its conversation component (sorted by
  // time) and hand them to the hook for thread rendering.
  pinNode(d) {
    this.pinnedNodeId = d.id;

    const comp = this.compOf[d.id];
    const thread = this.nodes
      .filter(n => this.compOf[n.id] === comp)
      .sort((a, b) => (a.created_at || 0) - (b.created_at || 0));

    if (this.onNodePin) this.onNodePin(thread, d.id);
  }

  unpinNode() {
    if (!this.pinnedNodeId) return;
    if (this.nodeElements) {
      const pid = this.pinnedNodeId;
      const isRoot = this.anchorOf[this.compOf[pid]] === pid;
      this.nodeElements.filter(d => d.id === pid)
        .select(".main-circle")
        .attr("stroke", isRoot ? "#8b5cf6" : "#fff")
        .attr("stroke-width", 2);
    }
    this.pinnedNodeId = null;
    if (this.onNodeUnpin) this.onNodeUnpin();
  }

  // Merge arriving profile data (kind 0) into every node by this pubkey and
  // refresh the sidebar if it's currently showing one of them.
  updateNodeProfile(pubkey, profile) {
    let hovered = null;

    this.nodes.forEach(n => {
      if (n.pubkey === pubkey) {
        if (profile.author) n.author = profile.author;
        if (profile.picture) { n.picture = profile.picture; n._pic_failed = false; }
        if (this.hoveredNodeId === n.id) hovered = n;
      }
    });

    if (this.nodeElements) {
      const sel = this.nodeElements.filter(n => n.pubkey === pubkey);
      sel.select(".profile-pic")
        .attr("href", n => (n.picture && !n._pic_failed) ? n.picture : "")
        .style("display", n => (n.picture && !n._pic_failed) ? null : "none");
      sel.select(".main-circle")
        .attr("fill", n => (n.picture && !n._pic_failed) ? "transparent" : this.getNodeColor(n));
    }

    if (hovered && this.onNodeHover) this.onNodeHover(hovered);
  }

  processNotes(data) {
    const nodes = data.nodes.map(node => ({
      id: node.id,
      type: node.type || 'note',
      content: node.content,
      author: node.author,
      picture: node.picture,
      pubkey: node.pubkey,
      created_at: node.created_at,
      reaction_count: node.reaction_count || 0,
      boost_count: node.boost_count || 0,
      zap_amount: node.zap_amount || 0,
      count: (node.reaction_count || 0) + (node.boost_count || 0) + Math.floor((node.zap_amount || 0) / 1000)
    }));

    const links = data.links.map(link => ({
      source: link.source,
      target: link.target,
      type: link.type || 'reply',
      value: 1
    }));

    return { nodes, links };
  }

  getNodeColor(node) {
    // Conversation roots (the time-anchored nodes) are purple; every other
    // node uses the activity heat ladder.
    if (this.anchorOf[this.compOf[node.id]] === node.id) return '#8b5cf6';

    if (node.count > 10) {
      return '#ff6b6b';
    } else if (node.count > 5) {
      return '#ffb347';
    } else if (node.count > 0) {
      return '#4ecdc4';
    } else {
      return '#95a5a6';
    }
  }

  drag() {
    return d3.drag()
      .on("start", (event, d) => {
        // Cancel any pending release from a previous drag
        if (d._releaseTimer) { clearTimeout(d._releaseTimer); d._releaseTimer = null; }
        if (!event.active) this.simulation.alphaTarget(0.3).restart();
        d.fx = d.x;
        d.fy = d.y;
      })
      .on("drag", (event, d) => {
        d.fx = event.x;
        d.fy = event.y;
        d._dragged = true;
      })
      .on("end", (event, d) => {
        // Release the node back into the float after a short delay — it
        // stays where dropped, then slowly drifts toward force equilibrium.
        if (!event.active) this.simulation.alphaTarget(FLOAT_ALPHA_TARGET);
        if (d._releaseTimer) clearTimeout(d._releaseTimer);
        d._releaseTimer = setTimeout(() => {
          d.fx = null;
          d.fy = null;
          d._releaseTimer = null;
        }, DRAG_RELEASE_MS);
      });
  }

  destroy() {
    if (this.floatTimer) {
      clearInterval(this.floatTimer);
      this.floatTimer = null;
    }
    if (this._resizeDebounce) {
      clearTimeout(this._resizeDebounce);
      this._resizeDebounce = null;
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }
    if (this.simulation) {
      this.simulation.stop();
      this.simulation = null;
    }
    if (this.nodes) {
      for (const n of this.nodes) {
        if (n._releaseTimer) clearTimeout(n._releaseTimer);
      }
    }
    if (this.container) {
      this.container.select("svg").remove();
    }
  }
}

window.NetworkGraph = NetworkGraph;
