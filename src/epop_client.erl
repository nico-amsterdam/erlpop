-module(epop_client).
-author("Harish Mallipeddi <harish.mallipeddi@gmail.com>").

%%%---------------------------------------------------------------------
%%% File    : epop_client.erl
%%% Created : 10 Sep 2008 by harish.mallipeddi@gmail.com
%%% Function: POP3 client (with SSL support)
%%% ====================================================================
%%% The contents of this file are subject to the Erlang Public License
%%% License, Version 1.1, (the "License"); you may not use this file
%%% except in compliance with the License. You may obtain a copy of the
%%% License at http://www.erlang.org/EPLICENSE
%%%
%%% Software distributed under the License is distributed on an "AS IS"
%%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%% the License for the specific language governing rights and limitations
%%% under the License.
%%%
%%% The Original Code is epop-2-3
%%%
%%% The Initial Developer of the Original Code is Ericsson Telecom
%%% AB. Portions created by Ericsson are Copyright (C), 1998, Ericsson
%%% Telecom AB. All Rights Reserved.
%%%
%%% Contributor(s):
%%%     11 Mar 1998 by tobbe@serc.rmit.edu.au
%%%     10 Sep 2008 by harish.mallipeddi@gmail.com (added support for SSL).
%%%
%%%---------------------------------------------------------------------

-vc('$Id$ ').
-export([connect/2,connect/3,stat/1,scan/1,scan/2,retrieve/2,bin_retrieve/2,delete/2,
	 reset/1,quit/1,uidl/1,uidl/2,top/3]).
-export([notify/3,accept/2,accept/3]).

-import(error_logger,[error_msg/1]).
-import(epop_client_utils,[recv_sl/1,recv_ml/1,recv_ml_on_ok/1,tokenize/1,bin_recv_ml_on_ok/1]).

-include("epop_client.hrl").

%% ----------------------------------------------
%% Accept a NOTIFY connection from an Epop server
%% ----------------------------------------------

accept(Lsock,Passwd) ->
    accept(Lsock,Passwd,[]).

accept(Lsock,Passwd,Options) when is_list(Passwd), is_list(Options) ->
    catch do_accept(Lsock,Passwd,Options).

