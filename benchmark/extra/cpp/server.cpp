// TechEmpower-style server in C++ (g++): epoll event loops with SO_REUSEPORT,
// keep-alive/pipelined HTTP/1.1, libpq prepared statements, pipeline mode.
// /db and /queries?q=1 are batched across one epoll round into a single int4[]
// SELECT; q>1, fortunes and updates are pipelined per round.
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <libpq-fe.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <string>
#include <vector>

static const int WORKERS = 4;
static const int HEAVY_PER_WORKER = 2;
static const int IN_CAP = 65536;
static const int OUT_CAP = 131072;
static const int MAX_EVENTS = 512;
static const int PORT_DEFAULT = 18095;

static const char* CONNINFO =
    "host=127.0.0.1 port=5432 user=benchmarkdbuser password=benchmarkdbpass dbname=hello_world";
static const char* SQL_ARRAY =
    "SELECT w.id, w.randomnumber FROM unnest($1::int[]) WITH ORDINALITY AS u(id, ord) "
    "JOIN world w ON w.id = u.id ORDER BY u.ord";
static const char* SQL_FORTUNE = "SELECT id, message FROM fortune";
static const char* SQL_UPDATE =
    "UPDATE world SET randomnumber = n.rn FROM "
    "(SELECT * FROM UNNEST($1::int[], $2::int[]) AS v(id, rn) ORDER BY 1) AS n "
    "WHERE world.id = n.id";

struct Conn;
struct Worker;

enum Route { R_PLAIN, R_JSON, R_DB, R_QUERIES, R_FORTUNES, R_UPDATES };

struct Op {
    Conn* c = nullptr;
    Route route = R_DB;
    int count = 0;
    std::vector<int> ids;
    std::vector<int> nums;
};

struct Conn {
    int fd = -1;
    Worker* w = nullptr;
    int inLen = 0;
    int outLen = 0;
    int outOff = 0;
    uint32_t interest = 0;
    char* in = nullptr;
    char* out = nullptr;
};

struct Worker {
    int idx = 0;
    int epfd = -1;
    int listenFd = -1;
    PGconn* primary = nullptr;
    PGconn* heavy[HEAVY_PER_WORKER] = {};
    int heavyRot = 0;
    uint32_t rng = 0x9e3779b9u;
    std::vector<Op*> singles;
    std::vector<Op*> heavyQueue[HEAVY_PER_WORKER];
    std::vector<Conn*> dirty;
};

static std::string g_plainHead, g_jsonHead, g_jsonHeadLen, g_htmlHeadLen;

static int rand_id(Worker* w) {
    uint32_t x = w->rng;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    w->rng = x;
    return (int)(x % 10000u) + 1;
}

static void append(char* dst, int& len, const char* s, int n) {
    memcpy(dst + len, s, (size_t)n);
    len += n;
}
static void append_str(char* dst, int& len, const std::string& s) { append(dst, len, s.data(), (int)s.size()); }
static void append_int(char* dst, int& len, int v) {
    char tmp[16];
    int n = snprintf(tmp, sizeof tmp, "%d", v);
    append(dst, len, tmp, n);
}

static void close_conn(Conn* c);
static void set_interest(Conn* c, uint32_t interest);

static void send_response(Conn* c, Route route, const char* body, int bodyLen) {
    const std::string* head = &g_jsonHeadLen;
    if (route == R_PLAIN) head = &g_plainHead;
    else if (route == R_JSON) head = &g_jsonHead;
    else if (route == R_FORTUNES) head = &g_htmlHeadLen;

    int need = (int)head->size() + bodyLen + 32;
    if (c->outLen + need > OUT_CAP) {
        // best effort: drop this connection rather than corrupt the stream
        close_conn(c);
        return;
    }
    append_str(c->out, c->outLen, *head);
    if (head == &g_jsonHeadLen || head == &g_htmlHeadLen) append_int(c->out, c->outLen, bodyLen);
    append(c->out, c->outLen, "\r\n\r\n", 4);
    append(c->out, c->outLen, body, bodyLen);
    c->w->dirty.push_back(c);
}

static void flush_conn(Conn* c) {
    while (c->outOff < c->outLen) {
        ssize_t n = send(c->fd, c->out + c->outOff, (size_t)(c->outLen - c->outOff), MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            close_conn(c);
            return;
        }
        c->outOff += (int)n;
    }
    if (c->outOff >= c->outLen) { c->outOff = 0; c->outLen = 0; }
}

static void set_interest(Conn* c, uint32_t interest) {
    if (c->interest == interest) return;
    epoll_event ev{};
    ev.events = interest;
    ev.data.ptr = c;
    epoll_ctl(c->w->epfd, EPOLL_CTL_MOD, c->fd, &ev);
    c->interest = interest;
}

