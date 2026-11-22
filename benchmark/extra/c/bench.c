// TechEmpower-style benchmark server in C: thread per connection, keep-alive,
// libpq connection pool. Endpoints: plaintext, json, db, queries, fortunes, updates.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <libpq-fe.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define POOL_SIZE 16
#define MAX_REQ 65536
#define OUT_CAP (1 << 20)

static PGconn *g_pool[POOL_SIZE];
static int g_pool_n;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;

static const char *g_conninfo;

static PGconn *db_acquire(void) {
    pthread_mutex_lock(&g_lock);
    while (g_pool_n == 0) pthread_cond_wait(&g_cond, &g_lock);
    PGconn *c = g_pool[--g_pool_n];
    pthread_mutex_unlock(&g_lock);
    return c;
}
static void db_release(PGconn *c) {
    if (!c) return;
    if (PQstatus(c) != CONNECTION_OK) {
        PQreset(c);
    }
    pthread_mutex_lock(&g_lock);
    g_pool[g_pool_n++] = c;
    pthread_cond_signal(&g_cond);
    pthread_mutex_unlock(&g_lock);
}

static __thread unsigned int g_seed;
static int rand_id(void) { return (int)(rand_r(&g_seed) % 10000u) + 1; }

static size_t html_escape(char *dst, const char *src) {
    char *d = dst;
    for (const unsigned char *p = (const unsigned char *)src; *p; p++) {
        switch (*p) {
            case '&': memcpy(d, "&amp;", 5); d += 5; break;
            case '<': memcpy(d, "&lt;", 4); d += 4; break;
            case '>': memcpy(d, "&gt;", 4); d += 4; break;
            case '"': memcpy(d, "&quot;", 6); d += 6; break;
            case '\'': memcpy(d, "&#x27;", 6); d += 6; break;
            case '/': memcpy(d, "&#x2F;", 6); d += 6; break;
            default: *d++ = (char)*p;
        }
    }
    *d = 0;
    return (size_t)(d - dst);
}

static void send_all(int fd, const char *buf, size_t len) {
    while (len) {
        ssize_t n = send(fd, buf, len, MSG_NOSIGNAL);
        if (n <= 0) return;
        buf += n;
        len -= (size_t)n;
    }
}

static int clamp_q(const char *s) {
    if (!s) return 1;
    int q = atoi(s);
    if (q < 1) q = 1;
    if (q > 500) q = 500;
    return q;
}

static const char *query_param(const char *target, const char *name, char *scratch) {
    const char *q = strchr(target, '?');
    if (!q) return NULL;
    size_t nlen = strlen(name);
    const char *p = q + 1;
    while (*p) {
        const char *eq = strchr(p, '=');
        if (!eq) break;
        const char *amp = strchr(eq + 1, '&');
        size_t klen = (size_t)(eq - p);
        if (klen == nlen && !strncmp(p, name, nlen)) {
            size_t vlen = amp ? (size_t)(amp - eq - 1) : strlen(eq + 1);
            if (vlen >= 32) vlen = 31;
            memcpy(scratch, eq + 1, vlen);
            scratch[vlen] = 0;
            return scratch;
        }
        if (!amp) break;
        p = amp + 1;
    }
    return NULL;
}

static void respond(int fd, const char *ctype, const char *body, size_t blen) {
    char head[256];
    int n = snprintf(head, sizeof head,
                     "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %zu\r\n\r\n",
                     ctype, blen);
    char *resp = malloc((size_t)n + blen);
    if (!resp) return;
    memcpy(resp, head, (size_t)n);
    memcpy(resp + n, body, blen);
    send_all(fd, resp, (size_t)n + blen);
    free(resp);
}

