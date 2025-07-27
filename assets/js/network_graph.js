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

    // Create nodes
    const node = g.append("g")
      .selectAll("circle")
      .data(nodes)
      .enter().append("circle")
      .attr("r", d => Math.max(6, Math.min(20, 6 + Math.sqrt(d.count) * 2)))
      .attr("fill", d => this.getNodeColor(d))
      .attr("stroke", "#fff")
      .attr("stroke-width", 2)
      .call(this.drag());

    // Add labels
    const labels = g.append("g")
      .selectAll("text")
      .data(nodes)
      .enter().append("text")
      .text(d => `AS${d.id}`)
      .attr("font-size", "12px")
      .attr("dx", 15)
      .attr("dy", 4);

    // Add tooltips
    node.append("title")
      .text(d => {
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

      node
        .attr("cx", d => d.x)
        .attr("cy", d => d.y);

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
      count: 1 // For sizing
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
