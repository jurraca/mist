# Mist

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).


## Architecture

Mist is an interface to Nostr, meaning it sends messages and queries for messages via Nostr relays.

On startup, Mist looks for a `NOSTR_PRIVKEY` env variable. If it exists, the `Signer` module derives the public key associated with the private key and uses that as the user identity. Without one, a read-only identity (npub) can be set via `/welcome` and is persisted in the `settings` table.

The `Mist.Nostr.SubManager` GenServer is the core of the application and the single owner of all relay subscriptions:

- **Ad-hoc (named) subscriptions** for UI-driven filters (`:notes_feed`, profile and follow-list lookups).
- **Feed subscriptions**: a reconciliation loop computes the desired state from the DB (the user's follows → their NIP-65 write relays, falling back to a set of well-known relays for follows with no known relay list) and opens/closes subscriptions to match. It reconciles on startup, identity switches, new follows, follow-list (kind 3) and relay-list (kind 10002) updates, and a periodic tick that also reconnects dead relays.

Because `NostrEx.send_sub/2` registers the calling process as the receiver of a subscription's messages, SubManager is the single event ingress: every incoming event is forwarded to `EventHandler`, which stores it in the local DB and broadcasts over PubSub to subscribed LiveViews.

Websocket connections to relays are managed by the [NostrEx](../nostr_ex) library (built on NostrCore). One-shot fetches (bootstrap of own kind 0/3/10002, relay discovery) run as separate task-based receive loops in `Initializer` and `Jobs.FindUserRelays`.

That's really it: subscribe to messages, handle them in `EventHandler` and dispatch them where you want.

