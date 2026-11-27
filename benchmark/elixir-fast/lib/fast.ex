defmodule Fast do
  @moduledoc """
  Servidor TechEmpower mínimo ("platform"): `gen_tcp` cru, HTTP/1.1 próprio, batching de banco por
  rodada. É o equivalente Elixir do `fast7` do Zig — a mesma ideia: em vez de pagar uma ida ao
  PostgreSQL por requisição, os pedidos de uma janela curta viram UM `EXECUTE` com arrays.
  """

  @worlds 10_000
  @plain ~s(HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!)
  @json ~s(HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{"message":"Hello, World!"})
  @json_ini "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
  @html_ini "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
  @fim "\r\n\r\n"
  @nao_achou "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
  @erro "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"
  @f_head "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>"
  @f_row_ini "<tr><td>"
  @f_row_meio "</td><td>"
  @f_row_fim "</td></tr>"
  @f_tail "</table></body></html>"
  @fortune_extra "Additional fortune added at request time."
  @escape %{
    ?& => "&amp;",
    ?< => "&lt;",
    ?> => "&gt;",
    ?" => "&quot;",
    ?' => "&#x27;",
    ?/ => "&#x2f;"
  }

  def main do
    {:ok, _} = Application.ensure_all_started(:crypto)
    port = env_int("PORT", 8098)
    workers = env_int("WORKERS", System.schedulers_online())
    janela_us = env_int("BATCH_US", 2000)
    pids = for i <- 1..workers, do: spawn_worker(i, janela_us)
    contador = :atomics.new(1, [])

    {:ok, escuta} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        nodelay: true,
        backlog: 4096,
        buffer: 65_536
      ])

    IO.puts("elixir-fast :#{port} workers=#{workers} janela=#{janela_us}us")
    for _ <- 1..workers, do: spawn_link(fn -> aceitar(escuta, pids, contador) end)
    Process.sleep(:infinity)
  end

  defp env_int(nome, padrao) do
    case Integer.parse(System.get_env(nome) || "") do
      {n, _} when n > 0 -> n
      _ -> padrao
    end
  end

  # ── aceitação e conexão ────────────────────────────────────────────────────

  defp aceitar(escuta, pids, contador) do
    case :gen_tcp.accept(escuta) do
      {:ok, socket} ->
        pid = spawn(fn -> iniciar_conexao(socket, pids, contador) end)
        :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        aceitar(escuta, pids, contador)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        aceitar(escuta, pids, contador)
    end
  end

  # A posse do socket chega antes de qualquer recv; o seed é por conexão para os ids não repetirem entre processos.
  defp iniciar_conexao(socket, pids, contador) do
    receive do
      :go -> :ok
    after
      5_000 -> :gen_tcp.close(socket)
    end

    :rand.seed(:exsss, {System.unique_integer([:positive]), System.unique_integer([:positive]), System.unique_integer([:positive])})
    ler(socket, pids, contador, "")
  end

  defp ler(socket, pids, contador, buffer) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, dados} ->
        {respostas, resto} = interpretar(buffer <> dados, pids, contador)
        :gen_tcp.send(socket, respostas)
        ler(socket, pids, contador, resto)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp interpretar(buffer, pids, contador) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        {"", buffer}

      {pos, 4} ->
        cabecalho = binary_part(buffer, 0, pos)
        resto = binary_part(buffer, pos + 4, byte_size(buffer) - pos - 4)

        resposta =
          case linha_de_requisicao(cabecalho) do
            nil -> @nao_achou
            alvo -> tratar(alvo, pids, contador)
          end

        {mais, sobra} = interpretar(resto, pids, contador)
        {[resposta, mais], sobra}
    end
  end

  defp linha_de_requisicao(cabecalho) do
    case :binary.split(cabecalho, "\r\n") do
      [linha | _] ->
        case :binary.split(linha, " ", [:global]) do
          [_metodo, alvo | _] -> alvo
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ── rotas ─────────────────────────────────────────────────────────────────

  defp tratar("/plaintext", _pids, _contador), do: @plain
  defp tratar("/json", _pids, _contador), do: @json

  defp tratar("/db", pids, contador) do
    id = :rand.uniform(@worlds)

    case pedir(pids, contador, :db, [id]) do
      {:ok, corpo} -> json(corpo)
      :erro -> @erro
    end
  end

  defp tratar("/fortunes", pids, contador) do
    case pedir(pids, contador, :fortunes, []) do
      {:ok, corpo} -> html(corpo)
      :erro -> @erro
    end
  end

  defp tratar(alvo, pids, contador) do
    cond do
      String.starts_with?(alvo, "/queries") ->
        q = quantidade(alvo)
        ids = for _ <- 1..q, do: :rand.uniform(@worlds)

        case pedir(pids, contador, :queries, ids) do
          {:ok, corpo} -> json(corpo)
          :erro -> @erro
        end

      String.starts_with?(alvo, "/updates") ->
        q = quantidade(alvo)
        ids = for _ <- 1..q, do: :rand.uniform(@worlds)
        nums = for _ <- 1..q, do: :rand.uniform(@worlds)

        case pedir(pids, contador, :updates, {ids, nums}) do
          {:ok, corpo} -> json(corpo)
          :erro -> @erro
        end

      true ->
        @nao_achou
    end
  end

  defp quantidade(alvo) do
    case :binary.split(alvo, "q=") do
      [_antes, valor] ->
        valor
        |> :binary.split("&")
        |> hd()
        |> Integer.parse()
        |> case do
          {n, _} when n >= 1 and n <= 500 -> n
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp json(corpo), do: [@json_ini, Integer.to_string(IO.iodata_length(corpo)), @fim, corpo]
  defp html(corpo), do: [@html_ini, Integer.to_string(IO.iodata_length(corpo)), @fim, corpo]

  # ── batching de banco ────────────────────────────────────────────────────

  defp pedir(pids, contador, tipo, ids) do
    indice = rem(:atomics.add_get(contador, 1, 1), length(pids))
    pid = Enum.at(pids, indice)
    ref = make_ref()
    send(pid, {:req, self(), ref, tipo, ids})

    receive do
      {^ref, {:ok, corpo}} -> {:ok, corpo}
      {^ref, :erro} -> :erro
    after
      10_000 -> :erro
    end
  end

  defp spawn_worker(_i, janela_us), do: spawn_link(fn -> worker_init(janela_us) end)

  defp worker_init(janela_us) do
    {:ok, conn} =
      Pg.conectar(
        host: "127.0.0.1",
        port: 5432,
        usuario: "benchmarkdbuser",
        senha: "benchmarkdbpass",
        banco: "hello_world"
      )

    worker_loop(conn, janela_us, [])
  end

  defp worker_loop(conn, janela_us, pendentes) do
    pendentes =
      receive do
        {:req, from, ref, tipo, ids} -> [{from, ref, tipo, ids} | pendentes]
      after
        janela_us -> pendentes
      end

    if pendentes == [] do
      worker_loop(conn, janela_us, [])
    else
      # A janela é um PRAZO (não um `after` por mensagem): com `after` dentro do laço, cada chegada reiniciava o
      # relógio e o lote só fechava quando o fluxo parava — sob 512 conexões isso virava centenas de ms por lote.
      prazo = System.monotonic_time(:microsecond) + janela_us
      pendentes = drenar(pendentes, prazo)
      executar(conn, Enum.reverse(pendentes))
      worker_loop(conn, janela_us, [])
    end
  end

  defp drenar(pendentes, prazo_us) do
    restante = prazo_us - System.monotonic_time(:microsecond)

    if restante <= 0 do
      pendentes
    else
      receive do
        {:req, from, ref, tipo, ids} -> drenar([{from, ref, tipo, ids} | pendentes], prazo_us)
      after
        restante -> pendentes
      end
    end
  end

  defp executar(conn, reqs) do
    {simples, resto} = Enum.split_with(reqs, fn {_f, _r, tipo, _ids} -> tipo in [:db, :queries] end)
    if simples != [], do: responder_select(conn, simples)
    {updates, fortunes} = Enum.split_with(resto, fn {_f, _r, tipo, _ids} -> tipo == :updates end)
    if updates != [], do: responder_updates(conn, updates)
    if fortunes != [], do: responder_fortunes(conn, fortunes)
  end

  defp responder_select(conn, reqs) do
    ids = reqs |> Enum.flat_map(fn {_f, _r, _t, ids} -> ids end) |> Enum.uniq()
    sql = "SELECT id, randomnumber FROM world WHERE id = ANY('" <> vetor(ids) <> "'::int[])"

    case Pg.query(conn, sql) do
      {:ok, rows} ->
        mapa = Map.new(rows, fn [id, rn] -> {String.to_integer(id), String.to_integer(rn)} end)
        for {from, ref, tipo, ids} <- reqs do
          if tipo == :db do
            id = hd(ids)
            send(from, {ref, {:ok, db_json(id, Map.get(mapa, id, 0))}})
          else
            send(from, {ref, {:ok, queries_json(ids, mapa)}})
          end
        end

      _ ->
        for {from, ref, _tipo, _ids} <- reqs, do: send(from, {ref, :erro})
    end
  end

  defp responder_updates(conn, reqs) do
    # Ordem canônica por id: dois lotes concorrentes tocam as mesmas linhas em ordens diferentes e o PostgreSQL
    # aborta um deles por deadlock (40P01). Ordenar impõe a mesma sequência de locks para todos os lotes.
    {ids, nums} =
      reqs
      |> Enum.flat_map(fn {_f, _r, _t, {ids, nums}} -> Enum.zip(ids, nums) end)
      |> Enum.sort()
      |> Enum.unzip()

    sql_update =
      "UPDATE world SET randomnumber = v.rn FROM (SELECT * FROM UNNEST('" <>
        vetor(ids) <> "'::int[], '" <> vetor(nums) <> "'::int[]) AS w(id, rn)) AS v(id, rn) WHERE world.id = v.id"

    # Deadlock (40P01) entre lotes concorrentes é possível mesmo com ordem canônica; repetir o lote resolve.
    resultado =
      Enum.reduce_while(1..3, nil, fn tentativa, _ ->
        case Pg.query(conn, sql_update) do
          {:error, "40P01" <> _} when tentativa < 3 -> {:cont, nil}
          outro -> {:halt, outro}
        end
      end)

    case resultado do
      {:ok, _} ->
        for {from, ref, _tipo, {ids_req, nums_req}} <- reqs do
          send(from, {ref, {:ok, updates_json(ids_req, nums_req)}})
        end

      _ ->
        for {from, ref, _tipo, _ids} <- reqs, do: send(from, {ref, :erro})
    end
  end

  defp responder_fortunes(conn, reqs) do
    case Pg.query(conn, "SELECT id, message FROM fortune") do
      {:ok, rows} ->
        corpo = render_fortunes(rows)
        for {from, ref, _tipo, _ids} <- reqs, do: send(from, {ref, {:ok, corpo}})

      _ ->
        for {from, ref, _tipo, _ids} <- reqs, do: send(from, {ref, :erro})
    end
  end

  # Inteiros já validados pela rota: o literal `{1,2,...}` não tem como carregar SQL.
  defp vetor(ints), do: "{" <> Enum.map_join(ints, ",", &Integer.to_string/1) <> "}"

  defp db_json(id, rn), do: ["{\"id\":", Integer.to_string(id), ",\"randomNumber\":", Integer.to_string(rn), "}"]

  defp queries_json(ids, mapa) do
    [
      "[",
      ids
      |> Enum.map(fn id -> db_json(id, Map.get(mapa, id, 0)) end)
      |> Enum.intersperse(","),
      "]"
    ]
  end

  defp updates_json(ids, nums) do
    [
      "[",
      ids
      |> Enum.zip(nums)
      |> Enum.map(fn {id, rn} -> db_json(id, rn) end)
      |> Enum.intersperse(","),
      "]"
    ]
  end

  defp render_fortunes(rows) do
    ordenadas =
      [{"0", @fortune_extra} | Enum.map(rows, fn [id, msg] -> {id, msg} end)]
      |> Enum.sort_by(fn {_id, msg} -> msg end, :asc)

    [
      @f_head,
      Enum.map(ordenadas, fn {id, msg} -> [@f_row_ini, id, @f_row_meio, escapar(msg), @f_row_fim] end),
      @f_tail
    ]
  end

  defp escapar(msg) do
    for <<c <- msg>> do
      Map.get(@escape, c, <<c>>)
    end
  end
end
