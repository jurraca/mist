import * as d3 from "d3";
  
class NetworkGraph {
  constructor(containerId) {
    this.container = d3.select(containerId);
    this.width = 800;
    this.height = 800;
    this.svg = null;
    this.simulation = null;
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
  }

  render(data) {
    if (!this.svg) this.init();

    const { nodes, links } = this.processNotes(data);
    
    // Track existing nodes to identify new ones for shimmer effect
    const existingNodeIds = new Set(this.lastNodes ? this.lastNodes.map(n => n.id) : []);
    const newNodes = nodes.filter(n => !existingNodeIds.has(n.id));
    this.lastNodes = nodes;

    // Clear previous content
    this.svg.select("g").selectAll("*").remove();

    // Create force simulation
    this.simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id(d => d.id).distance(100))
      .force("charge", d3.forceManyBody().strength(-300))
      .force("center", d3.forceCenter(this.width / 2, this.height / 2));

    const g = this.svg.select("g");

    // Create links with uniform gray color
    const link = g.append("g")
      .selectAll("line")
      .data(links)
      .enter().append("line")
      .attr("stroke", "#999")
      .attr("stroke-opacity", 0.6)
      .attr("stroke-width", d => Math.sqrt(d.value));

    // Create nodes with zap borders  
    const nodeGroup = g.append("g")
      .selectAll("g")
      .data(nodes)
      .enter().append("g")
      .call(this.drag());

    // Zap border (outer ring) for nodes with zaps
    nodeGroup
      .filter(d => d.zap_amount > 0)
      .append("circle")
      .attr("r", d => Math.max(8, Math.min(24, 8 + Math.sqrt(d.count) * 2)))
      .attr("fill", "none")
      .attr("stroke", "#DAA520") // Burnished gold
      .attr("stroke-width", 3)
      .attr("opacity", 0.8);

    // Main node circle
    const node = nodeGroup
      .append("circle")
      .attr("r", d => Math.max(6, Math.min(20, 6 + Math.sqrt(d.count) * 2)))
      .attr("fill", d => this.getNodeColor(d))
      .attr("stroke", "#fff")
      .attr("stroke-width", 2);

    // Apply shimmer effect to new nodes
    nodeGroup
      .filter(d => newNodes.some(newNode => newNode.id === d.id))
      .classed("graph-node-shimmer", true)
      .transition()
      .delay(800) // Remove class after animation
      .duration(0)
      .on("end", function() {
        d3.select(this).classed("graph-node-shimmer", false);
      });

    // Add labels for notes
    const labels = g.append("g")
      .selectAll("text")
      .data(nodes.filter(d => d.type === 'note'))
      .enter().append("text")
      .text(d => d.content ? d.content.slice(0, 20) + '...' : d.id.slice(0, 8))
      .attr("font-size", "10px")
      .attr("dx", 15)
      .attr("dy", 4)
      .attr("fill", "#ccc");

    // Add tooltips for notes
    nodeGroup.append("title")
      .text(d => `${d.content || 'Note'}\nReactions: ${d.reaction_count}\nBoosts: ${d.boost_count}\nZaps: ${d.zap_amount} sats\nInteraction Score: ${d.count}`);

    // Update positions on tick
    this.simulation.on("tick", () => {
      link
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y);

      nodeGroup
        .attr("transform", d => `translate(${d.x},${d.y})`);

      labels
        .attr("x", d => d.x)
        .attr("y", d => d.y);
    });
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
      // Calculate total interaction score for sizing
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
    // Color based on interaction intensity
    if (node.count > 10) {
      return '#ff6b6b'; // Red for high interaction
    } else if (node.count > 5) {
      return '#ffb347'; // Orange for medium interaction
    } else if (node.count > 0) {
      return '#4ecdc4'; // Teal for some interaction
    } else {
      return '#95a5a6'; // Gray for no interaction
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

// Export for use in Phoenix LiveView
window.NetworkGraph = NetworkGraph;
