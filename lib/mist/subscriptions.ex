defmodule Mist.Subscriptions do
  import Ecto.Query

  alias Mist.Repo
  alias Mist.Subscriptions.Subscription

  def list_subscriptions do
    Repo.all(from s in Subscription, order_by: [asc: s.name])
  end

  def get_subscription!(id), do: Repo.get!(Subscription, id)

  def create_subscription(attrs \\ %{}) do
    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert()
  end

  def update_subscription(%Subscription{} = subscription, attrs) do
    subscription
    |> Subscription.changeset(attrs)
    |> Repo.update()
  end

  def delete_subscription(%Subscription{} = subscription) do
    Repo.delete(subscription)
  end

  def change_subscription(%Subscription{} = subscription, attrs \\ %{}) do
    Subscription.changeset(subscription, attrs)
  end
end
