defmodule Mist.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MistWeb.Telemetry,
      Mist.Repo,
      {DNSCluster, query: Application.get_env(:mist, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Mist.PubSub},
      # Start a worker by calling: Mist.Worker.start_link(arg)
      # {Mist.Worker, arg},
      # Start to serve requests, typically the last entry
      MistWeb.Endpoint
    ]

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
