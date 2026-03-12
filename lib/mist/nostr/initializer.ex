defmodule Mist.Nostr.Initializer do
  @moduledoc """
  Handles bootstrap initialization for the Nostr application.

  On startup, waits for the signer to be ready (using OTP-idiomatic retries),
  then connects to a configurable bootstrap relay and performs a one-shot fetch
  of the user's own kind 0 (profile), kind 3 (follow list), and kind 10002
  (relay metadata) events. The subscription is closed after EOSE or a timeout.

  ## Configuration

    config :mist, :bootstrap_relay, "wss://purplepag.es"

  """

  use GenServer
  require Logger

  alias Mist.Nostr.EventHandler
  alias Mist.Relay

  @default_bootstrap_relay "wss://purplepag.es"
  @bootstrap_kinds [0, 3, 10002]
  @subscription_timeout 15_000
  @retry_interval 200
  @max_retries 50

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{retries: 0}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    {:ok, state, {:continue, :check_signer}}
  end

  @impl GenServer
  def handle_continue(:check_signer, state) do
    check_signer_and_bootstrap(state)
  end

  @impl GenServer
  def handle_info(:retry_init, state) do
    check_signer_and_bootstrap(state)
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("Initializer received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp check_signer_and_bootstrap(%{retries: retries} = state) do
    case :persistent_term.get(:my_profile_pubkey, nil) do
      nil when retries < @max_retries ->
        Process.send_after(self(), :retry_init, @retry_interval)
        {:noreply, %{state | retries: retries + 1}}

      nil ->
        Logger.warning(
          "Initializer: signer not ready after #{retries} retries (#{retries * @retry_interval}ms), skipping bootstrap"
        )
        {:noreply, state}

      pubkey ->
        Logger.info("Initializer: signer ready, starting bootstrap fetch")
        run_bootstrap(pubkey)
        {:noreply, state}
    end
  end

  defp run_bootstrap(pubkey) do
    relay_url = bootstrap_relay()
    Logger.info("Initializer: connecting to bootstrap relay #{relay_url}")

    case Relay.maybe_connect_relays([relay_url]) do
      {:ok, _} ->
        fetch_own_events(pubkey, relay_url)

      {:error, reason} ->
        Logger.warning("Initializer: failed to connect to bootstrap relay: #{inspect(reason)}")
    end
  end

  defp fetch_own_events(pubkey, relay_url) do
    filter = [authors: [pubkey], kinds: @bootstrap_kinds]

    case NostrEx.send_sub(filter, send_via: [relay_url]) do
      {:ok, sub_id} ->
        Logger.info("Initializer: subscribed to #{relay_url} (sub_id: #{sub_id})")
        event_count = receive_events_loop(sub_id, relay_url)
        Logger.info("Initializer: bootstrap complete — processed #{event_count} events")

      {:error, reason} ->
        Logger.warning("Initializer: failed to subscribe on #{relay_url}: #{inspect(reason)}")
    end
  end

  defp receive_events_loop(sub_id, relay_url) do
    start_time = System.monotonic_time(:millisecond)
    do_receive_loop(sub_id, relay_url, 0, start_time)
  end

  defp do_receive_loop(sub_id, relay_url, event_count, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > @subscription_timeout do
      Logger.warning("Initializer: bootstrap timed out after #{elapsed}ms, closing subscription")
      NostrEx.close_sub(sub_id)
      event_count
    else
      remaining = @subscription_timeout - elapsed

      receive do
        {:event, ^sub_id, event} ->
          EventHandler.process_event(event)
          do_receive_loop(sub_id, relay_url, event_count + 1, start_time)

        {:eose, ^sub_id, _relay_host} ->
          Logger.info("Initializer: EOSE received from #{relay_url}")
          NostrEx.close_sub(sub_id)
          event_count
      after
        remaining ->
          Logger.warning("Initializer: no messages received within timeout, closing subscription")
          NostrEx.close_sub(sub_id)
          event_count
      end
    end
  end

  defp bootstrap_relay do
    Application.get_env(:mist, :bootstrap_relay, @default_bootstrap_relay)
  end
end
