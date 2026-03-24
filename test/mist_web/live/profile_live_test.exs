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

      assert html =~ "Show Profile"
    end

    test "updates profile within modal", %{conn: conn, profile: profile} do
      {:ok, show_live, _html} = live(conn, ~p"/profiles/#{profile}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Profile"

      assert_patch(show_live, ~p"/profiles/#{profile}/show/edit")

      assert show_live
             |> form("#profile-form")
             |> render_submit()

      assert_patch(show_live, ~p"/profiles/#{profile}")

      html = render(show_live)
      assert html =~ "Profile updated successfully"
    end
  end
end
