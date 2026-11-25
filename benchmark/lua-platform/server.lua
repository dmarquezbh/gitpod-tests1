-- Lua "platform" entry (LuaJIT): sockets e libpq via FFI, um loop por processo com SO_REUSEPORT.
-- Sem framework HTTP e sem driver Lua: a mesma libpq (C) das outras entradas.
local ffi = require("ffi")
ffi.cdef[[
typedef struct PGconn PGconn;
typedef struct PGresult PGresult;
PGconn* PQconnectdb(const char*);
PGresult* PQexec(PGconn*, const char*);
PGresult* PQexecParams(PGconn*, const char*, int, void*, const char* const*, void*, void*, int);
int PQntuples(const PGresult*);
char* PQgetvalue(const PGresult*, int, int);
void PQclear(PGresult*);
int socket(int, int, int);
int setsockopt(int, int, int, const void*, unsigned int);
int bind(int, const void*, unsigned int);
int listen(int, int);
int accept(int, void*, unsigned int*);
long read(int, void*, unsigned long);
long write(int, const void*, unsigned long);
int fork(void);
]]
local C = ffi.C
local pq = ffi.load("pq")
local socket, setsockopt, bind, listen, accept, read, write, fork =
  C.socket, C.setsockopt, C.bind, C.listen, C.accept, C.read, C.write, C.fork

local PORT = tonumber(os.getenv("PORT") or "8094")
local WORKERS = tonumber(os.getenv("WORKERS") or "2")
local DB = os.getenv("DB_URL") or "postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world"
local conn = pq.PQconnectdb(DB)
if conn == nil then error("libpq: sem conexão") end
local AF_INET, SOCK_STREAM, SOL_SOCKET, SO_REUSEADDR, SO_REUSEPORT = 2, 1, 1, 2, 15
local buf = ffi.new("char[?]", 65536)

local function query(sql)
  local r = pq.PQexec(conn, sql)
  local n = pq.PQntuples(r)
  local rows = {}
  for i = 0, n - 1 do
    rows[i + 1] = { ffi.string(pq.PQgetvalue(r, i, 0)), ffi.string(pq.PQgetvalue(r, i, 1)) }
  end
  pq.PQclear(r)
  return rows
end

local function listen_socket()
  local fd = socket(AF_INET, SOCK_STREAM, 0)
  local um = ffi.new("int[1]", 1)
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, um, 4)
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, um, 4)
  local addr = ffi.new("uint8_t[16]")
  addr[0] = AF_INET; addr[1] = 0
  addr[2] = 0; addr[3] = 0  -- porta em big-endian preenchida abaixo
  local p = PORT
  addr[2] = math.floor(p / 256); addr[3] = p % 256
  for i = 4, 7 do addr[i] = 0 end
  assert(bind(fd, addr, 16) == 0, "bind")
  assert(listen(fd, 4096) == 0, "listen")
  return fd
end

local function esc(s)
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
  return s
end

local function fortunes()
  local rows = query("SELECT id, message FROM fortune")
  table.insert(rows, { "0", "Additional fortune added at request time." })
  table.sort(rows, function(a, b) return a[2] < b[2] end)
  local t = { "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>" }
  for _, r in ipairs(rows) do
    t[#t + 1] = "<tr><td>" .. r[1] .. "</td><td>" .. esc(r[2]) .. "</td></tr>"
  end
  t[#t + 1] = "</table></body></html>"
  return table.concat(t)
end

local function qtd(path)
  local n = tonumber(path:match("[?&]q=(%d+)")) or 1
  if n < 1 then n = 1 elseif n > 500 then n = 500 end
  return n
end

local function handler(path)
  if path == "/plaintext" then return "Hello, World!", "text/plain" end
  if path == "/json" then return '{"message":"Hello, World!"}', "application/json" end
  if path == "/db" then
    local id = math.random(1, 10000)
    local r = query("SELECT id, randomnumber FROM world WHERE id = " .. id)
    return '{"id":' .. r[1][1] .. ',"randomNumber":' .. r[1][2] .. '}', "application/json"
  end
  if path:sub(1, 8) == "/queries" then
    local q = qtd(path)
    local ids, lista = {}, {}
    for i = 1, q do ids[i] = math.random(1, 10000); lista[i] = tostring(ids[i]) end
    local rows = query("SELECT id, randomnumber FROM world WHERE id IN (" .. table.concat(lista, ",") .. ")")
    local porId = {}
    for _, r in ipairs(rows) do porId[tonumber(r[1])] = r[2] end
    local out = {}
    for i, id in ipairs(ids) do out[i] = '{"id":' .. id .. ',"randomNumber":' .. (porId[id] or 0) .. '}' end
    return "[" .. table.concat(out, ",") .. "]", "application/json"
  end
  if path:sub(1, 8) == "/updates" then
    local q = qtd(path)
    local pares = {}
    for i = 1, q do pares[#pares + 1] = "(" .. math.random(1, 10000) .. "," .. math.random(1, 10000) .. ")" end
    local rows = query("UPDATE world SET randomnumber = v.rn FROM (VALUES " .. table.concat(pares, ",") ..
      ") AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber")
    local porId = {}
    for _, r in ipairs(rows) do porId[tonumber(r[1])] = r[2] end
    local out = {}
    for i, r in ipairs(rows) do out[i] = '{"id":' .. r[1] .. ',"randomNumber":' .. r[2] .. '}' end
    return "[" .. table.concat(out, ",") .. "]", "application/json"
  end
  if path == "/fortunes" then return fortunes(), "text/html; charset=utf-8" end
  return "", nil
end

local function resp(corpo, tipo)
  if tipo == nil then return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" end
  return "HTTP/1.1 200 OK\r\nContent-Type: " .. tipo .. "\r\nContent-Length: " .. #corpo .. "\r\n\r\n" .. corpo
end

local function worker(lsock)
  while true do
    local fd = accept(lsock, nil, nil)
    if fd >= 0 then
      local total = read(fd, buf, 65536)
      if total > 0 then
        local req = ffi.string(buf, total)
        local path = req:match("^GET (%S+) ")
        if path then
          local corpo, tipo = handler(path)
          local r = resp(corpo, tipo)
          local enviado = 0
          while enviado < #r do enviado = enviado + write(fd, r:sub(enviado + 1), #r - enviado) end
        end
      end
    end
  end
end

math.randomseed(os.time() + (tonumber(os.getenv("WORKER") or "0")))
local lsock = listen_socket()
if WORKERS > 1 then
  for _ = 2, WORKERS do
    if fork() == 0 then break end
  end
end
worker(lsock)
