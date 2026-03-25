# Overview

Mist is a Phoenix LiveView application that provides a browser-based interface for interacting with the Nostr protocol. It serves as a bridge between web browsers and Nostr relays, enabling users to send messages, subscribe to events, and visualize network relationships through an interactive graph interface. The application is built using Elixir/Phoenix with a focus on real-time communication and data visualization.

# User Preferences

Preferred communication style: Simple, everyday language.

# System Architecture

## Backend Architecture
The application follows a modular Phoenix architecture with several key components:

- **Signer Module**: Handles Nostr identity management by deriving public keys from private keys stored in the `NOSTR_PRIVKEY` environment variable
- **Dispatcher Module**: Core orchestration component that manages subscriptions to Nostr relays and handles incoming messages via BEAM message passing
- **EventHandler**: Processes and routes Nostr events received from relays
- **Nostrbase Integration**: External application that manages WebSocket connections to Nostr relays and publishes messages via Phoenix PubSub

The backend uses a functional, message-passing approach where the process creating subscriptions automatically becomes the receiver for subscription messages.

## Frontend Architecture
The frontend implements a modern, dark-themed interface with real-time capabilities:

- **Phoenix LiveView**: Provides server-side rendering with real-time updates
- **D3.js Network Visualization**: Interactive network graph for visualizing Nostr relationships and message flows
- **TailwindCSS Styling**: Custom dark theme with neon accents and monospace typography
- **Asset Pipeline**: ESBuild for JavaScript bundling and compilation

The frontend includes hooks for the NetworkGraph component that handles dynamic graph updates with shimmer effects for new nodes.

## Data Storage
The application uses SQLite as the primary database through:

- **Ecto ORM**: Database abstraction layer with migration support
- **Ecto SQLite3 Adapter**: Lightweight database solution suitable for development and smaller deployments
- **Database Schema**: Manages Nostr events, subscriptions, and related metadata

## Real-time Communication
- **Phoenix Channels**: WebSocket-based real-time communication for LiveView updates
- **Phoenix PubSub**: Inter-process message broadcasting for Nostr event distribution
- **LiveView Hooks**: JavaScript integration for interactive components like the network graph

## Identity Management
- **Read-only Identity**: Users can set a public key (npub or hex) without a private key via `/welcome`
- **Settings Table**: Key/value store in SQLite (`Mist.Settings`) persists the active pubkey across restarts
- **Identity Module** (`Mist.Nostr.Identity`): Handles identity switching — decodes npub, updates persistent_term, broadcasts PubSub, triggers bootstrap
- **LiveIdentity Hook** (`MistWeb.LiveIdentity`): on_mount guard redirecting to `/welcome` when no pubkey is configured; broadcasts identity changes to all live views
- **Welcome/Switcher LiveView**: `/welcome` route for first-run setup and identity switching

## Security and Authentication
- **Cryptographic Support**: Secp256k1 library for Nostr key operations and message signing
- **Bech32 Encoding**: Support for Nostr's address format requirements
- **Private Key Management**: Environment-based configuration for user identity (`NOSTR_PRIVKEY`)
- **Read-only Mode**: Write-action gating in NoteLive.Index, ProfileLive.Manage, and ProfileLive.ManageFollows when no private key is configured

# External Dependencies

## Core Framework Dependencies
- **Phoenix Framework**: Web application framework with LiveView for real-time interfaces
- **Ecto**: Database ORM with SQLite adapter for data persistence
- **Bandit**: High-performance HTTP server (Phoenix 1.7+ default)

## Nostr Protocol Integration
- **Nostrbase**: External application managing WebSocket connections to Nostr relays
- **Secp256k1 Library**: Cryptographic operations for Nostr key management and message signing
- **Bech32 Encoding**: Address format encoding/decoding for Nostr compatibility

## Frontend and Asset Management
- **D3.js**: Data visualization library for interactive network graphs
- **TailwindCSS**: Utility-first CSS framework with custom dark theme
- **ESBuild**: Fast JavaScript bundler and asset compilation
- **Phoenix LiveView**: Server-side rendering with real-time DOM updates

## Development and Build Tools
- **ElixirMake**: Native code compilation for cryptographic libraries
- **File System Watcher**: Asset recompilation during development
- **Live Debugger**: Development tool for debugging LiveView applications

## HTTP and Network Libraries
- **Finch**: HTTP client for external API communication
- **Mint**: Low-level HTTP client library
- **DNS Cluster**: Distributed node discovery and clustering support

## Utility Libraries
- **Jason**: High-performance JSON encoding/decoding
- **Gettext**: Internationalization support
- **Floki**: HTML parsing and manipulation
- **CircularBuffer**: Efficient circular buffer data structure for event handling