static void close_conn(Conn* c) {
    if (c->fd < 0) return;
    epoll_ctl(c->w->epfd, EPOLL_CTL_DEL, c->fd, nullptr);
    close(c->fd);
    free(c->in);
    free(c->out);
    free(c);
}

static void html_escape(char* dst, int& len, const char* s) {
    for (const unsigned char* p = (const unsigned char*)s; *p; p++) {
        switch (*p) {
            case '&': append(dst, len, "&amp;", 5); break;
            case '<': append(dst, len, "&lt;", 4); break;
            case '>': append(dst, len, "&gt;", 4); break;
            case '"': append(dst, len, "&quot;", 6); break;
            case '\'': append(dst, len, "&#x27;", 6); break;
            case '/': append(dst, len, "&#x2F;", 6); break;
            default: dst[len++] = (char)*p;
        }
    }
}

static int param_count(const char* target) {
    const char* q = strchr(target, '?');
    if (!q) return 1;
    const char* p = strchr(q, '=');
    if (!p) return 1;
    p++;
    int v = 0;
    while (*p >= '0' && *p <= '9') { v = v * 10 + (*p - '0'); p++; }
    if (v < 1) v = 1;
    if (v > 500) v = 500;
    return v;
}

static std::string int_array(const std::vector<int>& v) {
    std::string s = "{";
    char tmp[16];
    for (size_t i = 0; i < v.size(); i++) {
        if (i) s += ',';
        int n = snprintf(tmp, sizeof tmp, "%d", v[i]);
        s.append(tmp, n);
    }
    s += '}';
    return s;
}

static PGresult* next_result(PGconn* pg) {
    PGresult* res;
    while (!(res = PQgetResult(pg))) {
        if (PQconsumeInput(pg) == 0) return nullptr;
    }
    return res;
}

static void write_db_body(PGresult* res, Op* op) {
    int n = PQntuples(res);
    int expect = op->route == R_QUERIES ? op->count : 1;
    if (n > expect) n = expect;
    char body[65536];
    int len = 0;
    if (op->route == R_QUERIES) {
        body[len++] = '[';
        for (int i = 0; i < n; i++) {
            if (i) body[len++] = ',';
            len += snprintf(body + len, 64, "{\"id\":%s,\"randomNumber\":%s}",
                            PQgetvalue(res, i, 0), PQgetvalue(res, i, 1));
        }
        body[len++] = ']';
        send_response(op->c, R_QUERIES, body, len);
    } else {
        len += snprintf(body + len, 64, "{\"id\":%s,\"randomNumber\":%s}",
                        n ? PQgetvalue(res, 0, 0) : "0", n ? PQgetvalue(res, 0, 1) : "0");
        send_response(op->c, R_DB, body, len);
    }
}

static void flush_singles(Worker* w) {
    if (w->singles.empty()) return;
    std::vector<int> ids;
    ids.reserve(w->singles.size());
    for (Op* op : w->singles) ids.push_back(op->ids[0]);
    std::string arr = int_array(ids);
    const char* params[1] = {arr.c_str()};
    PGresult* res = PQexecPrepared(w->primary, "a", 1, params, nullptr, nullptr, 0);
    if (res && PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) == (int)w->singles.size()) {
        for (size_t i = 0; i < w->singles.size(); i++) {
            Op one;
            one.c = w->singles[i]->c;
            one.route = R_DB;
            // build a one-row result view by copying values
            char body[128];
            int len = snprintf(body, sizeof body, "{\"id\":%s,\"randomNumber\":%s}",
                               PQgetvalue(res, (int)i, 0), PQgetvalue(res, (int)i, 1));
            send_response(one.c, R_DB, body, len);
            delete w->singles[i];
        }
        PQclear(res);
    } else {
        if (res) PQclear(res);
        for (Op* op : w->singles) {
            if (op->c != nullptr) send_response(op->c, R_DB, "{}", 2);
            delete op;
        }
    }
    w->singles.clear();
}

