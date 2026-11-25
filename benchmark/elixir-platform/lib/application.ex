defmodule Platform.Application do
  use Application

  @conn_opts [
    hostname: "127.0.0.1", username: "benchmarkdbuser", password: "benchmarkdbpass",
    database: "hello_world", pool_size: 1
  ]

  def start(_type, _args) do
    porta = System.get_env("PORT", "8091") |> String.to_integer()
    pool = for _ <- 1..8, do: start_conn()
    :persistent_term.put({__MODULE__, :pool}, List.to_tuple(pool))
    :persistent_term.put({__MODULE__, :at}, :atomics.new(1, []))

    children = [
      {Plug.Cowboy, scheme: :http, plug: Platform.Router, options: [
        port: porta, ip: {0, 0, 0, 0}, num_acceptors: 4, max_connections: 16384,
        transport_options: [nodelay: true, backlog: 4096]
      ]}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: Platform.Supervisor)
  end

  defp start_conn do
    {:ok, pid} = Postgrex.start_link(@conn_opts)
    pid
  end

  def conn do
    pool = :persistent_term.get({__MODULE__, :pool})
    at = :persistent_term.get({__MODULE__, :at})
    :atomics.add_get(at, 1, 1)
    elem(pool, rem(:atomics.get(at, 1) - 1, tuple_size(pool)))
  end
end
