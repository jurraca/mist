defmodule MistWeb.ProfileLiveTest do
  use MistWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mist.NostrFixtures

  defp create_profile(_) do
    profile = profile_fixture()
    %{profile: profile}
  end

  describe "Index" do
    test "renders the profiles page with search form", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/profiles")

      assert html =~ "Profiles you follow"
      assert html =~ "search_term"
    end

    test "shows followed profiles in the list", %{conn: conn} do
      _profile = profile_fixture()
      {:ok, _index_live, html} = live(conn, ~p"/profiles")

      assert html =~ "Profiles you follow"
    end

    test "ignores empty search submission", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/profiles")

      html =
        index_live
        |> form("form", %{"search_term" => ""})
        |> render_submit()

      assert html =~ "Profiles you follow"
    end
  end

  describe "Show" do
    setup [:create_profile]

    test "displays profile", %{conn: conn, profile: profile} do
      {:ok, _show_live, html} = live(conn, ~p"/profiles/#{profile}")

      assert html =~ "Back to profiles"
    end
  end
end
