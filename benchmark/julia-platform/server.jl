# Julia "platform" entry: HTTP.jl (servidor) + LibPQ (C) direto, os seis testes.
using HTTP, LibPQ

const PORT = parse(Int, get(ENV, "PORT", "8097"))
const CONNINFO = get(ENV, "DB_URL", "postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world")
const NT = max(1, Threads.nthreads())
const conns = [LibPQ.Connection(CONNINFO) for _ in 1:NT]
conn() = conns[Threads.threadid()]

qtd(uri) = (m = match(r"[?&]q=(\d+)", uri); m === nothing ? 1 : clamp(parse(Int, m.captures[1]), 1, 500))

function consulta(sql)
    r = execute(conn(), sql)
    linhas = [(Int(first(linha)), Int(last(linha))) for linha in r]
    close(r)
    linhas
end

function fortunes_html()
    linhas = consulta("SELECT id, message FROM fortune")
    push!(linhas, (0, "Additional fortune added at request time."))
    ordenadas = sort(linhas, by = l -> l[2])
    io = IOBuffer()
    print(io, "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>")
    for (id, msg) in ordenadas
        print(io, "<tr><td>", id, "</td><td>", escapeHTML(msg), "</td></tr>")
    end
    print(io, "</table></body></html>")
    String(take!(io))
end

function handler(req::HTTP.Request)
    caminho = HTTP.URI(req.target).path
    if caminho == "/plaintext"
        HTTP.Response(200, ["Content-Type" => "text/plain"], "Hello, World!")
    elseif caminho == "/json"
        HTTP.Response(200, ["Content-Type" => "application/json"], "{\"message\":\"Hello, World!\"}")
    elseif caminho == "/db"
        id = rand(1:10000)
        r = consulta("SELECT id, randomnumber FROM world WHERE id = $id")
        HTTP.Response(200, ["Content-Type" => "application/json"], "{\"id\":$(r[1][1]),\"randomNumber\":$(r[1][2])}")
    elseif startswith(caminho, "/queries")
        q = qtd(req.target)
        ids = [rand(1:10000) for _ in 1:q]
        lista = join(ids, ",")
        r = consulta("SELECT id, randomnumber FROM world WHERE id IN ($lista)")
        porid = Dict(l[1] => l[2] for l in r)
        corpo = join(("{\"id\":$id,\"randomNumber\":$(get(porid, id, 0))}" for id in ids), ",")
        HTTP.Response(200, ["Content-Type" => "application/json"], "[$corpo]")
    elseif startswith(caminho, "/updates")
        q = qtd(req.target)
        ids = [rand(1:10000) for _ in 1:q]
        novos = [rand(1:10000) for _ in 1:q]
        valores = join(("($(ids[i]),$(novos[i]))" for i in 1:q), ",")
        r = consulta("UPDATE world SET randomnumber = v.rn FROM (VALUES $valores) AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber")
        porid = Dict(l[1] => l[2] for l in r)
        corpo = join(("{\"id\":$(ids[i]),\"randomNumber\":$(get(porid, ids[i], novos[i]))}" for i in 1:q), ",")
        HTTP.Response(200, ["Content-Type" => "application/json"], "[$corpo]")
    elseif caminho == "/fortunes"
        HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], fortunes_html())
    else
        HTTP.Response(404, "")
    end
end

HTTP.serve(handler, "0.0.0.0", PORT)
