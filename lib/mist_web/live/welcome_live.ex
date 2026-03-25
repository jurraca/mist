defmodule MistWeb.WelcomeLive do
  use MistWeb, :live_view

  alias Mist.Nostr.Identity

  @impl true
  def mount(_params, _session, socket) do
    current_pubkey = Identity.current_pubkey()

    {:ok,
     socket
     |> assign(:current_pubkey, current_pubkey)
     |> assign(:form, to_form(%{"pubkey_input" => ""}))
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("switch_identity", %{"pubkey_input" => input}, socket) do
    case Identity.switch(input) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Identity set successfully")
         |> push_navigate(to: ~p"/")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, assign(socket, :error, reason)}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, "Failed to set identity. Please try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-dark-primary flex items-center justify-center px-4">
      <div class="w-full max-w-md">
        <div class="text-center mb-8">
          <div class="w-16 h-16 bg-gradient-to-br from-neon-green to-neon-purple rounded-2xl flex items-center justify-center font-bold text-3xl text-dark-primary mx-auto mb-4">
            M
          </div>
          <h1 class="text-3xl font-bold text-neon-green mb-2">Welcome to MIST</h1>
          <p class="text-text-secondary">Enter your Nostr public key to get started in read-only mode.</p>
        </div>

        <div class="bg-dark-secondary border border-dark-border rounded-2xl p-8">
          <%= if @current_pubkey do %>
            <div class="mb-6 p-4 bg-dark-tertiary border border-dark-border rounded-lg">
              <p class="text-xs text-text-muted mb-1">Current identity</p>
              <p class="text-sm text-neon-green font-mono break-all"><%= @current_pubkey %></p>
            </div>
          <% end %>

          <h2 class="text-lg font-semibold text-text-primary mb-6">
            <%= if @current_pubkey, do: "Switch Identity", else: "Set Your Identity" %>
          </h2>

          <form phx-submit="switch_identity" class="space-y-4">
            <div>
              <label class="block text-sm text-text-secondary mb-2">
                npub or hex public key
              </label>
              <input
                type="text"
                name="pubkey_input"
                placeholder="npub1... or 64-char hex"
                class="w-full bg-dark-tertiary border border-dark-border rounded-lg px-4 py-3 text-text-primary placeholder-text-muted focus:outline-none focus:border-neon-green transition-colors font-mono text-sm"
                required
              />
              <%= if @error do %>
                <p class="mt-2 text-sm text-red-400"><%= @error %></p>
              <% end %>
            </div>

            <button
              type="submit"
              class="w-full bg-neon-green text-dark-primary font-semibold py-3 rounded-lg hover:bg-neon-purple transition-colors"
            >
              <%= if @current_pubkey, do: "Switch Identity", else: "Set Identity" %>
            </button>
          </form>

          <%= if @current_pubkey do %>
            <div class="mt-4 text-center">
              <.link navigate={~p"/"} class="text-sm text-text-muted hover:text-neon-green transition-colors">
                Cancel — keep current identity
              </.link>
            </div>
          <% end %>

          <div class="mt-6 p-4 bg-dark-tertiary rounded-lg border border-dark-border">
            <p class="text-xs text-text-muted leading-relaxed">
              Read-only mode — you can browse notes, profiles, and follows without a private key.
              Write actions (publishing notes, editing profile) require a private key configured via the
              <code class="text-neon-green">NOSTR_PRIVKEY</code> environment variable.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
