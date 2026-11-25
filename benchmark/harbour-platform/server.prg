// Harbour (sucessor open-source do Clipper): servidor HTTP mínimo com hb_socket.
// Serve plaintext e json; as rotas de banco exigiriam hbpgsql e ficam fora desta entrada.
#include "hbsocket.ch"

PROCEDURE Main()
   LOCAL nPorta := Val( hb_GetEnv( "PORT", "8095" ) )
   LOCAL srv, cli, cReq, cResp, cPedido
   srv := hb_socketOpen( 2, 1 )
   hb_socketSetReuseAddr( srv, .T. )
   hb_socketBind( srv, { HB_SOCKET_AF_INET, "0.0.0.0", nPorta } )
   hb_socketListen( srv, 4096 )
   ? "harbour-platform on :" + hb_ntos( nPorta )
   DO WHILE .T.
      cli := hb_socketAccept( srv, , 1000 )
      IF HB_ISNIL( cli )
         LOOP
      ENDIF
      cReq := Space( 4096 )
      hb_socketRecv( cli, @cReq, Len( cReq ), 0, 1000 )
      cPedido := SubStr( cReq, 5, 16 )
      IF Left( cPedido, 10 ) == "/plaintext"
         cResp := "HTTP/1.1 200 OK" + CRLF + ;
                  "Content-Type: text/plain" + CRLF + ;
                  "Content-Length: 13" + CRLF + CRLF + ;
                  "Hello, World!"
      ELSEIF Left( cPedido, 5 ) == "/json"
         cResp := "HTTP/1.1 200 OK" + CRLF + ;
                  "Content-Type: application/json" + CRLF + ;
                  "Content-Length: 27" + CRLF + CRLF + ;
                  '{"message":"Hello, World!"}'
      ELSE
         cResp := "HTTP/1.1 404 Not Found" + CRLF + "Content-Length: 0" + CRLF + CRLF
      ENDIF
      hb_socketSend( cli, cResp )
      hb_socketClose( cli )
   ENDDO
RETURN