static size_t render_fortunes(char *out, size_t cap) {
    PGconn *c = db_acquire();
    PGresult *r = PQexec(c, "SELECT id, message FROM fortune");
    if (!r || PQresultStatus(r) != PGRES_TUPLES_OK) {
        if (r) PQclear(r);
        db_release(c);
        return 0;
    }
    int n = PQntuples(r);
    typedef struct { int id; char *msg; } Row;
    Row *rows = malloc(sizeof(Row) * (size_t)(n + 1));
    for (int i = 0; i < n; i++) {
        rows[i].id = atoi(PQgetvalue(r, i, 0));
        rows[i].msg = strdup(PQgetvalue(r, i, 1));
    }
    PQclear(r);
    db_release(c);
    rows[n].id = 0;
    rows[n].msg = strdup("Additional fortune added at request time.");
    int total = n + 1;
    for (int i = 1; i < total; i++) {
        Row key = rows[i];
        int j = i - 1;
        while (j >= 0 && strcmp(rows[j].msg, key.msg) > 0) { rows[j + 1] = rows[j]; j--; }
        rows[j + 1] = key;
    }
    size_t len = 0;
    len += (size_t)snprintf(out + len, cap - len,
        "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>"
        "<tr><th>id</th><th>message</th></tr>");
    for (int i = 0; i < total; i++) {
        len += (size_t)snprintf(out + len, cap - len, "<tr><td>%d</td><td>", rows[i].id);
        len += html_escape(out + len, rows[i].msg);
        len += (size_t)snprintf(out + len, cap - len, "</td></tr>");
        free(rows[i].msg);
    }
    len += (size_t)snprintf(out + len, cap - len, "</table></body></html>");
    free(rows);
    return len;
}

static size_t run_db(char *out, size_t cap) {
    char idbuf[16];
    snprintf(idbuf, sizeof idbuf, "%d", rand_id());
    const char *params[1] = {idbuf};
    PGconn *c = db_acquire();
    PGresult *r = PQexecParams(c, "SELECT id, randomnumber FROM world WHERE id = $1",
                               1, NULL, params, NULL, NULL, 0);
    size_t len = 0;
    if (r && PQresultStatus(r) == PGRES_TUPLES_OK && PQntuples(r) == 1)
        len = (size_t)snprintf(out, cap, "{\"id\":%s,\"randomNumber\":%s}",
                               PQgetvalue(r, 0, 0), PQgetvalue(r, 0, 1));
    if (r) PQclear(r);
    db_release(c);
    return len;
}

static size_t run_queries(char *out, size_t cap, int q) {
    PGconn *c = db_acquire();
    size_t len = 1;
    out[0] = '[';
    for (int i = 0; i < q; i++) {
        char idbuf[16];
        snprintf(idbuf, sizeof idbuf, "%d", rand_id());
        const char *params[1] = {idbuf};
        PGresult *r = PQexecParams(c, "SELECT id, randomnumber FROM world WHERE id = $1",
                                   1, NULL, params, NULL, NULL, 0);
        if (r && PQresultStatus(r) == PGRES_TUPLES_OK && PQntuples(r) == 1) {
            len += (size_t)snprintf(out + len, cap - len,
                                    "%s{\"id\":%s,\"randomNumber\":%s}",
                                    i ? "," : "", PQgetvalue(r, 0, 0), PQgetvalue(r, 0, 1));
        }
        if (r) PQclear(r);
    }
    out[len++] = ']';
    out[len] = 0;
    db_release(c);
    return len;
}

static size_t run_updates(char *out, size_t cap, int q) {
    PGconn *c = db_acquire();
    int ids[500], rns[500];
    char idsbuf[500][16];
    for (int i = 0; i < q; i++) {
        ids[i] = rand_id();
        snprintf(idsbuf[i], sizeof idsbuf[i], "%d", ids[i]);
        const char *params[1] = {idsbuf[i]};
        PGresult *r = PQexecParams(c, "SELECT id, randomnumber FROM world WHERE id = $1",
                                   1, NULL, params, NULL, NULL, 0);
        rns[i] = 1;
        if (r && PQresultStatus(r) == PGRES_TUPLES_OK && PQntuples(r) == 1)
            rns[i] = atoi(PQgetvalue(r, 0, 1));
        if (r) PQclear(r);
    }
    size_t len = 1;
    out[0] = '[';
    for (int i = 0; i < q; i++) {
        int newrn = (int)(rand_r(&g_seed) % 10000u) + 1;
        char nbuf[16], ibuf[16];
        snprintf(nbuf, sizeof nbuf, "%d", newrn);
        snprintf(ibuf, sizeof ibuf, "%d", ids[i]);
        const char *params[2] = {nbuf, ibuf};
        PGresult *r = PQexecParams(c, "UPDATE world SET randomnumber = $1 WHERE id = $2",
                                   2, NULL, params, NULL, NULL, 0);
        if (r) PQclear(r);
        len += (size_t)snprintf(out + len, cap - len,
                                "%s{\"id\":%d,\"randomNumber\":%d}", i ? "," : "", ids[i], newrn);
    }
    out[len++] = ']';
    out[len] = 0;
    db_release(c);
    return len;
}

