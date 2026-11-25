{ Pascal "platform" entry (FPC): fphttpserver com threads + conectores PostgreSQL (fcl-db).
  Os mesmos seis testes do TechEmpower; serve também como entrada "Delphi" (mesmo código,
  compilado por Delphi/FPC em modo Delphi). }
program server;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, fphttpserver, httpdefs, pqconnection, sqldb, strutils;

type
  TConn = record Conexao: TPQConnection; Consulta: TSQLQuery; end;

var
  Cfg: record Host, Base, Usuario, Senha: string; Porta: Integer; end;

threadvar
  C: TConn;

procedure AbrirBanco;
begin
  if Assigned(C.Conexao) then Exit;
  C.Conexao := TPQConnection.Create(nil);
  C.Conexao.HostName := Cfg.Host;
  C.Conexao.DatabaseName := Cfg.Base;
  C.Conexao.UserName := Cfg.Usuario;
  C.Conexao.Password := Cfg.Senha;
  C.Conexao.Connected := True;
  C.Consulta := TSQLQuery.Create(nil);
  C.Consulta.DataBase := C.Conexao;
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
  if i > p then
    Result := StrToIntDef(Copy(Qs, p, i - p), 1);
  if Result < 1 then Result := 1;
  if Result > 500 then Result := 500;
end;

procedure Escrever(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse; const Corpo, Tipo: string);
begin
  AResponse.Code := 200;
  AResponse.ContentType := Tipo;
  AResponse.ContentLength := Length(Corpo);
  AResponse.Content := Corpo;
end;

function Fortunes: string;
var
  itens: TStringList;
