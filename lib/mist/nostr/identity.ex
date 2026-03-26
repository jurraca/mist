defmodule Mist.Nostr.Identity do
  @moduledoc """
  Owns the identity switch operation for read-only identity management.

  Decodes npub/hex pubkey input, validates it, persists it, and triggers
  a bootstrap fetch so the app works with the new identity immediately.
  """

  alias Mist.{Settings, Profile}
  alias Mist.Nostr.{Keys, Initializer}
  require Logger

  @pubkey_setting "active_pubkey"

  @doc """
  Switch the active identity to the given npub or hex pubkey.

  Optionally accepts a relay URL hint used to bootstrap the user's data.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  def switch(input, relay_hint \\ nil) when is_binary(input) do
    with {:ok, hex_pubkey} <- Keys.decode_pubkey_input(input),
         :ok <- Settings.put(@pubkey_setting, hex_pubkey) do
      :persistent_term.put(:my_profile_pubkey, hex_pubkey)

      Profile.get_or_create_profile(hex_pubkey)

      Phoenix.PubSub.broadcast(Mist.PubSub, "identity:switched", {:identity_switched, hex_pubkey})

      Task.Supervisor.start_child(Mist.TaskSupervisor, fn ->
        Initializer.bootstrap(hex_pubkey, relay_hint)
      end)

      :ok
    end
  end

  @doc """
  Load the active identity from the DB into `:persistent_term` if one is stored.
  Skips if an env-var private key already set a pubkey in persistent_term.
  """
  def load_from_db do
    case :persistent_term.get(:my_profile_pubkey, nil) do
      nil ->
        case Settings.get(@pubkey_setting) do
          {:ok, pubkey} ->
            :persistent_term.put(:my_profile_pubkey, pubkey)
            Logger.info("Identity: loaded active pubkey from DB: #{pubkey}")

          {:error, :not_found} ->
            Logger.info("Identity: no active pubkey stored in DB")

          {:error, reason} ->
            Logger.warning("Identity: failed to load pubkey from DB: #{inspect(reason)}")
        end

      _already_set ->
        :ok
    end
  end

  @doc """
  Returns the currently active pubkey, if any.
  """
  def current_pubkey do
    :persistent_term.get(:my_profile_pubkey, nil)
  end
end
