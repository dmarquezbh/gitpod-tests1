>>SOURCE FORMAT FREE
identification division.
program-id. cobolserver.
data division.
working-storage section.
01 sock-fd    usage binary-long.
01 client-fd  usage binary-long.
01 n          usage binary-long.
01 rc         usage binary-long.
01 addr       pic x(16).
01 buf        pic x(65536).
01 resp       pic x(512).
01 resp-len   usage binary-long.
01 um         usage binary-long.
procedure division.
    move all x"00" to addr
    move x"0200" to addr(1:2)
    move x"46B3" to addr(3:2)
    call "socket" using by value 2 by value 1 by value 0
        returning sock-fd
    if sock-fd < 0
        display "socket falhou" end-display
        stop run
    end-if
    move 1 to um
    call "setsockopt" using by value sock-fd by value 1 by value 2
        by reference um by value 4 returning rc
    call "bind" using by value sock-fd by reference addr by value 16
        returning rc
    if rc < 0
        display "bind falhou" end-display
        stop run
    end-if
    call "listen" using by value sock-fd by value 4096 returning rc
    display "cobol-platform on :18099" end-display
    perform forever
        call "accept" using by value sock-fd by value 0 by value 0
            returning client-fd
        if client-fd >= 0
            move spaces to buf
            call "read" using by value client-fd by reference buf
                by value 65536 returning n
            if n > 0
                if buf(5:10) = "/plaintext"
                    perform responder-plain
                else
                    if buf(5:5) = "/json"
                        perform responder-json
                    else
                        perform responder-404
                    end-if
                end-if
            end-if
            call "close" using by value client-fd returning rc
        end-if
    end-perform
    stop run.
responder-plain.
    move spaces to resp
    string "HTTP/1.1 200 OK" x"0D0A"
           "Content-Type: text/plain" x"0D0A"
           "Content-Length: 13" x"0D0A" x"0D0A"
           "Hello, World!"
        into resp end-string
    move 78 to resp-len
    perform enviar.
responder-json.
    move spaces to resp
    string "HTTP/1.1 200 OK" x"0D0A"
           "Content-Type: application/json" x"0D0A"
           "Content-Length: 28" x"0D0A" x"0D0A"
           "{" x"22" "message" x"22" ":" x"22" "Hello, World!" x"22" "}"
        into resp end-string
    move 99 to resp-len
    perform enviar.
responder-404.
    move spaces to resp
    string "HTTP/1.1 404 Not Found" x"0D0A"
           "Content-Length: 0" x"0D0A" x"0D0A"
        into resp end-string
    move 46 to resp-len
    perform enviar.
enviar.
    call "write" using by value client-fd by reference resp
        by value resp-len returning rc.
