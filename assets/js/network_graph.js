import * as d3 from "d3";

// Layout model: the X axis is time. Each conversation (a connected component
// over reply links) is anchored by the time of its FIRST reply and its ROOT
// note is pinned at x = pad + age/window * (width - 2*pad): new conversations
// emerge on the left and float right as they age (60s heartbeat). The anchor
// time comes from event data (min reply created_at), so later replies never
// pull a conversation back left. Only the root is pinned — every other node
// floats freely, shaped by link/charge/collision physics with just a faint
// pull toward the conversation's anchor. The Y axis is deliberately
// measureless: vertical arrangement emerges from physics, with a whisper-weak
// per-component "home height" nudge on roots only, to keep the full
// rectangle in use over long sessions. Node radii counter-scale with zoom
// (r/k) so nodes keep a constant, hoverable screen size at any zoom level.

const PAD = 60;
const FLOAT_INTERVAL_MS = 60_000;

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
    this.hoveredEl = null;
    // Once the user pans/zooms manually, stop auto-fitting the view.
    this.userInteracted = false;
    this.warmingUp = false;
    this.resizeObserver = null;
    // Time-axis layout state
    this.windowSeconds = 24 * 3600;
    this.compOf = {};   // nodeId -> component id
    this.compX = {};    // component id -> time-anchored x target
    this.homeY = {};    // component id -> stable pseudo-random home height
    this.anchorOf = {}; // component id -> root node id (the pinned node)
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

    // Main group that pan/zoom transforms apply to
    this.root = this.svg.append("g");

    // Force simulation (empty at first). No forceCenter: x is time-anchored
    // per conversation, y is left to physics.
    this.simulation = d3.forceSimulation([])
      .force("link", d3.forceLink([]).id(d => d.id).distance(80))
      .force("charge", d3.forceManyBody().strength(-40).distanceMax(250))
      .force("collide", d3.forceCollide(d => this.baseRadius(d) + 3))
      .force("x", d3.forceX(this.width / 2).strength(0.4))
      .force("y", d3.forceY(this.height / 2).strength(0.03));

    // Register the tick handler ONCE here. Selections are read dynamically
    // (this.*) so later renders don't need to re-register — registering per
    // render would accumulate stale handlers and multiply position updates.
    this.simulation.on("tick", () => this.syncPositions());

    this.root.append("g").attr("class", "links");
    this.root.append("g").attr("class", "nodes");

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

  // FNV-1a hash -> [0, 1): stable per-component pseudo-random home height.
  hashUnit(str) {
    let h = 2166136261;
    for (let i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return ((h >>> 0) % 10000) / 10000;
  }

  // Decompose the graph into conversations (connected components over reply
  // links) and compute each one's time-anchored x target and home height.
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
    this.homeY = {};

    Object.keys(anchorAny).forEach(c => {
      const anchor = anchorReply[c] ?? anchorAny[c];
      const age = Math.max(0, now - anchor);
      const frac = Math.min(age / this.windowSeconds, 1);
      this.compX[c] = PAD + frac * Math.max(this.width - 2 * PAD, 1);
      this.homeY[c] = PAD + this.hashUnit(c) * Math.max(this.height - 2 * PAD, 1);
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
    const oldestOf = {};
    this.nodes.forEach(n => {
      const c = this.compOf[n.id];
      if (isSource[n.id] && !isTarget[n.id] && !(c in rootOf)) rootOf[c] = n.id;
      if (!(c in oldestOf) || (n.created_at ?? Infinity) < oldestOf[c].ts) {
        oldestOf[c] = { id: n.id, ts: n.created_at ?? Infinity };
      }
    });

    this.anchorOf = {};
    Object.keys(oldestOf).forEach(c => {
      this.anchorOf[c] = rootOf[c] ?? oldestOf[c].id;
    });
  }

  // Only each conversation's root is pinned to the time axis (and given the
  // faintest home-height nudge); all other nodes get a mere whisper of pull
  // toward the conversation anchor so deep threads stay loosely associated
  // without forming lanes.
  applyLayoutForces() {
    const isAnchor = (d) => this.anchorOf[this.compOf[d.id]] === d.id;

    this.simulation.force("x",
      d3.forceX(d => this.compX[this.compOf[d.id]] ?? this.width / 2)
        .strength(d => isAnchor(d) ? 0.5 : 0.05));
    this.simulation.force("y",
      d3.forceY(d => this.homeY[this.compOf[d.id]] ?? this.height / 2)
        .strength(d => isAnchor(d) ? 0.05 : 0));
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
      .attr("x1", d => d.source.x)
      .attr("y1", d => d.source.y)
      .attr("x2", d => d.target.x)
      .attr("y2", d => d.target.y);

    this.nodeElements
      .attr("transform", d => `translate(${d.x},${d.y})`);
  }

  // Counter-scale radii and strokes by the zoom level so nodes keep a
  // constant, hoverable screen size no matter how far the graph zooms out.
  applyNodeSizes() {
    if (!this.nodeElements) return;
    const k = this.zoomK || 1;

    this.nodeElements.select(".main-circle")
      .attr("r", d => this.baseRadius(d) / k)
      .attr("stroke-width", 2 / k);

    this.nodeElements.select(".zap-border")
      .attr("r", d => this.zapRadius(d) / k)
      .attr("stroke-width", d => d.zap_amount > 0 ? 3 / k : 0);
  }

  resize() {
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

    if (!this.userInteracted) this.fitToView(false);
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

    // Keep a low simmer so live arrivals ease into place.
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
        node.x = (this.compX[comp] ?? this.width / 2) + (Math.random() - 0.5) * 40;
        node.y = (this.homeY[comp] ?? this.height / 2) + (Math.random() - 0.5) * 80;
      }
    });

    // Update simulation and visualization incrementally
    this.updateSimulation();
    this.applyLayoutForces();
    this.updateVisualization();

    // Restart simulation with heat to accommodate new nodes
    this.simulation.alpha(0.5).restart();
  }

  updateSimulation() {
    // Update simulation nodes and links
    this.simulation.nodes(this.nodes);
    this.simulation.force("link").links(this.links);
  }

  updateNodeCounts(note_id, counts) {
    // Find and update the node with new counts
    const node = this.nodes.find(n => n.id === note_id);
    if (node) {
      Object.assign(node, counts);
      // Recalculate interaction count
      node.count = (node.reaction_count || 0) + (node.boost_count || 0) + Math.floor((node.zap_amount || 0) / 1000);

      // Update visualization (re-bind data to update radii, colors)
      this.updateVisualization();
    }
  }

  updateVisualization() {
    // Normalize link IDs for consistent keying (D3 mutates source/target to objects)
    const normalizeId = (val) => (typeof val === 'object' && val.id) ? val.id : val;

    // Update links using enter/update/exit pattern
    const linkSelection = this.root.select(".links")
      .selectAll("line")
      .data(this.links, d => `${normalizeId(d.source)}-${normalizeId(d.target)}`);

    // Remove old links
    linkSelection.exit().remove();

    // Add new links
    const linkEnter = linkSelection.enter().append("line")
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
      .on("mouseenter", (event, d) => this.highlight(event.currentTarget, d));

    // Initialize main circle for new nodes
    nodeEnter.append("circle")
      .attr("class", "main-circle");

    // Initialize zap border circle for new nodes
    nodeEnter.append("circle")
      .attr("class", "zap-border");

    // Update existing + new nodes
    this.nodeElements = nodeEnter.merge(nodeSelection);

    // Update colors for all nodes; radii/strokes are zoom counter-scaled
    this.nodeElements.select(".main-circle")
      .attr("fill", d => this.getNodeColor(d))
      .attr("stroke", "#fff");

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
    const k = this.zoomK || 1;

    if (this.hoveredEl) {
      this.hoveredEl.select(".main-circle")
        .attr("stroke", "#fff")
        .attr("stroke-width", 2 / k);
    }

    const node = d3.select(el);
    node.select(".main-circle")
      .attr("stroke", "#39ff14")
      .attr("stroke-width", 3 / k);
    node.raise();

    this.hoveredEl = node;
    if (this.onNodeHover) this.onNodeHover(d);
  }

  processNotes(data) {
    const nodes = data.nodes.map(node => ({
      id: node.id,
      type: node.type || 'note',
      content: node.content,
      author: node.author,
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
        if (!event.active) this.simulation.alphaTarget(0.3).restart();
        d.fx = d.x;
        d.fy = d.y;
      })
      .on("drag", (event, d) => {
        d.fx = event.x;
        d.fy = event.y;
      })
      .on("end", (event, d) => {
        if (!event.active) this.simulation.alphaTarget(0);
        d.fx = null;
        d.fy = null;
      });
  }

  destroy() {
    if (this.floatTimer) {
      clearInterval(this.floatTimer);
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    if (this.simulation) {
      this.simulation.stop();
    }
    if (this.container) {
      this.container.select("svg").remove();
    }
  }
}

window.NetworkGraph = NetworkGraph;
