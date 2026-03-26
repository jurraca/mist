defmodule Mist.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Create ETS table for interaction counts with concurrency options
    :ets.new(:interaction_counts, [:named_table, :public, :set, {:write_concurrency, true}, {:read_concurrency, true}])
    
    children =
      [
        MistWeb.Telemetry,
        Mist.Repo,
        {DNSCluster, query: Application.get_env(:mist, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Mist.PubSub},
        {Task.Supervisor, name: Mist.TaskSupervisor}
      ] ++
        if Application.get_env(:mist, :skip_nostr_services, false) do
          []
        else
          [
            {Mist.Nostr.Signer, signing_method: :local},
            Mist.Nostr.Dispatcher,
            Mist.Nostr.SubscriptionPlanner,
            Mist.Nostr.Initializer,
            Mist.Jobs.FindUserRelays
          ]
        end ++
        [MistWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mist.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MistWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