static void handle(int fd) {
    char *buf = malloc(MAX_REQ);
    char *out = malloc(OUT_CAP);
    if (!buf || !out) { close(fd); free(buf); free(out); return; }
    size_t len = 0;
    g_seed = (unsigned int)(time(NULL) ^ (uintptr_t)pthread_self());
    for (;;) {
        ssize_t n = recv(fd, buf + len, MAX_REQ - len, 0);
        if (n <= 0) break;
        len += (size_t)n;
        size_t off = 0;
        for (;;) {
            char *hdr_end = NULL;
            for (size_t i = off; i + 3 < len; i++) {
                if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n') {
                    hdr_end = buf + i;
                    break;
                }
            }
            if (!hdr_end) break;
            char *line_end = memchr(buf + off, ' ', len - off);
            char target[2048] = {0};
            if (line_end) {
                char *tstart = line_end + 1;
                char *tend = memchr(tstart, ' ', (size_t)(hdr_end - tstart));
                if (tend) {
                    size_t tlen = (size_t)(tend - tstart);
                    if (tlen >= sizeof target) tlen = sizeof target - 1;
                    memcpy(target, tstart, tlen);
                }
            }
            char scratch[64];
            const char *body = NULL;
            size_t blen = 0;
            const char *ctype = "text/plain; charset=utf-8";
            if (!strcmp(target, "/plaintext")) {
                body = "Hello, World!";
                blen = 13;
            } else if (!strcmp(target, "/json")) {
                body = "{\"message\":\"Hello, World!\"}";
                blen = 27;
                ctype = "application/json";
            } else if (!strcmp(target, "/db")) {
                blen = run_db(out, OUT_CAP);
                body = out;
                ctype = "application/json";
            } else if (!strncmp(target, "/queries", 8)) {
                const char *v = query_param(target, "q", scratch);
                if (!v) v = query_param(target, "queries", scratch);
                blen = run_queries(out, OUT_CAP, clamp_q(v));
                body = out;
                ctype = "application/json";
            } else if (!strncmp(target, "/updates", 8)) {
                const char *v = query_param(target, "q", scratch);
                if (!v) v = query_param(target, "queries", scratch);
                blen = run_updates(out, OUT_CAP, clamp_q(v));
                body = out;
                ctype = "application/json";
            } else if (!strcmp(target, "/fortunes")) {
                blen = render_fortunes(out, OUT_CAP);
                body = out;
                ctype = "text/html; charset=utf-8";
            } else {
                body = "Not Found";
                blen = 9;
                ctype = "text/plain";
            }
            respond(fd, ctype, body, blen);
            off = (size_t)(hdr_end - buf) + 4;
        }
        if (off) {
            memmove(buf, buf + off, len - off);
            len -= off;
        }
        if (len == MAX_REQ) break;
    }
    free(buf);
    free(out);
    close(fd);
}

static void *conn_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    handle(fd);
    return NULL;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    int port = argc > 1 ? atoi(argv[1]) : 18089;
    g_conninfo = getenv("POSTGRES_URL");
    if (!g_conninfo)
        g_conninfo = "postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world";

    for (int i = 0; i < POOL_SIZE; i++) {
        PGconn *c = PQconnectdb(g_conninfo);
        if (PQstatus(c) != CONNECTION_OK) {
            fprintf(stderr, "db connect failed: %s\n", PQerrorMessage(c));
            return 1;
        }
        g_pool[g_pool_n++] = c;
    }

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof addr) || listen(lfd, 4096)) {
        perror("bind/listen");
        return 1;
    }
    printf("started C server on port %d (pool %d)\n", port, POOL_SIZE);
    fflush(stdout);

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 256 * 1024);
    for (;;) {
        int fd = accept(lfd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            continue;
        }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        pthread_t t;
        if (pthread_create(&t, &attr, conn_thread, (void *)(intptr_t)fd) != 0) close(fd);
    }
    return 0;
}
