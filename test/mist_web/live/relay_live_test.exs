defmodule MistWeb.RelayLiveTest do
  use MistWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mist.NostrFixtures

  @create_attrs %{name: "some name", version: "some version", description: "some description", banner: "some banner", icon: "some icon", pubkey: "some pubkey", contact: "some contact", supported_nips: [1, 2], software: "some software"}
  @update_attrs %{name: "some updated name", version: "some updated version", description: "some updated description", banner: "some updated banner", icon: "some updated icon", pubkey: "some updated pubkey", contact: "some updated contact", supported_nips: [1], software: "some updated software"}
  @invalid_attrs %{name: nil, version: nil, description: nil, banner: nil, icon: nil, pubkey: nil, contact: nil, supported_nips: [], software: nil}

  defp create_relay(_) do
    relay = relay_fixture()
    %{relay: relay}
  end

  describe "Index" do
    setup [:create_relay]

    test "lists all relays", %{conn: conn, relay: relay} do
      {:ok, _index_live, html} = live(conn, ~p"/relays")

      assert html =~ "Listing Relays"
      assert html =~ relay.name
    end

    test "saves new relay", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/relays")

      assert index_live |> element("a", "New Relay") |> render_click() =~
               "New Relay"

      assert_patch(index_live, ~p"/relays/new")

      assert index_live
             |> form("#relay-form", relay: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#relay-form", relay: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/relays")

      html = render(index_live)
      assert html =~ "Relay created successfully"
      assert html =~ "some name"
    end

    test "updates relay in listing", %{conn: conn, relay: relay} do
      {:ok, index_live, _html} = live(conn, ~p"/relays")

      assert index_live |> element("#relays-#{relay.id} a", "Edit") |> render_click() =~
               "Edit Relay"

      assert_patch(index_live, ~p"/relays/#{relay}/edit")

      assert index_live
             |> form("#relay-form", relay: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#relay-form", relay: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/relays")

      html = render(index_live)
      assert html =~ "Relay updated successfully"
      assert html =~ "some updated name"
    end

    test "deletes relay in listing", %{conn: conn, relay: relay} do
      {:ok, index_live, _html} = live(conn, ~p"/relays")

      assert index_live |> element("#relays-#{relay.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#relays-#{relay.id}")
    end
  end

  describe "Show" do
    setup [:create_relay]

    test "displays relay", %{conn: conn, relay: relay} do
      {:ok, _show_live, html} = live(conn, ~p"/relays/#{relay}")

      assert html =~ "Show Relay"
      assert html =~ relay.name
    end

    test "updates relay within modal", %{conn: conn, relay: relay} do
      {:ok, show_live, _html} = live(conn, ~p"/relays/#{relay}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Relay"

      assert_patch(show_live, ~p"/relays/#{relay}/show/edit")

      assert show_live
             |> form("#relay-form", relay: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#relay-form", relay: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/relays/#{relay}")

      html = render(show_live)
      assert html =~ "Relay updated successfully"
      assert html =~ "some updated name"
    end
  end
end
