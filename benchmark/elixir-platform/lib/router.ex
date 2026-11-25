defmodule Platform.Router do
  use Plug.Router
  alias Platform.Application, as: App

  plug :match
  plug :dispatch

  defp q(conn) do
    case conn.query_string |> URI.decode_query() |> Map.get("q", "1") |> Integer.parse() do
      {n, _} -> n |> max(1) |> min(500)
      :error -> 1
    end
  end

  defp row([id, rn]), do: %{"id" => id, "randomNumber" => rn}

  get "/plaintext" do
    conn |> put_resp_content_type("text/plain") |> send_resp(200, "Hello, World!")
  end

  get "/json" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"message":"Hello, World!"}))
  end

  get "/db" do
    id = :rand.uniform(10000)
    %{rows: [[rid, rn]]} = Postgrex.query!(App.conn(), "SELECT id, randomnumber FROM world WHERE id = $1", [id])
    conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"id":#{rid},"randomNumber":#{rn}}))
  end

  get "/queries" do
    q = q(conn)
    ids = for _ <- 1..q, do: :rand.uniform(10000)
    %{rows: rows} =
      Postgrex.query!(App.conn(), "SELECT id, randomnumber FROM world WHERE id = ANY($1::int[])", [ids])
    por_id = Map.new(rows, fn [id, rn] -> {id, rn} end)
    body = ids |> Enum.map(fn id -> ~s({"id":#{id},"randomNumber":#{Map.fetch!(por_id, id)}}) end) |> Enum.join(",")
    conn |> put_resp_content_type("application/json") |> send_resp(200, "[" <> body <> "]")
  end

  get "/updates" do
    q = q(conn)
    ids = for _ <- 1..q, do: :rand.uniform(10000)
    novos = for _ <- 1..q, do: :rand.uniform(10000)
    pares = Enum.zip(ids, novos)
    %{rows: rows} =
      Postgrex.query!(
        App.conn(),
        "UPDATE world SET randomnumber = v.rn FROM unnest($1::int[], $2::int[]) AS v(id, rn) " <>
          "WHERE world.id = v.id RETURNING world.id, world.randomnumber",
        [ids, novos]
      )
    por_id = Map.new(rows, fn [id, rn] -> {id, rn} end)
    body = pares |> Enum.map(fn {id, novo} -> ~s({"id":#{id},"randomNumber":#{Map.get(por_id, id, novo)}}) end) |> Enum.join(",")
    conn |> put_resp_content_type("application/json") |> send_resp(200, "[" <> body <> "]")
  end

  get "/fortunes" do
    %{rows: rows} = Postgrex.query!(App.conn(), "SELECT id, message FROM fortune", [])
    itens = rows ++ [[0, "Additional fortune added at request time."]]
    itens = Enum.sort_by(itens, fn [_, msg] -> msg end)
    linhas = Enum.map(itens, fn [id, msg] -> "<tr><td>#{id}</td><td>#{html_escape(msg)}</td></tr>" end)
    body = "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>" <>
             Enum.join(linhas) <> "</table></body></html>"
    conn |> put_resp_content_type("text/html", "utf-8") |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp html_escape(s) do
    s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;") |> String.replace("'", "&#39;")
  end
end
