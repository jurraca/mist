import * as d3 from "d3";
  
class NetworkGraph {
  constructor(containerId) {
    this.container = d3.select(containerId);
    this.width = 800;
    this.height = 800;
    this.svg = null;
    this.simulation = null;
    this.nodes = [];
    this.links = [];
    this.nodeElements = null;
    this.linkElements = null;
    this.labelElements = null;
  }

  init() {
    this.svg = this.container
      .append("svg")
      .attr("width", this.width)
      .attr("height", this.height);

    const zoom = d3.zoom()
      .scaleExtent([0.1, 3])
      .on("zoom", (event) => {
        this.svg.select("g").attr("transform", event.transform);
      });

    this.svg.call(zoom);

    // Create main group
    this.svg.append("g");

    // Initialize force simulation (empty at first)
    this.simulation = d3.forceSimulation([])
      .force("link", d3.forceLink([]).id(d => d.id).distance(100))
      .force("charge", d3.forceManyBody().strength(-300))
      .force("center", d3.forceCenter(this.width / 2, this.height / 2));

    // Register the tick handler ONCE here. Selections are read dynamically
    // (this.*) so later renders don't need to re-register — registering per
    // render would accumulate stale handlers and multiply position updates.
    this.simulation.on("tick", () => {
      if (!this.nodeElements || !this.linkElements) return;

      this.linkElements
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y);

      this.nodeElements
        .attr("transform", d => `translate(${d.x},${d.y})`);

      if (this.labelElements) {
        this.labelElements
          .attr("x", d => d.x)
          .attr("y", d => d.y);
      }
    });

    // Create empty link and node groups
    this.svg.select("g").append("g").attr("class", "links");
    this.svg.select("g").append("g").attr("class", "nodes");
    this.svg.select("g").append("g").attr("class", "labels");
  }

  render(data) {
    if (!this.svg) this.init();

    const { nodes, links } = this.processNotes(data);
    
    // Replace all data and rebuild
    this.nodes = nodes;
    this.links = links;
    
    this.updateSimulation();
    this.updateVisualization();
  }

  updateIncremental(newData) {
    if (!this.svg) this.init();

    const { nodes: newNodes, links: newLinks } = this.processNotes(newData);
    
    // Normalize ID helper (same as in updateVisualization)
    const normalizeId = (val) => (typeof val === 'object' && val.id) ? val.id : val;
    
    // Track existing node IDs for shimmer effect
    const existingNodeIds = new Set(this.nodes.map(n => n.id));
    
    // Add new nodes (avoid duplicates)
    newNodes.forEach(node => {
      if (!this.nodes.find(n => n.id === node.id)) {
        node.isNew = true; // Mark for shimmer effect
        this.nodes.push(node);
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

    // Update simulation and visualization incrementally
    this.updateSimulation();
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
      
      // Update visualization (re-bind data to update radii, colors, tooltips)
      this.updateVisualization();
    }
  }

  updateVisualization() {
    const g = this.svg.select("g");

    // Normalize link IDs for consistent keying (D3 mutates source/target to objects)
    const normalizeId = (val) => (typeof val === 'object' && val.id) ? val.id : val;

    // Update links using enter/update/exit pattern
    const linkSelection = g.select(".links")
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
    const nodeSelection = g.select(".nodes")
      .selectAll("g")
      .data(this.nodes, d => d.id);

    // Remove old nodes
    nodeSelection.exit().remove();

    // Add new nodes
    const nodeEnter = nodeSelection.enter().append("g")
      .call(this.drag());

    // Initialize main circle for new nodes
    nodeEnter.append("circle")
      .attr("class", "main-circle");

    // Initialize zap border circle for new nodes
    nodeEnter.append("circle")
      .attr("class", "zap-border");

    // Initialize tooltip for new nodes
    nodeEnter.append("title");

    // Update existing + new nodes
    this.nodeElements = nodeEnter.merge(nodeSelection);

    // Update main circle attributes for all nodes
    this.nodeElements.select(".main-circle")
      .attr("r", d => Math.max(6, Math.min(20, 6 + Math.sqrt(d.count) * 2)))
      .attr("fill", d => this.getNodeColor(d))
      .attr("stroke", "#fff")
      .attr("stroke-width", 2);

    // Update zap border for all nodes
    this.nodeElements.select(".zap-border")
      .attr("r", d => Math.max(8, Math.min(24, 8 + Math.sqrt(d.count) * 2)))
      .attr("fill", "none")
      .attr("stroke", d => d.zap_amount > 0 ? "#DAA520" : "none")
      .attr("stroke-width", d => d.zap_amount > 0 ? 3 : 0)
      .attr("opacity", d => d.zap_amount > 0 ? 0.8 : 0);

    // Update tooltips for all nodes
    this.nodeElements.select("title")
      .text(d => `${d.content || 'Note'}\nReactions: ${d.reaction_count}\nBoosts: ${d.boost_count}\nZaps: ${d.zap_amount} sats\nInteraction Score: ${d.count}`);

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

    // Update existing + new nodes
    this.nodeElements = nodeEnter.merge(nodeSelection);

    // Update labels using enter/update/exit pattern
    const labelData = this.nodes.filter(d => d.type === 'note');
    const labelSelection = g.select(".labels")
      .selectAll("text")
      .data(labelData, d => d.id);

    // Remove old labels
    labelSelection.exit().remove();

    // Add new labels
    const labelEnter = labelSelection.enter().append("text")
      .text(d => d.content ? d.content.slice(0, 20) + '...' : d.id.slice(0, 8))
      .attr("font-size", "10px")
      .attr("dx", 15)
      .attr("dy", 4)
      .attr("fill", "#ccc");

    // Update existing + new labels
    this.labelElements = labelEnter.merge(labelSelection);
  }

  processNotes(data) {
    const nodes = data.nodes.map(node => ({
      id: node.id,
      type: node.type || 'note',
      content: node.content,
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
    if (this.simulation) {
      this.simulation.stop();
    }
    if (this.container) {
      this.container.select("svg").remove();
    }
  }
}

window.NetworkGraph = NetworkGraph;