do_accept(Lsock,Passwd,Options) ->
    S = init_options(false,false,Options),
    case gen_tcp:accept(Lsock) of
	{ok,Sock} ->
	    parse_notification(S#sk{sockfd=Sock},Passwd);
	Else ->
	    exit(Else)
    end.

parse_notification(S,Passwd) ->
    case recv_sl(S) of
	{[$N,$T,$F,$Y|T],_} ->
	    User = parse_user(T),
	    answer_greeting(S#sk{user=User},Passwd,T);
	_ ->
	    error_msg("epop_client: Wrong connect message !~n"),
	    exit(wrong_connect)
    end.

parse_user(T) ->
    case string:tokens(T," \r\n") of
	[User|_] -> User;
	_ ->
	    error_msg("epop_client: Couldn't parse User !~n"),
	    exit(no_user)
    end.


%% ------------------------------------------
%% Set up a connection to a POP3 server using
%% the specified UserId and Passwd
%% ------------------------------------------

connect(User,Passwd) ->
    connect(User,Passwd,[]).

connect(User,Passwd,Options) when is_atom(User) ->
    connect(atom_to_list(User),Passwd,Options);
connect(User,Passwd,Options) when is_list(User), is_list(Passwd), is_list(Options) ->
    catch do_connect(User,Passwd,Options).

do_connect(User,Passwd,Options) when is_list(User), is_list(Passwd), is_list(Options) ->
    S = init_session(User,Options),
    case do_connect_proto(S) of
        {ok,Sock} -> get_greeting(S#sk{sockfd=Sock},Passwd);
        _         -> {error,connect_failed}
    end.

do_connect_proto(S) ->
    case S#sk.ssl of
        false ->
            %% default POP3
            Opts = [{packet,raw}, {reuseaddr,true}, {active,false}],
            gen_tcp:connect(S#sk.addr, S#sk.port, Opts);
        true ->
            %% handle POP3 over SSL
%            application:start(ssl),
            ok = ssl:start(),
            Opts = [{packet,raw}, {reuseaddr,true}, {active,false}],
            ssl:connect(S#sk.addr, S#sk.port, Opts)
    end.

%% -----------------------------------------------
%% Get the initial greeting from the server and
%% perform the specified authentication procedure.

get_greeting(S,Passwd) ->
    case recv_sl(S) of
    	{[$+,$O,$K|T],_} ->
    	    answer_greeting(S,Passwd,T);
    	{[$-,$E,$R,$R|T],_} ->
    	    if_snoop(S,sender,"-ERR" ++ T),
    	    {error,T}
    end.

answer_greeting(S,Passwd,T) when S#sk.apop==false ->
    if_snoop(S,sender,"+OK" ++ T),
    Msg = "USER " ++ S#sk.user,
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    send_passwd(S,Passwd);
answer_greeting(S,Passwd,T) when S#sk.apop==true ->
    if_snoop(S,sender,"+OK" ++ T),
    TS = parse_banner_timestamp(T),
    Digest = epop_md5:string(TS ++ Passwd),
    Msg = "APOP " ++ S#sk.user ++ " " ++ Digest,
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    get_ok(S).

parse_banner_timestamp(Banner) ->
    case re:run(Banner,"<.*>", [{capture,first,list}]) of
	{match,[Timestamp]} ->
            Timestamp;
	_ ->
	    throw({error,apop_banner_timestamp})
    end.

%% -------------------------------------------
%% Wait for an expected ok from the server and
%% reply with the password.

send_passwd(S,Passwd) ->
    case recv_sl(S) of
	{[$+,$O,$K|T],_} ->
	    if_snoop(S,sender,"+OK" ++ T),
	    Msg = "PASS " ++ Passwd,
	    ok = deliver(S,Msg),
	    if_snoop(S,client,Msg),
	    get_ok(S);
	{[$-,$E,$R,$R|T],_} ->
	    if_snoop(S,sender,"-ERR" ++ T),
	    {error,T}
    end.

%% -------------------
%% Send a STAT request
%% -------------------

stat(S) ->
    Msg = "STAT",
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    get_stat(S).

get_stat(S) ->
    case recv_sl(S) of
	{[$+,$O,$K|T],_} ->
	    if_snoop(S,sender,"+OK" ++ T),
	    [NumMsg,TotSize] = string:tokens(T," \r\n"),
	    {ok,{s2i(NumMsg),s2i(TotSize)}};
	{[$-,$E,$R,$R|T],_} ->
	    if_snoop(S,sender,"-ERR" ++ T),
	    {error,T}
    end.

%% ------------------------
%% Send a scan list request
%% ------------------------

scan(S) -> do_scan(S,"LIST",true).

scan(S,Num) when is_integer(Num) ->
    do_scan(S,"LIST " ++ integer_to_list(Num),false).

do_scan(S,Msg,MultiLine) ->
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    get_scanlist(S,MultiLine).

get_scanlist(S,MultiLine) ->
    case scan_recv(S,MultiLine) of
	{[$+,$O,$K|T],_} when MultiLine==true ->
	    [Line1|Ls] = tokenize("+OK" ++ T),
	    if_snoop(S,sender,Line1),
	    F = fun(L) -> if_snoop(S,sender,L) end,
	    lists:foreach(F,Ls),
	    F2 = fun(Str) -> [Num,Sz] = string:tokens(Str," "),
			     {l2i(Num),l2i(Sz)}
		 end,
	    {ok,lists:map(F2,Ls)};
	{[$+,$O,$K|T],_} when MultiLine==false ->
	    if_snoop(S,sender,"+OK" ++ T),
	    [MsgNum,MsgSize] = string:tokens(T," "),
	    {ok,{l2i(MsgNum),l2i(MsgSize)}};
	{[$-,$E,$R,$R|T],_} ->
	    %% According to RFC-1939 page 6. We can only
	    %% receive an error when a specific argument
	    %% was specified in LIST, i.e MultiLine==false.
	    if_snoop(S,sender,"-ERR" ++ T),
	    {error,T}
    end.

%% Do we expect a multi line response or not ?

scan_recv(SockFd,true)  -> recv_ml(SockFd);
scan_recv(SockFd,false) -> recv_sl(SockFd).

%% ------------------
%% Get specified mail
%% ------------------

retrieve(S,MsgNum) when is_integer(MsgNum) -> 
    Msg = "RETR " ++ integer_to_list(MsgNum),
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    get_retrieve(S).

bin_retrieve(S,MsgNum) when is_integer(MsgNum) -> 
    Msg = "RETR " ++ integer_to_list(MsgNum),
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    bin_get_retrieve(S).

top(S,MsgNum,Lines) when is_integer(MsgNum), is_integer(Lines) -> 
    Msg = "TOP " ++ integer_to_list(MsgNum) ++ " " ++ integer_to_list(Lines),
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    get_retrieve(S).

get_retrieve(S) ->
    case recv_ml_on_ok(S) of
	{[$+,$O,$K|T],_} ->
	    {Line,Ls} = get_line("+OK" ++ T),
	    if (S#sk.snoop==true) ->
		    if_snoop(S,sender,Line),
		    io:fwrite("~s~n",[Ls]);
	       true -> true
	    end,
	    {ok,Ls};
	{[$-,$E,$R,$R|T],_} ->
	    if_snoop(S,sender,"-ERR" ++ T),
	    {error,T};
	Else ->
	    Else
    end.

bin_get_retrieve(S) ->
    case bin_recv_ml_on_ok(S) of
	{<<"+OK", T/binary>>,_} ->
	    {Line,Ls} = bin_get_line(<<"+OK", T/binary>>),
	    if (S#sk.snoop==true) ->
		    if_snoop(S,sender,Line),
		    io:fwrite("~s~n",[Ls]);
	       true -> true
	    end,
	    {ok,Ls};
	{[$-,$E,$R,$R|T],_} ->
	    if_snoop(S,sender,"-ERR" ++ T),
	    {error,T};
	Else ->
	    Else
    end.

get_line(Str) -> 
    F = fun($\n) -> false;
	   (_)   -> true
	end,
    {Line,[_Nl|Rest]} = lists:splitwith(F,Str),
    {Line,Rest}.

bin_get_line(Bin) ->
    case binary:match(Bin, <<"\n">>) of
      {Start, Length} -> {binary:part(Bin, 0, Start), binary:part(Bin, Start + Length, byte_size(Bin) - Start - Length)};
      nomatch -> {Bin,<< >>}
    end.

%% -------------------
%% Send a uidl request
%% -------------------

uidl(S) -> do_uidl(S,"UIDL",true).

uidl(S,Num) when is_integer(Num) ->
    do_uidl(S,"UIDL " ++ integer_to_list(Num),false).

do_uidl(S,Msg,MultiLine) ->
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    get_uidllist(S,MultiLine).

get_uidllist(S,MultiLine) ->
    case uidl_recv(S,MultiLine) of
	{[$+,$O,$K|T],_} when MultiLine==true ->
	    [Line1|Ls] = tokenize("+OK" ++ T),
	    if_snoop(S,sender,Line1),
	    F = fun(L) -> if_snoop(S,sender,L) end,
	    lists:foreach(F,Ls),
	    F2 = fun(Str) -> [Num,Id] = string:tokens(Str," "),
			     {l2i(Num),Id}
		 end,
	    {ok,lists:map(F2,Ls)};
	{[$+,$O,$K|T],_} when MultiLine==false ->
	    if_snoop(S,sender,"+OK" ++ T),
	    [MsgNum,MsgId] = string:tokens(T," "),
	    {ok,{l2i(MsgNum),MsgId}};
	{[$-,$E,$R,$R|T],_} ->
	    %% We assume that the behaviour here is similar
	    %% to the LIST request, see comment above.
	    if_snoop(S,sender,"-ERR" ++ T),
	    {error,T}
    end.

%% Do we expect a multi line response or not ?

uidl_recv(SockFd,true)  -> recv_ml(SockFd);
uidl_recv(SockFd,false) -> recv_sl(SockFd).


%% ----------------------
%% Mark mail for deletion
%% ----------------------

delete(S,MsgNum) when is_integer(MsgNum) ->
    Msg = "DELE " ++ integer_to_list(MsgNum),
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    case get_ok(S) of
	{ok,_} -> ok;
	Else   -> Else
    end.


%% --------------------------------------------
%% Remove all delete marks made in this session
%% --------------------------------------------
    
reset(S) -> 
    Msg = "RSET",
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    case get_ok(S) of
	{ok,_} -> ok;
	Else   -> Else
    end.

%% ----------------
%% Quit the session
%% ----------------

quit(S) -> 
    Msg = "QUIT",
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    Res = case get_ok(S) of
	      {ok,_} -> ok;
	      Else   -> Else
	  end,
    case S#sk.ssl of
        true -> ssl:close(S#sk.sockfd);
        false -> gen_tcp:close(S#sk.sockfd)
    end,
    Res.

%% ----------------------------------------------------
%% Order notification.
%% NB: This is my little extension of the POP3 protocol
%% ----------------------------------------------------

notify(S,Host,PortNo) when is_list(Host), is_integer(PortNo) ->
    do_notify(S,"NTFY " ++ Host ++ " " ++ integer_to_list(PortNo)).

do_notify(S,Msg) ->
    ok = deliver(S,Msg),
    if_snoop(S,client,Msg),
    get_ok(S).

%% ---------------------------------------------
%% Wait for an expected ok from the server which
%% ends this transaction.

get_ok(S) ->
    case recv_sl(S) of
	{[$+,$O,$K|T],_} ->
	    if_snoop(S,sender,"+OK" ++ T),
	    {ok,S};
	{[$-,$E,$R,$R|T],_} ->
	    if_snoop(S,sender,"+ERR" ++ T),
	    {error,T}
    end.
    

%% -----------------------------
%% Send a CRLF terminated string

deliver(S,Msg) ->
    case S#sk.ssl of
        true -> ssl:send(S#sk.sockfd, Msg ++ "\r\n");
        false -> gen_tcp:send(S#sk.sockfd, Msg ++ "\r\n")
    end.

%% ---------------------------------------
%% Print trace info if snoop option is set

if_snoop(S,Who,Msg) when S#sk.snoop==true ->
    io:fwrite("~s: ~s~n",[who(Who),Msg]);
if_snoop(_,_,_) ->
    true.

who(sender) -> "S";
who(client) -> "C".


%% --------------------
%% Init the session key

init_session(User,Options) ->
    {Uid,Adr} = user_address(User),
    init_options(Uid,Adr,Options).

init_options(Uid,Adr,Options) ->
    set_options(Options,#sk{user=Uid,addr=Adr}).

user_address(User) ->
    case string:tokens(User,"@") of
	List when length(List)>1 -> make_uid_address(List);
	_ -> throw({error,address_format})
    end.

make_uid_address(L) -> make_uid_address(L, "").

make_uid_address([_Uid, Adr], Uid) -> {Uid++_Uid, Adr};
make_uid_address([_Uid|L], Uid)    -> make_uid_address(L, Uid++_Uid++"@").
    

set_options([{snoop,Flag}|T],S) ->
    set_options(T,S#sk{snoop=Flag});
set_options([{port,Port}|T],S) ->
    set_options(T,S#sk{port=Port});
set_options([apop|T],S) ->
    set_options(T,S#sk{apop=true});
set_options([upass|T],S) ->
    set_options(T,S#sk{apop=false});
set_options([ssl|T],S) ->
    set_options(T,S#sk{ssl=true});
set_options([{addr,Addr}|T], S) ->
    set_options(T,S#sk{addr=Addr});
set_options([{user,User}|T], S) ->
    set_options(T,S#sk{user=User});
set_options([X|_],_) ->
    throw({error,{unknown_option,X}});
set_options([],S) ->
    S.

s2i(String) when is_list(String) ->
    l2i(strip(String)).

%% Remove any trailing stuff from the (ascii) integer value
strip([H|T]) when H>-48,H=<57 -> [H|strip(T)];
strip(_)                      -> [].

l2i(List) when is_list(List)  -> list_to_integer(List);
l2i(Int) when is_integer(Int) -> Int.

