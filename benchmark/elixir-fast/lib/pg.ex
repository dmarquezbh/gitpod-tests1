defmodule Pg do
  @moduledoc """
  Cliente mínimo do protocolo PostgreSQL (v3) sobre `gen_tcp`.

  Existe para medir o servidor sem o custo do Postgrex/DBConnection: autenticação SCRAM-SHA-256 e consultas
  pelo protocolo simples (`Q`), com resultados em formato texto. Só aceita SQL com valores já literais
  (inteiros) embutidos — não há parâmetros, escape ou correção de tipos além do que a rota monta.
  """

  @doc """
  Abre a conexão, autentica e devolve o socket pronto para consultas.

  `opcoes` aceita `:host` (padrão "127.0.0.1"), `:port` (5432), `:usuario`, `:senha` e `:banco`.
  """
  @spec conectar(keyword()) :: {:ok, port()} | {:error, term()}
  def conectar(opcoes) do
    host = Keyword.get(opcoes, :host, "127.0.0.1")
    port = Keyword.get(opcoes, :port, 5432)
    usuario = Keyword.fetch!(opcoes, :usuario)
    senha = Keyword.fetch!(opcoes, :senha)
    banco = Keyword.fetch!(opcoes, :banco)

    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, {:active, false}, {:nodelay, true}], 5_000) do
      {:ok, socket} ->
        case autenticar(socket, usuario, senha, banco) do
          :ok -> {:ok, socket}
          {:error, motivo} ->
            :gen_tcp.close(socket)
            {:error, motivo}
        end

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  @doc """
  Executa uma consulta pelo protocolo simples e devolve as linhas como listas de campos em texto (`nil` para NULL).
  """
  @spec query(port(), String.t()) :: {:ok, [[String.t() | nil]]} | {:error, String.t()}
  def query(socket, sql) do
    enviar(socket, ?Q, [sql, <<0>>])

    case ler_ate_pronto(socket, []) do
      {:ok, linhas} -> {:ok, Enum.reverse(linhas)}
      {:error, motivo} -> {:error, motivo}
    end
  end

  @doc "Fecha o socket."
  def fechar(socket), do: :gen_tcp.close(socket)

  defp autenticar(socket, usuario, senha, banco) do
    payload = [<<196_608::32>>, "user", <<0>>, usuario, <<0>>, "database", <<0>>, banco, <<0>>, <<0>>]
    :ok = :gen_tcp.send(socket, [<<IO.iodata_length(payload) + 4::32>>, payload])
    ler_handshake(socket, usuario, senha, nil)
  end

  defp ler_handshake(socket, usuario, senha, estado_sasl) do
    case ler_mensagem(socket) do
      {:ok, ?R, <<codigo::32, resto::binary>>} ->
        case codigo do
          0 ->
            ler_handshake(socket, usuario, senha, estado_sasl)

          3 ->
            enviar(socket, ?p, [senha, <<0>>])
            ler_handshake(socket, usuario, senha, estado_sasl)

          5 ->
            enviar(socket, ?p, [md5(senha, resto), <<0>>])
            ler_handshake(socket, usuario, senha, estado_sasl)

          10 ->
            if not String.contains?(resto, "SCRAM-SHA-256"), do: {:error, "mecanismo SASL não suportado"}
            nonce = Base.encode64(:crypto.strong_rand_bytes(18))
            primeira = "n=#{usuario},r=#{nonce}"
            resposta = "n,," <> primeira
            enviar(socket, ?p, ["SCRAM-SHA-256", <<0>>, <<byte_size(resposta)::32>>, resposta])
            ler_handshake(socket, usuario, senha, primeira)

          11 ->
            primeira = estado_sasl
            {server_nonce, salt, iteracoes} = ler_scram(resto)
            sem_prova = "c=biws,r=#{server_nonce}"
            mensagem = primeira <> "," <> resto <> "," <> sem_prova
            salted = :crypto.pbkdf2_hmac(:sha256, senha, Base.decode64!(salt), iteracoes, 32)
            chave_cliente = hmac(salted, "Client Key")
            chave_armazenada = :crypto.hash(:sha256, chave_cliente)
            assinatura = hmac(chave_armazenada, mensagem)
            prova = Base.encode64(xor(chave_cliente, assinatura))
            enviar(socket, ?p, [sem_prova, ",p=", prova])
            ler_handshake(socket, usuario, senha, nil)

          12 ->
            ler_handshake(socket, usuario, senha, nil)
        end

      {:ok, ?E, resto} ->
        {:error, erro_de(resto)}

      {:ok, ?Z, _} ->
        :ok

      {:ok, _tipo, _resto} ->
        ler_handshake(socket, usuario, senha, estado_sasl)

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  defp ler_scram(dados) do
    campos = for campo <- String.split(dados, ","), into: %{}, do: (case String.split(campo, "=", parts: 2) do
      [chave, valor] -> {chave, valor}
      [chave] -> {chave, ""}
    end)

    {Map.fetch!(campos, "r"), Map.fetch!(campos, "s"), String.to_integer(Map.fetch!(campos, "i"))}
  end

  defp md5(senha, salt) do
    hash = Base.encode16(:crypto.hash(:md5, [senha, salt]), case: :lower)
    "md5" <> Base.encode16(:crypto.hash(:md5, hash), case: :lower)
  end

  defp hmac(chave, dados), do: :crypto.mac(:hmac, :sha256, chave, dados)

  defp xor(a, b) do
    :crypto.exor(a, b)
  end

  defp ler_ate_pronto(socket, linhas) do
    case ler_mensagem(socket) do
      {:ok, ?D, resto} -> ler_ate_pronto(socket, [linha_de(resto) | linhas])
      {:ok, ?Z, _} -> {:ok, linhas}
      {:ok, ?E, resto} -> {:error, erro_de(resto)}
      {:ok, _tipo, _resto} -> ler_ate_pronto(socket, linhas)
      {:error, motivo} -> {:error, motivo}
    end
  end

  defp linha_de(<<quantidade::16, resto::binary>>), do: campos(resto, quantidade, [])

  defp campos(_resto, 0, acumulado), do: Enum.reverse(acumulado)

  defp campos(<<-1::signed-32, resto::binary>>, quantidade, acumulado),
    do: campos(resto, quantidade - 1, [nil | acumulado])

  defp campos(<<tamanho::signed-32, valor::binary-size(tamanho), resto::binary>>, quantidade, acumulado),
    do: campos(resto, quantidade - 1, [valor | acumulado])

  defp erro_de(dados) do
    campos =
      for campo <- String.split(dados, <<0>>), campo != "",
          <<tipo, texto::binary>> = campo,
          do: {tipo, texto}

    mensagem = campos |> Enum.find_value(fn {tipo, texto} -> if tipo == ?M, do: texto end) |> Kernel.||("erro")
    codigo = campos |> Enum.find_value(fn {tipo, texto} -> if tipo == ?C, do: texto end)
    "#{codigo} #{mensagem}"
  end

  defp enviar(socket, tipo, payload) do
    :ok = :gen_tcp.send(socket, [<<tipo>>, <<IO.iodata_length(payload) + 4::32>>, payload])
  end

  defp ler_mensagem(socket) do
    case :gen_tcp.recv(socket, 5, 30_000) do
      {:ok, <<tipo, tamanho::32>>} ->
        case :gen_tcp.recv(socket, tamanho - 4, 30_000) do
          {:ok, dados} -> {:ok, tipo, dados}
          {:error, motivo} -> {:error, motivo}
        end

      {:error, motivo} ->
        {:error, motivo}
    end
  end
end
