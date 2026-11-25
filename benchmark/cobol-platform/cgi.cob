       IDENTIFICATION DIVISION.
       PROGRAM-ID. BENCHCGI.
       ENVIRONMENT DIVISION.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 URI        PIC X(128).
       01 MODO       PIC X(1).
       PROCEDURE DIVISION.
           ACCEPT URI FROM ENVIRONMENT "REQUEST_URI"
           IF URI(1:9) = "/json"
               PERFORM JSON
           ELSE
               PERFORM PLAINTEXT
           END-IF
           STOP RUN.
       PLAINTEXT.
           DISPLAY "Content-Type: text/plain"
           DISPLAY "Content-Length: 13"
           DISPLAY " "
           DISPLAY "Hello, World!" WITH NO ADVANCING.
       JSON.
           DISPLAY "Content-Type: application/json"
           DISPLAY "Content-Length: 28"
           DISPLAY " "
           DISPLAY "{" & """ & "message" & """ & ":" & """
                   & "Hello, World!" & """ & "}" WITH NO ADVANCING.
