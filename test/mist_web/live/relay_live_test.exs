defmodule MistWeb.RelayLiveTest do
  use MistWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mist.NostrFixtures

  defp create_relay(_) do
    relay = relay_fixture()
    %{relay: relay}
  end

  describe "Index" do
    setup [:create_relay]

    test "lists all relays", %{conn: conn, relay: relay} do
      {:ok, _index_live, html} = live(conn, ~p"/relays")

      assert html =~ "My Relays"
      assert html =~ relay.name || relay.url
    end

    test "saves new relay", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/relays")

      assert index_live |> element("a", "Add Relay") |> render_click() =~
               "Add a relay URL"

      assert_patch(index_live, ~p"/relays/new")

      assert index_live
             |> form("#relay-form", %{"url" => "wss://new-relay-live.example.com"})
             |> render_submit()

      assert_patch(index_live, ~p"/relays")

      html = render(index_live)
      assert html =~ "Relay saved successfully"
    end
  end
end
