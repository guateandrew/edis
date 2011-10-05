%%%-------------------------------------------------------------------
%%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @author Chad DePue <chad@inakanetworks.com>
%%% @copyright (C) 2011 InakaLabs SRL
%%% @doc edis Database
%%% @todo It's currently delivering all operations to the leveldb instance, i.e. no in-memory management
%%%       Therefore, operations like save/1 are not really implemented
%%% @todo We need to evaluate which calls should in fact be casts
%%% @todo We need to add info to INFO
%%% @end
%%%-------------------------------------------------------------------
-module(edis_db).
-author('Fernando Benavides <fernando.benavides@inakanetworks.com>').
-author('Chad DePue <chad@inakanetworks.com>').

-behaviour(gen_server).

-include("edis.hrl").
-define(DEFAULT_TIMEOUT, 5000).

-record(state, {index     :: non_neg_integer(),
                db        :: eleveldb:db_ref(),
                last_save :: float()}).
-opaque state() :: #state{}.

%% Administrative functions
-export([start_link/1, process/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Commands ========================================================================================
-export([ping/1, save/1, last_save/1, info/1, flush/0, flush/1, size/1]).
-export([append/3, get_range/4, decr/3, get/2]).

%% =================================================================================================
%% External functions
%% =================================================================================================
-spec start_link(non_neg_integer()) -> {ok, pid()}.
start_link(Index) ->
  gen_server:start_link({local, process(Index)}, ?MODULE, Index, []).

-spec process(non_neg_integer()) -> atom().
process(Index) ->
  list_to_atom("edis-db-" ++ integer_to_list(Index)).

%% =================================================================================================
%% Commands
%% =================================================================================================
-spec size(atom()) -> non_neg_integer().
size(Db) ->
  make_call(Db, size).

-spec flush() -> ok.
flush() ->
  lists:foreach(
    fun flush/1, [process(Index) || Index <- lists:seq(0, edis_config:get(databases) - 1)]).

-spec flush(atom()) -> ok.
flush(Db) ->
  make_call(Db, flush).

-spec ping(atom()) -> pong.
ping(Db) ->
  make_call(Db, ping).

-spec save(atom()) -> ok.
save(Db) ->
  make_call(Db, save).

-spec last_save(atom()) -> ok.
last_save(Db) ->
  make_call(Db, last_save).

-spec info(atom()) -> [{atom(), term()}].
info(Db) ->
  make_call(Db, info).

-spec append(atom(), binary(), binary()) -> pos_integer().
append(Db, Key, Value) ->
  make_call(Db, {append, Key, Value}).

-spec decr(atom(), binary(), integer()) -> integer().
decr(Db, Key, Decrement) ->
  make_call(Db, {decr, Key, Decrement}).

-spec get(atom(), binary()) -> undefined | binary().
get(Db, Key) ->
  make_call(Db, {get, Key}).

-spec get_range(atom(), binary(), integer(), integer()) -> binary().
get_range(Db, Key, Start, End) ->
  make_call(Db, {get_range, Key, Start, End}).

%% =================================================================================================
%% Server functions
%% =================================================================================================
%% @hidden
-spec init(non_neg_integer()) -> {ok, state()} | {stop, any()}.
init(Index) ->
  case eleveldb:open("db/edis-" ++ integer_to_list(Index), [{create_if_missing, true}]) of
    {ok, Ref} ->
      {ok, #state{index = Index, db = Ref, last_save = edis_util:timestamp()}};
    {error, Reason} ->
      ?THROW("Couldn't start level db #~p:~b\t~p~n", [Index, Reason]),
      {stop, Reason}
  end.

%% @hidden
-spec handle_call(term(), reference(), state()) -> {reply, ok | {ok, term()} | {error, term()}, state()} | {stop, {unexpected_request, term()}, {unexpected_request, term()}, state()}.
handle_call(save, _From, State) ->
  {reply, ok, State#state{last_save = edis_util:timestamp()}};
handle_call(last_save, _From, State) ->
  {reply, {ok, State#state.last_save}, State};
handle_call(ping, _From, State) ->
  {reply, {ok, pong}, State};
handle_call(info, _From, State) ->
  Version =
    case lists:keyfind(edis, 1, application:loaded_applications()) of
      false -> "0";
      {edis, _Desc, V} -> V
    end,
  {ok, Stats} = eleveldb:status(State#state.db, <<"leveldb.stats">>),
  {reply, {ok, [{edis_version, Version},
                {last_save, State#state.last_save},
                {db_stats, Stats}]}, %%TODO: add info
   State};
handle_call(flush, _From, State) ->
  ok = eleveldb:destroy("db/edis-" ++ integer_to_list(State#state.index), []),
  case init(State#state.index) of
    {ok, NewState} ->
      {reply, ok, NewState};
    {stop, Reason} ->
      {reply, {error, Reason}, State}
  end;
handle_call(size, _From, State) ->
  %%TODO: Is there any way to improve this?
  Size = eleveldb:fold_keys(
           State#state.db, fun(_, Acc) -> Acc + 1 end, 0,
           [{verify_checksums, false}]),
  {reply, {ok, Size}, State};
handle_call({append, Key, Value}, _From, State) ->
  case update(State#state.db, Key, string,
              fun(Item = #edis_item{value = OldV}) ->
                      Item#edis_item{value = <<OldV/binary, Value/binary>>}
              end, <<>>) of
    {ok, NewItem} ->
      {reply, {ok, erlang:size(NewItem#edis_item.value)}, State};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;
handle_call({get, Key}, _From, State) ->
  case eleveldb:get(State#state.db, Key, []) of
    {ok, Bin} ->
      case erlang:binary_to_term(Bin) of
        #edis_item{type = string, value = Value} ->
          {reply, {ok, Value}, State};
        Other ->
          ?THROW("Not a string:~n\t~p~n", [Other]),
          {reply, {error, bad_item_type}, State}
      end;
    not_found ->
      {reply, {ok, undefined}, State};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;
handle_call({get_range, Key, Start, End}, _From, State) ->
  try
    case eleveldb:get(State#state.db, Key, []) of
      {ok, Bin} ->
        case erlang:binary_to_term(Bin) of
          #edis_item{type = string, value = Value} ->
            L = erlang:size(Value),
            StartPos =
              case Start of
                Start when Start >= L -> throw(empty);
                Start when Start >= 0 -> Start;
                Start when Start < (-1)*L -> 0;
                Start -> L + Start
              end,
            EndPos =
              case End of
                End when End >= 0, End >= L -> L - 1;
                End when End >= 0 -> End;
                End when End < (-1)*L -> 0;
                End -> L + End
              end,
            case EndPos - StartPos + 1 of
              Len when Len =< 0 ->
                {reply, {ok, <<>>}, State};
              Len ->
                {reply, {ok, binary:part(Value, StartPos, Len)}, State}
            end;
          Other ->
            ?THROW("Not a string:~n\t~p~n", [Other]),
            {reply, {error, bad_item_type}, State}
        end;
      not_found ->
        throw(empty);
      {error, Reason} ->
        {reply, {error, Reason}, State}
    end
  catch
    _:empty ->
      {reply, {ok, <<>>}, State}
  end;
handle_call({decr, Key, Decrement}, _From, State) ->
  case update(State#state.db, Key, string,
              fun(Item = #edis_item{value = OldV}) ->
                      try edis_util:binary_to_integer(OldV) of
                        OldInt ->
                          Item#edis_item{value = edis_util:integer_to_binary(OldInt - Decrement)}
                      catch
                        _:badarg ->
                          throw(bad_item_type)
                      end
              end, <<"0">>) of
    {ok, NewItem} ->
      {reply, {ok, edis_util:binary_to_integer(NewItem#edis_item.value)}, State};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;
handle_call(X, _From, State) ->
  {stop, {unexpected_request, X}, {unexpected_request, X}, State}.

%% @hidden
-spec handle_cast(X, state()) -> {stop, {unexpected_request, X}, state()}.
handle_cast(X, State) -> {stop, {unexpected_request, X}, State}.

%% @hidden
-spec handle_info(term(), state()) -> {noreply, state(), hibernate}.
handle_info(_, State) -> {noreply, State, hibernate}.

%% @hidden
-spec terminate(term(), state()) -> ok.
terminate(_, _) -> ok.

%% @hidden
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% =================================================================================================
%% Private functions
%% =================================================================================================
%% @private
update(Db, Key, Type, Fun, Default) ->
  try
    NewItem =
      case eleveldb:get(Db, Key, []) of
        {ok, Bin} ->
          case erlang:binary_to_term(Bin) of
            Item = #edis_item{type = Type} ->
              Fun(Item);
            Other ->
              ?THROW("Not a ~p:~n\t~p~n", [Type, Other]),
              throw(bad_item_type)
          end;
        not_found ->
          Fun(#edis_item{key = Key, type = Type, value = Default});
        {error, Reason} ->
          throw(Reason)
      end,
    case eleveldb:put(Db, Key, erlang:term_to_binary(NewItem), []) of
      ok -> {ok, NewItem};
      {error, Reason2} -> {error, Reason2}
    end
  catch
    _:Error ->
      {error, Error}
  end.

%% @private
make_call(Process, Request) ->
  make_call(Process, Request, ?DEFAULT_TIMEOUT).

%% @private
make_call(Process, Request, Timeout) ->
  ?DEBUG("CALL for ~p: ~p~n", [Process, Request]),
  ok = edis_db_monitor:notify(Process, Request),
  case gen_server:call(Process, Request, Timeout) of
    ok -> ok;
    {ok, Reply} -> Reply;
    {error, Error} ->
      ?THROW("Error trying ~p on ~p:~n\t~p~n", [Request, Process, Error]),
      throw(Error)
  end.