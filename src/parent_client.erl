-module(parent_client).

-export([children/1,
    child_pid/2, child_meta/2,
    start_child/2, start_child/3, %restart_child/2,
    shutdown_child/2,
    shutdown_all/1, shutdown_all/2,
    %return_children/2,
    update_child_meta/3,
    whereis_name/1]).

%% ----------------------------------------------------------------------------
%% @doc
%% Functions for interacting with parent's children from other processes.
%%
%% All of these functions issue a call to the parent process. Therefore, they can't be used from
%% inside the parent process. Use functions from the `Parent` module instead to interact with the
%% children from within the process.
%%
%% Likewise these functions can't be invoked inside the child process during its initialization.
%% Defer interacting with the parent to `gen_server:handle_continue/2`, or if you're using another
%% behaviour which doesn't support such callback, send yourself a message to safely do the post-init
%% interaction with the parent.
%% @end
%% ----------------------------------------------------------------------------

%% ----------------------------------------------------------------------------
%% @doc Client interface to `parent:children/0`.
%% ----------------------------------------------------------------------------
-spec children(gen_server:server_ref()) -> [parent:child()].
children(Parent) -> call(Parent, children).
    %case parent_registry:table(Parent) of
    %    {ok, Table} -> parent_registry:children(Table);
    %    error -> 
    %        call(Parent, children)
    %end.

%% @doc Client interface to `parent:child_pid/1`.
-spec child_pid(gen_server:server_ref(), parent:child_id()) -> {ok, pid()} | error.
child_pid(Parent, ChildId) -> call(Parent, child_pid, [ChildId]).
    %case parent_registry:table(Parent) of
    %    {ok, Table} -> parent_registry:child_pid(Table, ChildId)
    %    error -> call(Parent, child_pid, [ChildId])
    %end.

%% @doc Client interface to `parent:child_meta/1`.
-spec child_meta(gen_server:server_ref(), parent:child_ref()) -> {ok, parent:child_meta()} | error.
child_meta(Parent, ChildRef) -> call(Parent, child_meta, [ChildRef]).
    %case parent_registry:table(Parent) of
    %    {ok, Table} -> parent_registry:child_meta(Table, ChildRef);
    %    error -> call(Parent, child_meta, [ChildRef])
    %end.

%% @doc Client interface to `parent:start_child/2`.
-spec start_child(
        gen_server:server_ref(),
        parent:start_spec(),
        map() | list({term(), term()})
    ) -> parent:on_start_child().
start_child(Parent, ChildSpec) -> start_child(Parent, ChildSpec, []).
start_child(Parent, ChildSpec, Overrides) ->
    call(Parent, start_child, [ChildSpec, Overrides], infinity).

%% @doc Client interface to `parent:shutdown_child/1`.
-spec shutdown_child(gen_server:server_ref(), parent:child_ref()) -> ok.
%    {ok, parent:stopped_children()} | error.
shutdown_child(Parent, ChildRef) ->
    call(Parent, shutdown_child, [ChildRef], infinity).

%% @doc Client interface to `parent:restart_child/1`.
%-spec restart_child(gen_server:server_ref(), parent:child_ref()) -> ok | error.
%restart_child(Parent, ChildRef) ->
%    call(Parent, restart_child, [ChildRef], infinity).

%% @doc Client interface to `parent:shutdown_all/1`.
-spec shutdown_all(gen_server:server_ref(), any()) -> ok. %parent:stopped_children().
shutdown_all(ServerRef) -> shutdown_all(ServerRef, shutdown).
shutdown_all(ServerRef, Reason) ->
    call(ServerRef, shutdown_all, [Reason], infinity).

%% @doc "Client interface to `parent:return_children/1`."
%-spec return_children(gen_server:server_ref(), parent:stopped_children()) -> ok.
%return_children(Parent, StoppedChildren) ->
%    call(Parent, return_children, [StoppedChildren], infinity).

%% @doc Client interface to `parent:update_child_meta/2`"
-spec update_child_meta(
        gen_server:server_ref(),
        parent:child_ref(),
        fun((parent:child_meta()) -> parent:child_meta())
    ) -> ok | error.
update_child_meta(Parent, ChildRef, Updater) ->
    call(Parent, update_child_meta, [ChildRef, Updater], infinity).

%@doc false
whereis_name({Parent, ChildId}) ->
    case child_pid(Parent, ChildId) of
        {ok, Pid} -> Pid;
        error -> undefined
    end.

%%%----------------------------------------------------------------------------
%%% Internal functions:
%%%----------------------------------------------------------------------------
call(ServerRef, Function) -> call(ServerRef, Function, []).
call(ServerRef, Function, Args) -> call(ServerRef, Function, Args, 5000).
call(ServerRef, Function, Args, Timeout) when
    (is_integer(Timeout) andalso Timeout >= 0) orelse Timeout =:= infinity ->
    %% This is the custom implementation of a call. We're not using standard gen_server calls to
    %% ensure that this call won't end up in some custom behaviour's handle_call.
    Req = {?MODULE, Function, Args},

    case gen_server_parent:whereis(ServerRef) of
        undefined ->
            exit({noproc, {?MODULE, call, [ServerRef, Req, Timeout]}});
        Pid when Pid == self() ->
            exit({calling_self, {?MODULE, call, [ServerRef, Req, Timeout]}});
        Pid ->
            try gen:call(Pid, '$parent_call', Req, Timeout) of
                {ok, Res} -> Res
            catch
                exit:Reason ->
                    exit({Reason, {?MODULE, call, [ServerRef, Req, Timeout]}})
            end
    end.