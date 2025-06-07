# Mist

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).


## Architecture

Mist is an interface to Nostr, meaning it sends messages and queries for messages via Nostr relays.

On startup, Mist looks for a `NOSTR_PRIVKEY` env variable. If it exists, the `Signer` module derives the public key associated with the private key and uses that as the user identity.

The `Dispatcher` module is the core module of the application: it handles subscribing (sending subscriptions requests to relays) and receiving those subscription messages (via BEAM message passing, from those relays). When it receives messages, it does two main things: stores the data in the local DB, and sends the message over PubSub to subscribed processes, like the Liveview front end pages.

The Nostr websocket connections to relays are managed by the `Nostrbase` application, which publishes messages via PubSub. The process which creates subscriptions is automatically set up as the receiver of those PubSub messages; in our case this is our Dispatcher process.

That's really it: subscribe to messages, handle them in `EventHandler` and dispatch them where you want.

