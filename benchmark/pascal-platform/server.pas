{ Pascal "platform" entry (FPC 3.2, modo objfpc): fphttpserver com threads + fcl-db/postgres.
  Mesmos seis testes do TechEmpower. Este arquivo também é a base da entrada "Delphi":
  basta compilar com Delphi (a API HTTP seria substituída por Indy/WebBroker). }
program server;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fphttpserver, httpdefs, pqconnection, sqldb;

var
  Porta, Procura: Integer;
  Host, Base, Usuario, Senha: string;

type
  TServidorApp = class
    procedure Tratar(Sender: TObject; var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
  end;

threadvar
  Conexao: TPQConnection;
  Transacao: TSQLTransaction;
  Consulta: TSQLQuery;

procedure AbrirBanco;
begin
  if Assigned(Conexao) then Exit;
  Conexao := TPQConnection.Create(nil);
  Conexao.HostName := Host;
  Conexao.DatabaseName := Base;
  Conexao.UserName := Usuario;
  Conexao.Password := Senha;
  Conexao.Connected := True;
  Transacao := TSQLTransaction.Create(nil);
  Transacao.DataBase := Conexao;
  Consulta := TSQLQuery.Create(nil);
  Consulta.DataBase := Conexao;
  Consulta.Transaction := Transacao;
end;

function IdAleatorio: Integer; inline;
begin
  Result := Random(10000) + 1;
end;

function QtdDaQuery(const Qs: string): Integer;
var
  i, p: Integer;
begin
  Result := 1;
  p := Pos('q=', Qs);
  if p = 0 then Exit;
  Inc(p, 2);
  i := p;
  while (i <= Length(Qs)) and (Qs[i] in ['0'..'9']) do Inc(i);
  if i > p then Result := StrToIntDef(Copy(Qs, p, i - p), 1);
  if Result < 1 then Result := 1;
  if Result > 500 then Result := 500;
end;

procedure Escrever(AResponse: TFPHTTPConnectionResponse; const Corpo, Tipo: string);
begin
  AResponse.Code := 200;
  AResponse.ContentType := Tipo;
  AResponse.ContentLength := Length(Corpo);
  AResponse.Content := Corpo;
end;

function Escapar(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function FortunesPagina: string;
var
  itens: TStringList;
  i, p: Integer;
  identificador, mensagem: string;
begin
  AbrirBanco;
  Consulta.Close;
  Consulta.SQL.Text := 'SELECT id, message FROM fortune';
  Consulta.Open;
  itens := TStringList.Create;
  try
    while not Consulta.EOF do
    begin
      itens.Add(Format('%.10d'#9'%s', [Consulta.FieldByName('id').AsInteger,
        Consulta.FieldByName('message').AsString]));
      Consulta.Next;
    end;
    itens.Add('0000000000'#9'Additional fortune added at request time.');
    itens.Sort;
    Result := '<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>' +
      '<tr><th>id</th><th>message</th></tr>';
    for i := 0 to itens.Count - 1 do
    begin
      p := Pos(#9, itens[i]);
      identificador := IntToStr(StrToIntDef(Copy(itens[i], 1, p - 1), 0));
      mensagem := Copy(itens[i], p + 1, MaxInt);
      Result := Result + '<tr><td>' + identificador + '</td><td>' + Escapar(mensagem) + '</td></tr>';
    end;
    Result := Result + '</table></body></html>';
  finally
    itens.Free;
  end;
end;

procedure TServidorApp.Tratar(Sender: TObject; var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
var
  rota, corpo, listaIds, listaNovos, primeiro, url: string;
  q, i, id, novo: Integer;
begin
  url := ARequest.URL;
  q := Pos('?', url);
  if q > 0 then rota := Copy(url, 1, q - 1) else rota := url;
  if rota = '/plaintext' then
    Escrever(AResponse, 'Hello, World!', 'text/plain')
  else if rota = '/json' then
    Escrever(AResponse, '{"message":"Hello, World!"}', 'application/json')
  else if rota = '/db' then
  begin
    AbrirBanco;
    id := IdAleatorio;
    Consulta.Close;
    Consulta.SQL.Text := 'SELECT id, randomnumber FROM world WHERE id = ' + IntToStr(id);
    Consulta.Open;
    Escrever(AResponse, Format('{"id":%d,"randomNumber":%d}',
      [Consulta.FieldByName('id').AsInteger, Consulta.FieldByName('randomnumber').AsInteger]),
      'application/json');
  end
  else if rota = '/queries' then
  begin
    AbrirBanco;
    q := QtdDaQuery(ARequest.QueryString);
    listaIds := '';
    for i := 1 to q do
    begin
      if i > 1 then listaIds := listaIds + ',';
      listaIds := listaIds + IntToStr(IdAleatorio);
    end;
    Consulta.Close;
    Consulta.SQL.Text := 'SELECT id, randomnumber FROM world WHERE id IN (' + listaIds + ')';
    Consulta.Open;
    corpo := '[';
    primeiro := '';
    while not Consulta.EOF do
    begin
      corpo := corpo + primeiro + Format('{"id":%d,"randomNumber":%d}',
        [Consulta.FieldByName('id').AsInteger, Consulta.FieldByName('randomnumber').AsInteger]);
      primeiro := ',';
      Consulta.Next;
    end;
    corpo := corpo + ']';
    Escrever(AResponse, corpo, 'application/json');
  end
  else if rota = '/updates' then
  begin
    AbrirBanco;
    q := QtdDaQuery(ARequest.QueryString);
    listaIds := '';
    listaNovos := '';
    for i := 1 to q do
    begin
      if i > 1 then
      begin
        listaIds := listaIds + ',';
        listaNovos := listaNovos + ',';
      end;
      listaIds := listaIds + IntToStr(IdAleatorio);
      listaNovos := listaNovos + IntToStr(IdAleatorio);
    end;
    Consulta.Close;
    Consulta.SQL.Text :=
      'UPDATE world SET randomnumber = v.rn FROM (SELECT unnest(''{' + listaIds + '}''::int[]) AS id, ' +
      'unnest(''{' + listaNovos + '}''::int[]) AS rn) AS v WHERE world.id = v.id ' +
      'RETURNING world.id, world.randomnumber';
    Consulta.Open;
    corpo := '[';
    primeiro := '';
    while not Consulta.EOF do
    begin
      corpo := corpo + primeiro + Format('{"id":%d,"randomNumber":%d}',
        [Consulta.FieldByName('id').AsInteger, Consulta.FieldByName('randomnumber').AsInteger]);
      primeiro := ',';
      Consulta.Next;
    end;
    corpo := corpo + ']';
    Escrever(AResponse, corpo, 'application/json');
  end
  else if rota = '/fortunes' then
    Escrever(AResponse, FortunesPagina, 'text/html; charset=utf-8')
  else
  begin
    AResponse.Code := 404;
    AResponse.ContentLength := 0;
  end;
end;

var
  Servidor: TFPHTTPServer;
  App: TServidorApp;
begin
  Randomize;
  Host := GetEnvironmentVariable('PGHOST');
  if Host = '' then Host := '127.0.0.1';
  Base := GetEnvironmentVariable('PGDATABASE');
  if Base = '' then Base := 'hello_world';
  Usuario := GetEnvironmentVariable('PGUSER');
  if Usuario = '' then Usuario := 'benchmarkdbuser';
  Senha := GetEnvironmentVariable('PGPASSWORD');
  if Senha = '' then Senha := 'benchmarkdbpass';
  Porta := StrToIntDef(GetEnvironmentVariable('PORT'), 8092);

  Servidor := TFPHTTPServer.Create(nil);
  Servidor.Port := Porta;
  Servidor.Threaded := True;
  Servidor.QueueSize := 4096;
  App := TServidorApp.Create;
  Servidor.OnRequest := @App.Tratar;
  Servidor.Active := True;
  WriteLn('pascal-platform on :', Porta);
  ReadLn;
end.