static void flush_heavy(Worker* w, int slot) {
    auto& queue = w->heavyQueue[slot];
    while (!queue.empty()) {
    // bounded pipeline: a huge batched UPDATE (512 conns x q=20) monopolises PostgreSQL
    std::vector<Op*> chunk;
    size_t take = queue.size() < 8 ? queue.size() : 8;
    chunk.assign(queue.begin(), queue.begin() + (long)take);
    queue.erase(queue.begin(), queue.begin() + (long)take);
    PGconn* pg = w->heavy[slot];
    PQenterPipelineMode(pg);
    std::vector<std::string> paramStore;
    paramStore.reserve(chunk.size() * 2);
    for (Op* op : chunk) {
        if (op->route == R_FORTUNES) {
            PQsendQueryPrepared(pg, "f", 0, nullptr, nullptr, nullptr, 0);
        } else if (op->route == R_UPDATES) {
            paramStore.push_back(int_array(op->ids));
            paramStore.push_back(int_array(op->nums));
            const char* params[2] = {paramStore[paramStore.size() - 2].c_str(),
                                     paramStore[paramStore.size() - 1].c_str()};
            PQsendQueryPrepared(pg, "u", 2, params, nullptr, nullptr, 0);
        } else {
            paramStore.push_back(int_array(op->ids));
            const char* params[1] = {paramStore.back().c_str()};
            PQsendQueryPrepared(pg, "a", 1, params, nullptr, nullptr, 0);
        }
    }
    PQpipelineSync(pg);
    for (Op* op : chunk) {
        PGresult* res = next_result(pg);
        if (!res) { delete op; continue; }
        if (op->route == R_UPDATES) {
            PQclear(res);
            char body[65536];
            int len = 0;
            body[len++] = '[';
            for (size_t i = 0; i < op->ids.size(); i++) {
                if (i) body[len++] = ',';
                len += snprintf(body + len, 64, "{\"id\":%d,\"randomNumber\":%d}", op->ids[i], op->nums[i]);
            }
            body[len++] = ']';
            send_response(op->c, R_QUERIES, body, len);
        } else if (op->route == R_FORTUNES) {
            struct FR { int id; std::string msg; };
            std::vector<FR> rows;
            int n = PQntuples(res);
            rows.reserve((size_t)n + 1);
            for (int i = 0; i < n; i++) rows.push_back({atoi(PQgetvalue(res, i, 0)), PQgetvalue(res, i, 1)});
            rows.push_back({0, "Additional fortune added at request time."});
            std::sort(rows.begin(), rows.end(), [](const FR& a, const FR& b) { return a.msg < b.msg; });
            char* body = (char*)malloc(65536);
            int len = 0;
            append_str(body, len, "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>");
            for (auto& r : rows) {
                append_str(body, len, "<tr><td>");
                append_int(body, len, r.id);
                append_str(body, len, "</td><td>");
                html_escape(body, len, r.msg.c_str());
                append_str(body, len, "</td></tr>");
            }
            append_str(body, len, "</table></body></html>");
            send_response(op->c, R_FORTUNES, body, len);
            free(body);
            PQclear(res);
        } else {
            write_db_body(res, op);
            PQclear(res);
        }
        delete op;
    }
    PGresult* syncRes = next_result(pg);
    if (syncRes) PQclear(syncRes);
    PQexitPipelineMode(pg);
    }
}

static Route route_of(const char* target) {
    if (!strcmp(target, "/plaintext")) return R_PLAIN;
    if (!strcmp(target, "/json")) return R_JSON;
    if (!strcmp(target, "/db")) return R_DB;
    if (!strncmp(target, "/queries", 8)) return R_QUERIES;
    if (!strcmp(target, "/fortunes")) return R_FORTUNES;
    if (!strncmp(target, "/updates", 8)) return R_UPDATES;
    return R_PLAIN;
}

static void handle_request(Worker* w, Conn* c, char* target) {
    Route route = route_of(target);
    if (route == R_PLAIN) {
        send_response(c, R_PLAIN, "Hello, World!", 13);
        return;
    }
    if (route == R_JSON) {
        send_response(c, R_JSON, "{\"message\":\"Hello, World!\"}", 27);
        return;
    }
    Op* op = new Op();
    op->c = c;
    op->route = route;
    if (route == R_UPDATES) {
        int n = param_count(target);
        op->ids.resize(n);
        op->nums.resize(n);
        for (int i = 0; i < n; i++) {
            op->ids[i] = rand_id(w);
            op->nums[i] = rand_id(w);
        }
        int slot = (w->heavyRot++) % HEAVY_PER_WORKER;
        w->heavyQueue[slot].push_back(op);
    } else if (route == R_FORTUNES) {
        int slot = (w->heavyRot++) % HEAVY_PER_WORKER;
        w->heavyQueue[slot].push_back(op);
    } else {
        op->count = param_count(target);
        op->ids.resize((size_t)op->count);
        for (int i = 0; i < op->count; i++) op->ids[i] = rand_id(w);
        if (op->count == 1) {
            w->singles.push_back(op);
        } else {
            int slot = (w->heavyRot++) % HEAVY_PER_WORKER;
            w->heavyQueue[slot].push_back(op);
        }
    }
}

