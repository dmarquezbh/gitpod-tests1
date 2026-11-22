# TechEmpower-style benchmark server: WEBrick + pg (thread-per-connection, connection pool).
require "webrick"
require "pg"
require "json"

PORT = (ARGV[0] || 18088).to_i
POOL_SIZE = (ENV["POOL_SIZE"] || 16).to_i

pool = Queue.new
POOL_SIZE.times do
  pool << PG.connect(host: "127.0.0.1", port: 5432, dbname: "hello_world",
                     user: "benchmarkdbuser", password: "benchmarkdbpass")
end

def rand_id
  rand(1..10000)
end

def clamp_q(v)
  n = v.to_i
  n = 1 if n < 1
  n = 500 if n > 500
  n
end

def escape_html(s)
  s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
   .gsub('"', "&quot;").gsub("'", "&#x27;").gsub("/", "&#x2F;")
end

def world(conn, id)
  conn.exec_params("SELECT id, randomnumber FROM world WHERE id = $1", [id]).first
end

server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: "0.0.0.0",
  DoNotReverseLookup: true,
  MaxClients: 1024,
  Logger: WEBrick::Log.new(File::NULL),
  AccessLog: []
)

server.mount_proc("/") do |req, res|
  begin
    case req.path
    when "/plaintext"
      res["Content-Type"] = "text/plain"
      res.body = "Hello, World!"
    when "/json"
      res["Content-Type"] = "application/json"
      res.body = '{"message":"Hello, World!"}'
    when "/db"
      conn = pool.pop
      begin
        row = world(conn, rand_id)
        res["Content-Type"] = "application/json"
        res.body = %({"id":#{row["id"]},"randomNumber":#{row["randomnumber"]}})
      ensure
        pool << conn
      end
    when "/queries"
      q = clamp_q(req.query["q"] || req.query["queries"])
      conn = pool.pop
      begin
        rows = Array.new(q) { world(conn, rand_id) }
        res["Content-Type"] = "application/json"
        res.body = "[" + rows.map { |r| %({"id":#{r["id"]},"randomNumber":#{r["randomnumber"]}}) }.join(",") + "]"
      ensure
        pool << conn
      end
    when "/updates"
      q = clamp_q(req.query["q"] || req.query["queries"])
      conn = pool.pop
      begin
        out = []
        q.times do
          row = world(conn, rand_id)
          new_rn = rand_id
          conn.exec_params("UPDATE world SET randomnumber = $1 WHERE id = $2", [new_rn, row["id"]])
          out << %({"id":#{row["id"]},"randomNumber":#{new_rn}})
        end
        res["Content-Type"] = "application/json"
        res.body = "[" + out.join(",") + "]"
      ensure
        pool << conn
      end
    when "/fortunes"
      conn = pool.pop
      begin
        rows = conn.exec("SELECT id, message FROM fortune").map { |r| [r["id"].to_i, r["message"]] }
        rows << [0, "Additional fortune added at request time."]
        rows.sort_by! { |r| r[1] }
        body = +"<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>" \
                "<tr><th>id</th><th>message</th></tr>"
        rows.each do |id, msg|
          body << "<tr><td>#{id}</td><td>#{escape_html(msg)}</td></tr>"
        end
        body << "</table></body></html>"
        res["Content-Type"] = "text/html; charset=utf-8"
        res.body = body
      ensure
        pool << conn
      end
    else
      res.status = 404
      res["Content-Type"] = "text/plain"
      res.body = "Not Found"
    end
  rescue => e
    res.status = 500
    res["Content-Type"] = "text/plain"
    res.body = "error: #{e.class}"
  end
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }
puts "started Ruby server on port #{PORT} (pool #{POOL_SIZE})"
server.start
