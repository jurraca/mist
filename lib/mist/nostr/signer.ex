defmodule Mist.Nostr.Signer do
  use GenServer
  alias Mist.Nostr.Keys
  require Logger

  @type signing_method :: :local | :remote

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:mist, :signer, mode: {:local})

    case config[:mode] do
      {:local} -> {:ok, %{mode: :local, authorized_clients: %{}}, {:continue, nil}}

      {:remote, bunker_url} when is_binary(bunker_url) ->
        {:ok, %{mode: :remote, bunker_url: bunker_url, authorized_clients: %{}}}

      invalid_config ->
        {:stop, "Invalid signer config: #{inspect(invalid_config)}"}
    end
  end

  # Client API - mimics NIP-46 bunker interface
  def connect(client_pubkey, secret \\ nil) do
    GenServer.call(__MODULE__, {:connect, client_pubkey, secret})
  end

  def get_public_key do
    GenServer.call(__MODULE__, :get_public_key)
  end

  def sign_event(event_params) do
    GenServer.call(__MODULE__, {:sign_event, event_params})
  end

  # Server callbacks
  @impl GenServer
  def handle_continue(_arg, state) do
    case Keys.derive_public_key() do
      {:ok, pubkey} ->
          :persistent_term.put(:my_profile_pubkey, pubkey)
          {:noreply, state}
      _ -> {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call({:connect, client_pubkey, _secret}, _from, state) do
    # In local mode, we auto-approve all connections
    {:reply, {:ok, "ack"}, put_in(state.authorized_clients[client_pubkey], true)}
  end

  @impl GenServer
  def handle_call(:get_public_key, _from, state) do
    case Keys.derive_public_key() do
      {:ok, pubkey} ->
        {:reply, {:ok, pubkey}, state}

      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl GenServer
  def handle_call({:sign_event, event_params}, _from, %{mode: :local} = state) do
    case Keys.get_private_key() do
      {:ok, priv_key} ->
        event = Nostr.Event.sign(event_params, priv_key)
        {:reply, {:ok, event}, state}
      {:error, _} = err ->
        {:reply, err, state}
    end
  end
end
