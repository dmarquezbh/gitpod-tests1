// Kotlin "platform" entry: HttpServer do JDK (sem framework) + JDBC (PostgreSQL).
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.sql.Connection
import java.sql.DriverManager
import java.util.concurrent.Executors
import kotlin.random.Random

val url = "jdbc:postgresql://127.0.0.1/hello_world?user=benchmarkdbuser&password=benchmarkdbpass"
val pool = Array(8) { DriverManager.getConnection(url) }
val rnd = Random(System.nanoTime())
var proximo = 0

fun conn(): Connection {
    val i = (proximo++ and Int.MAX_VALUE) % pool.size
    return pool[i]
}

fun qtd(qs: String?): Int {
    val v = qs?.split("&")?.firstOrNull { it.startsWith("q=") }?.substring(2)?.toIntOrNull() ?: 1
    return v.coerceIn(1, 500)
}

fun escape(s: String): String = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

fun main() {
    val port = System.getenv("PORT")?.toInt() ?: 8096
    val server = HttpServer.create(InetSocketAddress("0.0.0.0", port), 4096)
    server.executor = Executors.newFixedThreadPool(4)
    server.createContext("/") { troca ->
        val path = troca.requestURI.path
        val qs = troca.requestURI.query
        val corpo: String
        val tipo: String
        when {
            path == "/plaintext" -> { corpo = "Hello, World!"; tipo = "text/plain" }
            path == "/json" -> { corpo = "{\"message\":\"Hello, World!\"}"; tipo = "application/json" }
            path == "/db" -> {
                val id = rnd.nextInt(1, 10001)
                conn().prepareStatement("SELECT id, randomnumber FROM world WHERE id = ?").use { ps ->
                    ps.setInt(1, id)
                    ps.executeQuery().use { rs ->
                        rs.next()
                        corpo = "{\"id\":${rs.getInt(1)},\"randomNumber\":${rs.getInt(2)}}"
                    }
                }
                tipo = "application/json"
            }
            path == "/queries" -> {
                val q = qtd(qs)
                val ids = List(q) { rnd.nextInt(1, 10001) }
                val porId = HashMap<Int, Int>()
                conn().createStatement().use { st ->
                    val sql = "SELECT id, randomnumber FROM world WHERE id IN (${ids.joinToString(",")})"
                    st.executeQuery(sql).use { rs -> while (rs.next()) porId[rs.getInt(1)] = rs.getInt(2) }
                }
                corpo = "[" + ids.joinToString(",") { id -> "{\"id\":$id,\"randomNumber\":${porId[id] ?: 0}}" } + "]"
                tipo = "application/json"
            }
            path == "/updates" -> {
                val q = qtd(qs)
                val pares = List(q) { rnd.nextInt(1, 10001) to rnd.nextInt(1, 10001) }
                val values = pares.joinToString(",") { (id, rn) -> "($id,$rn)" }
                val porId = HashMap<Int, Int>()
                conn().createStatement().use { st ->
                    val sql = "UPDATE world SET randomnumber = v.rn FROM (VALUES $values) AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber"
                    st.executeQuery(sql).use { rs -> while (rs.next()) porId[rs.getInt(1)] = rs.getInt(2) }
                }
                corpo = "[" + pares.joinToString(",") { (id, rn) -> "{\"id\":$id,\"randomNumber\":${porId[id] ?: rn}}" } + "]"
                tipo = "application/json"
            }
            path == "/fortunes" -> {
                val itens = ArrayList<Pair<Int, String>>()
                conn().createStatement().use { st ->
                    st.executeQuery("SELECT id, message FROM fortune").use { rs ->
                        while (rs.next()) itens.add(rs.getInt(1) to rs.getString(2))
                    }
                }
                itens.add(0 to "Additional fortune added at request time.")
                itens.sortBy { it.second }
                val html = StringBuilder("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>")
                for ((id, msg) in itens) html.append("<tr><td>$id</td><td>${escape(msg)}</td></tr>")
                html.append("</table></body></html>")
                corpo = html.toString()
                tipo = "text/html; charset=utf-8"
            }
            else -> { corpo = ""; tipo = "text/plain" }
        }
        val bytes = corpo.toByteArray()
        troca.responseHeaders.add("Content-Type", tipo)
        troca.sendResponseHeaders(if (corpo.isEmpty()) 404 else 200, bytes.size.toLong())
        troca.responseBody.use { it.write(bytes) }
    }
    server.start()
    println("kotlin-platform on :$port")
}
