defmodule MistWeb.LiveIdentity do
  @moduledoc """
  An `on_mount` hook that guards protected LiveViews behind identity check.

  If no pubkey is configured, redirects to /welcome.
  Also subscribes connected LiveViews to the "identity:switched" PubSub topic
  so they navigate to / when the identity changes.
  """

  import Phoenix.LiveView

  def on_mount(:require_identity, _params, _session, socket) do
    case :persistent_term.get(:my_profile_pubkey, nil) do
      nil ->
        {:halt, redirect(socket, to: "/welcome")}

      _pubkey ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Mist.PubSub, "identity:switched")
        end

        {:cont, socket}
    end
  end
end