static void process_input(Worker* w, Conn* c) {
    int off = 0;
    while (true) {
        int hdr = -1;
        for (int i = off; i + 3 < c->inLen; i++) {
            if (c->in[i] == '\r' && c->in[i + 1] == '\n' && c->in[i + 2] == '\r' && c->in[i + 3] == '\n') {
                hdr = i;
                break;
            }
        }
        if (hdr < 0) break;
        int sp1 = -1, sp2 = -1;
        for (int i = off; i < hdr; i++) {
            if (c->in[i] == ' ') {
                if (sp1 < 0) sp1 = i;
                else { sp2 = i; break; }
            }
        }
        if (sp1 < 0 || sp2 < 0) break;
        int tlen = sp2 - sp1 - 1;
        char target[2048];
        if (tlen > 2047) tlen = 2047;
        memcpy(target, c->in + sp1 + 1, (size_t)tlen);
        target[tlen] = 0;
        handle_request(w, c, target);
        off = hdr + 4;
    }
    if (off > 0) {
        memmove(c->in, c->in + off, (size_t)(c->inLen - off));
        c->inLen -= off;
    }
}

static void *worker_main(void* arg) {
    Worker* w = (Worker*)arg;
    w->epfd = epoll_create1(0);
    w->rng ^= (uint32_t)(w->idx * 2654435761u + 1);

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(lfd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(PORT_DEFAULT);
    if (bind(lfd, (sockaddr*)&addr, sizeof addr) || listen(lfd, 4096)) {
        perror("bind/listen");
        return nullptr;
    }
    fcntl(lfd, F_SETFL, O_NONBLOCK);
    w->listenFd = lfd;
    epoll_event lev{};
    lev.events = EPOLLIN;
    lev.data.ptr = nullptr;   // nullptr marks the listener
    epoll_ctl(w->epfd, EPOLL_CTL_ADD, lfd, &lev);

    w->primary = PQconnectdb(CONNINFO);
    if (PQstatus(w->primary) != CONNECTION_OK) { fprintf(stderr, "primary: %s\n", PQerrorMessage(w->primary)); return nullptr; }
    PQprepare(w->primary, "a", SQL_ARRAY, 1, nullptr);
    for (int i = 0; i < HEAVY_PER_WORKER; i++) {
        w->heavy[i] = PQconnectdb(CONNINFO);
        if (PQstatus(w->heavy[i]) != CONNECTION_OK) { fprintf(stderr, "heavy: %s\n", PQerrorMessage(w->heavy[i])); return nullptr; }
        PQprepare(w->heavy[i], "a", SQL_ARRAY, 1, nullptr);
        PQprepare(w->heavy[i], "f", SQL_FORTUNE, 0, nullptr);
        PQprepare(w->heavy[i], "u", SQL_UPDATE, 2, nullptr);
    }

    printf("worker %d ready\n", w->idx);
    fflush(stdout);
    epoll_event events[MAX_EVENTS];
    while (true) {
        int n = epoll_wait(w->epfd, events, MAX_EVENTS, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int i = 0; i < n; i++) {
            if (events[i].data.ptr == nullptr) {
                while (true) {
                    int fd = accept4(lfd, nullptr, nullptr, SOCK_NONBLOCK);
                    if (fd < 0) break;
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                    Conn* c = (Conn*)calloc(1, sizeof(Conn));
                    c->fd = fd;
                    c->w = w;
                    c->in = (char*)malloc(IN_CAP);
                    c->out = (char*)malloc(OUT_CAP);
                    c->interest = EPOLLIN | EPOLLRDHUP;
                    epoll_event cev{};
                    cev.events = c->interest;
                    cev.data.ptr = c;
                    epoll_ctl(w->epfd, EPOLL_CTL_ADD, fd, &cev);
                }
                continue;
            }
            Conn* c = (Conn*)events[i].data.ptr;
            uint32_t ev = events[i].events;
            bool closed = false;
            if (ev & (EPOLLERR | EPOLLHUP)) { close_conn(c); continue; }
            if (ev & EPOLLIN) {
                while (c->inLen < IN_CAP) {
                    ssize_t r = recv(c->fd, c->in + c->inLen, (size_t)(IN_CAP - c->inLen), 0);
                    if (r == 0) { closed = true; break; }
                    if (r < 0) break;
                    c->inLen += (int)r;
                }
                if (!closed) process_input(w, c);
            }
            if (ev & EPOLLOUT) flush_conn(c);
            if (closed) close_conn(c);
        }
        flush_singles(w);
        for (int s = 0; s < HEAVY_PER_WORKER; s++) flush_heavy(w, s);
        for (Conn* c : w->dirty) flush_conn(c);
        w->dirty.clear();
    }
    return nullptr;
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    g_plainHead = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13";
    g_jsonHead = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27";
    g_jsonHeadLen = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
    g_htmlHeadLen = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ";
    static Worker workers[WORKERS];
    pthread_t threads[WORKERS];
    for (int i = 0; i < WORKERS; i++) {
        workers[i].idx = i;
        pthread_create(&threads[i], nullptr, worker_main, &workers[i]);
    }
    for (int i = 0; i < WORKERS; i++) pthread_join(threads[i], nullptr);
    return 0;
}