begin
  AbrirBanco;
  C.Consulta.Close;
  C.Consulta.SQL.Text := 'SELECT id, message FROM fortune';
  C.Consulta.Open;
  itens := TStringList.Create;
  try
    while not C.Consulta.EOF do
    begin
      itens.Add(Format('%d'#9'%s', [C.Consulta.FieldByName('id').AsInteger,
        C.Consulta.FieldByName('message').AsString]));
      C.Consulta.Next;
    end;
    itens.Add('0'#9'Additional fortune added at request time.');
    itens.Sort;
    Result := '<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>';
    for var i := 0 to itens.Count - 1 do
    begin
      var P := Pos(#9, itens[i]);
      var Id := Copy(itens[i], 1, P - 1);
      var Msg := StringReplace(StringReplace(StringReplace(StringReplace(Copy(itens[i], P + 1, MaxInt),
        '&', '&amp;', [rfReplaceAll]), '<', '&lt;', [rfReplaceAll]), '>', '&gt;', [rfReplaceAll]),
        '"', '&quot;', [rfReplaceAll]);
      Result := Result + '<tr><td>' + Id + '</td><td>' + Msg + '</td></tr>';
    end;
    Result := Result + '</table></body></html>';
  finally
    itens.Free;
  end;
end;

procedure Tratar(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse);
var
  Rota, Corpo, ListaIds, ListaNovos: string;
  Q, I, Id, Novo: Integer;
  Ids, Novos, Rs: TStringList;
begin
  Rota := ARequest.Path;
  if Rota = '/plaintext' then
    Escrever(ARequest, AResponse, 'Hello, World!', 'text/plain')
  else if Rota = '/json' then
    Escrever(ARequest, AResponse, '{"message":"Hello, World!"}', 'application/json')
  else if Rota = '/db' then
  begin
    AbrirBanco;
    Id := IdAleatorio;
    C.Consulta.Close;
    C.Consulta.SQL.Text := 'SELECT id, randomnumber FROM world WHERE id = ' + IntToStr(Id);
    C.Consulta.Open;
    Escrever(ARequest, AResponse,
      Format('{"id":%d,"randomNumber":%d}', [C.Consulta.FieldByName('id').AsInteger,
        C.Consulta.FieldByName('randomnumber').AsInteger]), 'application/json');
  end
  else if Rota = '/queries' then
  begin
    AbrirBanco;
    Q := QtdDaQuery(ARequest.QueryString);
    Ids := TStringList.Create;
    try
      ListaIds := '';
      for I := 1 to Q do
      begin
        Id := IdAleatorio;
        Ids.Add(IntToStr(Id));
        if I > 1 then ListaIds := ListaIds + ',';
        ListaIds := ListaIds + IntToStr(Id);
      end;
      C.Consulta.Close;
      C.Consulta.SQL.Text := 'SELECT id, randomnumber FROM world WHERE id IN (' + ListaIds + ')';
      C.Consulta.Open;
      Corpo := '[';
      var Primeiro := True;
      while not C.Consulta.EOF do
      begin
        if not Primeiro then Corpo := Corpo + ',';
        Primeiro := False;
        Corpo := Corpo + Format('{"id":%d,"randomNumber":%d}', [C.Consulta.FieldByName('id').AsInteger,
          C.Consulta.FieldByName('randomnumber').AsInteger]);
        C.Consulta.Next;
      end;
      Corpo := Corpo + ']';
      Escrever(ARequest, AResponse, Corpo, 'application/json');
    finally
      Ids.Free;
    end;
  end
  else if Rota = '/updates' then
  begin
    AbrirBanco;
    Q := QtdDaQuery(ARequest.QueryString);
    ListaIds := ''; ListaNovos := '';
    for I := 1 to Q do
    begin
      if I > 1 then begin ListaIds := ListaIds + ','; ListaNovos := ListaNovos + ','; end;
      ListaIds := ListaIds + IntToStr(IdAleatorio);
      ListaNovos := ListaNovos + IntToStr(IdAleatorio);
    end;
    C.Consulta.Close;
    C.Consulta.SQL.Text :=
      'UPDATE world SET randomnumber = v.rn FROM (SELECT unnest(''{' + ListaIds + '}''::int[]) AS id, ' +
      'unnest(''{' + ListaNovos + '}''::int[]) AS rn) AS v WHERE world.id = v.id RETURNING world.id, world.randomnumber';
    C.Consulta.Open;
    Corpo := '[';
    var Primeiro := True;
    while not C.Consulta.EOF do
    begin
      if not Primeiro then Corpo := Corpo + ',';
      Primeiro := False;
      Corpo := Corpo + Format('{"id":%d,"randomNumber":%d}', [C.Consulta.FieldByName('id').AsInteger,
        C.Consulta.FieldByName('randomnumber').AsInteger]);
      C.Consulta.Next;
    end;
    Corpo := Corpo + ']';
    Escrever(ARequest, AResponse, Corpo, 'application/json');
  end
  else if Rota = '/fortunes' then
    Escrever(ARequest, AResponse, Fortunes, 'text/html; charset=utf-8')
  else
  begin
    AResponse.Code := 404;
    AResponse.ContentLength := 0;
  end;
end;

var
  Servidor: TFPHTTPServer;
begin
  Randomize;
  Cfg.Host := GetEnvironmentVariable('PGHOST');
  if Cfg.Host = '' then Cfg.Host := '127.0.0.1';
  Cfg.Base := GetEnvironmentVariable('PGDATABASE');
  if Cfg.Base = '' then Cfg.Base := 'hello_world';
  Cfg.Usuario := GetEnvironmentVariable('PGUSER');
  if Cfg.Usuario = '' then Cfg.Usuario := 'benchmarkdbuser';
  Cfg.Senha := GetEnvironmentVariable('PGPASSWORD');
  if Cfg.Senha = '' then Cfg.Senha := 'benchmarkdbpass';
  Cfg.Porta := StrToIntDef(GetEnvironmentVariable('PORT'), 8092);

  Servidor := TFPHTTPServer.Create(nil);
  Servidor.Port := Cfg.Porta;
  Servidor.Threaded := True;
  Servidor.QueueSize := 4096;
  Servidor.OnRequest := @Tratar;
  Servidor.Active := True;
  WriteLn('pascal-platform on :', Cfg.Porta);
  ReadLn;
end.
