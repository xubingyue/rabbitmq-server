%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_vhost).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-export([add/1, delete/1, exists/1, list/0, with/2, assert/1, update/2,
         set_limits/2, limits_of/1]).
-export([info/1, info/2, info_all/0, info_all/1, info_all/2, info_all/3]).


-spec add(rabbit_types:vhost()) -> 'ok'.
-spec delete(rabbit_types:vhost()) -> 'ok'.
-spec update(rabbit_types:vhost(), rabbit_misc:thunk(A)) -> A.
-spec exists(rabbit_types:vhost()) -> boolean().
-spec list() -> [rabbit_types:vhost()].
-spec with(rabbit_types:vhost(), rabbit_misc:thunk(A)) -> A.
-spec assert(rabbit_types:vhost()) -> 'ok'.

-spec info(rabbit_types:vhost()) -> rabbit_types:infos().
-spec info(rabbit_types:vhost(), rabbit_types:info_keys())
                -> rabbit_types:infos().
-spec info_all() -> [rabbit_types:infos()].
-spec info_all(rabbit_types:info_keys()) -> [rabbit_types:infos()].
-spec info_all(rabbit_types:info_keys(), reference(), pid()) ->
                         'ok'.

%%----------------------------------------------------------------------------

-define(INFO_KEYS, [name, tracing]).

add(VHostPath) ->
    rabbit_log:info("Adding vhost '~s'~n", [VHostPath]),
    R = rabbit_misc:execute_mnesia_transaction(
          fun () ->
                  case mnesia:wread({rabbit_vhost, VHostPath}) of
                      []  -> ok = mnesia:write(rabbit_vhost,
                                               #vhost{virtual_host = VHostPath},
                                               write);
                      [_] -> mnesia:abort({vhost_already_exists, VHostPath})
                  end
          end,
          fun (ok, true) ->
                  ok;
              (ok, false) ->
                  [rabbit_exchange:declare(
                     rabbit_misc:r(VHostPath, exchange, Name),
                     Type, true, false, Internal, []) ||
                      {Name, Type, Internal} <-
                          [{<<"">>,                   direct,  false},
                           {<<"amq.direct">>,         direct,  false},
                           {<<"amq.topic">>,          topic,   false},
                           %% per 0-9-1 pdf
                           {<<"amq.match">>,          headers, false},
                           %% per 0-9-1 xml
                           {<<"amq.headers">>,        headers, false},
                           {<<"amq.fanout">>,         fanout,  false},
                           {<<"amq.rabbitmq.trace">>, topic,   true}]],
                  ok
          end),
    rabbit_event:notify(vhost_created, info(VHostPath)),
    R.

delete(VHostPath) ->
    %% FIXME: We are forced to delete the queues and exchanges outside
    %% the TX below. Queue deletion involves sending messages to the queue
    %% process, which in turn results in further mnesia actions and
    %% eventually the termination of that process. Exchange deletion causes
    %% notifications which must be sent outside the TX
    rabbit_log:info("Deleting vhost '~s'~n", [VHostPath]),
    QDelFun = fun (Q) -> rabbit_amqqueue:delete(Q, false, false) end,
    [assert_benign(rabbit_amqqueue:with(Name, QDelFun)) ||
        #amqqueue{name = Name} <- rabbit_amqqueue:list(VHostPath)],
    [assert_benign(rabbit_exchange:delete(Name, false)) ||
        #exchange{name = Name} <- rabbit_exchange:list(VHostPath)],
    Funs = rabbit_misc:execute_mnesia_transaction(
          with(VHostPath, fun () -> internal_delete(VHostPath) end)),
    ok = rabbit_event:notify(vhost_deleted, [{name, VHostPath}]),
    [ok = Fun() || Fun <- Funs],
    ok.

assert_benign(ok)                 -> ok;
assert_benign({ok, _})            -> ok;
assert_benign({error, not_found}) -> ok;
assert_benign({error, {absent, Q, _}}) ->
    %% Removing the mnesia entries here is safe. If/when the down node
    %% restarts, it will clear out the on-disk storage of the queue.
    case rabbit_amqqueue:internal_delete(Q#amqqueue.name) of
        ok                 -> ok;
        {error, not_found} -> ok
    end.

internal_delete(VHostPath) ->
    [ok = rabbit_auth_backend_internal:clear_permissions(
            proplists:get_value(user, Info), VHostPath)
     || Info <- rabbit_auth_backend_internal:list_vhost_permissions(VHostPath)],
    Fs1 = [rabbit_runtime_parameters:clear(VHostPath,
                                           proplists:get_value(component, Info),
                                           proplists:get_value(name, Info))
     || Info <- rabbit_runtime_parameters:list(VHostPath)],
    Fs2 = [rabbit_policy:delete(VHostPath, proplists:get_value(name, Info))
           || Info <- rabbit_policy:list(VHostPath)],
    ok = mnesia:delete({rabbit_vhost, VHostPath}),
    Fs1 ++ Fs2.

exists(VHostPath) ->
    mnesia:dirty_read({rabbit_vhost, VHostPath}) /= [].

list() ->
    mnesia:dirty_all_keys(rabbit_vhost).

with(VHostPath, Thunk) ->
    fun () ->
            case mnesia:read({rabbit_vhost, VHostPath}) of
                [] ->
                    mnesia:abort({no_such_vhost, VHostPath});
                [_V] ->
                    Thunk()
            end
    end.

%% Like with/2 but outside an Mnesia tx
assert(VHostPath) -> case exists(VHostPath) of
                         true  -> ok;
                         false -> throw({error, {no_such_vhost, VHostPath}})
                     end.

update(VHostPath, Fun) ->
    case mnesia:read({rabbit_vhost, VHostPath}) of
        [] ->
            mnesia:abort({no_such_vhost, VHostPath});
        [V] ->
            V1 = Fun(V),
            ok = mnesia:write(rabbit_vhost, V1, write),
            V1
    end.

limits_of(VHostPath) when is_binary(VHostPath) ->
    assert(VHostPath),
    case mnesia:dirty_read({rabbit_vhost, VHostPath}) of
        [] ->
            mnesia:abort({no_such_vhost, VHostPath});
        [#vhost{limits = Limits}] ->
            Limits
    end;
limits_of(#vhost{virtual_host = Name}) ->
    limits_of(Name).

set_limits(VHost = #vhost{}, undefined) ->
    VHost#vhost{limits = undefined};
set_limits(VHost = #vhost{}, Limits) ->
    VHost#vhost{limits = Limits}.

%%----------------------------------------------------------------------------

infos(Items, X) -> [{Item, i(Item, X)} || Item <- Items].

i(name,    VHost) -> VHost;
i(tracing, VHost) -> rabbit_trace:enabled(VHost);
i(Item, _)        -> throw({bad_argument, Item}).

info(VHost)        -> infos(?INFO_KEYS, VHost).
info(VHost, Items) -> infos(Items, VHost).

info_all()      -> info_all(?INFO_KEYS).
info_all(Items) -> [info(VHost, Items) || VHost <- list()].

info_all(Ref, AggregatorPid)        -> info_all(?INFO_KEYS, Ref, AggregatorPid).
info_all(Items, Ref, AggregatorPid) ->
    rabbit_control_misc:emitting_map(
       AggregatorPid, Ref, fun(VHost) -> info(VHost, Items) end, list()).
