defmodule TermigateWeb.ConfigController do
  use TermigateWeb, :controller

  alias Termigate.Config

  def show(conn, _params) do
    json(conn, Config.public_view())
  end
end
