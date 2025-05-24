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
      {:local} ->
        {:ok, %{mode: :local, authorized_clients: %{}}}

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
  @impl true
  def handle_call({:connect, client_pubkey, _secret}, _from, state) do
    # In local mode, we auto-approve all connections
    {:reply, {:ok, "ack"}, put_in(state.authorized_clients[client_pubkey], true)}
  end

  @impl true 
  def handle_call(:get_public_key, _from, state) do
    {:reply, {:ok, Keys.derive_public_key()}, state}
  end

  @impl true
  def handle_call({:sign_event, event_params}, _from, %{signing_method: :local} = state) do
    priv_key = Keys.get_private_key()
    event = Nostr.Event.create(event_params, priv_key)
    {:reply, {:ok, event}, state}
  end
end