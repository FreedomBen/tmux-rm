defmodule TermigateWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TermigateWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen">
      <aside class="hidden md:flex md:w-64 flex-col bg-base-200 border-r border-base-300 p-4">
        <div class="flex items-center gap-2 mb-8">
          <span class="text-lg font-bold tracking-tight">termigate</span>
        </div>
        <nav class="flex-1 space-y-1">
          <a href="/" class="btn btn-ghost btn-sm w-full justify-start">
            <.icon name="hero-home-micro" class="size-4" /> Sessions
          </a>
          <a href="/settings" class="btn btn-ghost btn-sm w-full justify-start">
            <.icon name="hero-cog-6-tooth-micro" class="size-4" /> Settings
          </a>
        </nav>
      </aside>

      <div class="flex flex-1 flex-col min-w-0">
        <main class="flex-1 overflow-auto p-4 sm:p-6 lg:p-8">
          {render_slot(@inner_block)}
        </main>

        <nav class="md:hidden btm-nav btm-nav-sm bg-base-200 border-t border-base-300">
          <a href="/" class="text-base-content">
            <.icon name="hero-home-micro" class="size-5" />
          </a>
          <a href="/settings" class="text-base-content">
            <.icon name="hero-cog-6-tooth-micro" class="size-5" />
          </a>
        </nav>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Resolves the DaisyUI page-chrome theme ("dark" or "light") from the saved
  Config terminal theme. Solarized variants map to their light/dark base; any
  unknown value falls back to "dark".
  """
  def resolve_page_theme do
    theme = get_in(Termigate.Config.get(), ["terminal", "theme"]) || "dark"

    case theme do
      "light" -> "light"
      "solarizedLight" -> "light"
      _ -> "dark"
    end
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
