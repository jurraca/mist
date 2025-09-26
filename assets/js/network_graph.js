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

    // Handle both transfer data (legacy) and note data
    const { nodes, links } = data.nodes ? this.processNotes(data) : this.processTransfers(data);
    
    // Track existing nodes to identify new ones for shimmer effect
    const existingNodeIds = new Set(this.lastNodes ? this.lastNodes.map(n => n.id) : []);
    const newNodes = nodes.filter(n => !existingNodeIds.has(n.id));
    this.lastNodes = nodes;

    // Clear previous content
    this.svg.select("g").selectAll("*").remove();

    // Create force simulation with positioning forces
    this.simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id(d => d.id).distance(100))
      .force("charge", d3.forceManyBody().strength(-300))
      .force("center", d3.forceCenter(this.width / 2, this.height / 2).strength(0.05))
      .force("x", d3.forceX().x(d => {
        // Position nodes based on type
        switch(d.type) {
          case 'outgoing_only':
            return this.width * 0.25; // Left quarter
          case 'incoming_only':
            return this.width * 0.75; // Right quarter
          case 'both':
            return this.width * 0.5; // Center
          default:
            return this.width * 0.5;
        }
      }).strength(0.2))
      .force("y", d3.forceY().y(this.height / 2).strength(0.05));

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
      .text(d => {
        if (d.type === 'note') {
          return `${d.content || 'Note'}\nReactions: ${d.reaction_count}\nBoosts: ${d.boost_count}\nZaps: ${d.zap_amount} sats\nInteraction Score: ${d.count}`;
        } else {
          let typeDescription;
          switch(d.type) {
            case 'outgoing_only':
              typeDescription = 'Outgoing only';
              break;
            case 'incoming_only':
              typeDescription = 'Incoming only';
              break;
            case 'both':
              typeDescription = `Both directions (${Math.round(d.ratio * 100)}% outgoing)`;
              break;
            default:
              typeDescription = 'Unknown';
          }
          return `AS${d.id}\nType: ${typeDescription}\nOutgoing: ${d.outgoing}\nIncoming: ${d.incoming}\nTotal: ${d.count}`;
        }
      });

    link.append("title")
      .text(d => `Network: ${d.network}\nTransfer: AS${d.source.id} → AS${d.target.id}\nDate: ${new Date(d.date).toLocaleDateString()}`);

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

  processTransfers(transfers) {
    const nodeStats = new Map();
    const links = [];

    // First pass: collect statistics for each node
    transfers.forEach(transfer => {
      // Initialize node stats if not exists
      if (!nodeStats.has(transfer.from_asn)) {
        nodeStats.set(transfer.from_asn, {
          id: transfer.from_asn,
          outgoing: 0,
          incoming: 0,
          totalCount: 0
        });
      }
      if (!nodeStats.has(transfer.to_asn)) {
        nodeStats.set(transfer.to_asn, {
          id: transfer.to_asn,
          outgoing: 0,
          incoming: 0,
          totalCount: 0
        });
      }

      // Update statistics
      nodeStats.get(transfer.from_asn).outgoing++;
      nodeStats.get(transfer.from_asn).totalCount++;
      nodeStats.get(transfer.to_asn).incoming++;
      nodeStats.get(transfer.to_asn).totalCount++;

      // Add links
      links.push({
        source: transfer.from_asn,
        target: transfer.to_asn,
        network: transfer.network,
        value: 1,
        date: transfer.transfer_date
      });
    });

    // Second pass: determine node types and create final nodes
    const nodes = Array.from(nodeStats.values()).map(stat => {
      let type;
      let ratio = 0;

      if (stat.outgoing > 0 && stat.incoming === 0) {
        type = 'outgoing_only';
      } else if (stat.incoming > 0 && stat.outgoing === 0) {
        type = 'incoming_only';
      } else {
        type = 'both';
        // Calculate ratio for purple scaling (0 = all incoming, 1 = all outgoing)
        ratio = stat.outgoing / (stat.outgoing + stat.incoming);
      }

      return {
        id: stat.id,
        type: type,
        count: stat.totalCount,
        outgoing: stat.outgoing,
        incoming: stat.incoming,
        ratio: ratio
      };
    });

    return {
      nodes: nodes,
      links: links
    };
  }

  getNodeColor(node) {
    switch(node.type) {
      case 'note':
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
      case 'outgoing_only':
        return '#ff6b6b'; // Red for outgoing only
      case 'incoming_only':
        return '#4ecdc4'; // Green for incoming only
      case 'both':
        // Purple with varying intensity based on ratio
        // ratio closer to 0 = more green-ish purple (more incoming)
        // ratio closer to 1 = more red-ish purple (more outgoing)
        const redComponent = Math.floor(128 + (node.ratio * 127)); // 128-255
        const greenComponent = Math.floor(64 + ((1 - node.ratio) * 64)); // 64-128
        const blueComponent = Math.floor(128 + (64 * Math.abs(0.5 - node.ratio))); // 128-160
        return `rgb(${redComponent}, ${greenComponent}, ${blueComponent})`;
      default:
        return '#999';
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
