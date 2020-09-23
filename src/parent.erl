-module(parent).

%%%-------------------------------------------------------------------
%% @doc Functions for implementing a parent process.
%%
%%  A parent process has the following properties:
%%
%%  1. It traps exits.
%%  2. It tracks its children inside the process dictionary.
%%  3. Before terminating, it stops its children synchronously, in the reverse startup order.
%%
%%  In most cases the simplest option is to start a parent process using a higher-level abstraction
%%  such as `Parent.GenServer`. In this case you will use a subset of the API from this module to
%%  start, stop, and enumerate your children.
%%
%%  If available parent behaviours ->n't fit your purposes, you can consider building your own
%%  behaviour or a concrete process. In this case, the functions of this module will provide the
%%  necessary plumbing. To implement a parent process you need to -> the following:
%%
%%  1. Invoke `initialize/0` when the process is started.
%%  2. Use functions such as `start_child/1` to work with child processes.
%%  3. When a message is received, invoke `handle_message/1` before handling the message yourself.
%%  4. If you receive a shutdown exit message from your parent, stop the process.
%%  5. Before terminating, invoke `shutdown_all/1` to stop all the children.
%%  6. Use `infinity` as the shutdown strategy for the parent process, and `:supervisor` for its type.
%%  7. If the process is a `GenServer`, handle supervisor calls (see `supervisor_which_children/0`
%%     and `supervisor_count_children/0`).
%%  8. Implement `format_status/2` (see `Parent.GenServer` for details) where applicable.
%%
%%  If the parent process is powered by a non-interactive code (e.g. `Task`), make sure
%%  to receive messages sent to that process, and handle them properly (see points 3 and 4).
%%
%%  You can take a look at the code of `Parent.GenServer` for specific details.
%% @end
%%%-------------------------------------------------------------------

-compile({parse_transform, do}).

-include("parent.hrl").

%-import(parent_state,[]).
-export([
    initialize/0,
    is_initialized/0,
    start_child/1,
    start_child/2,
    shutdown_child/1,
    shutdown_all/0,
    shutdown_all/1,
    handle_message/1,
    await_child_termination/2,
    children/0,
    is_child/1,
    supervisor_which_children/0,
    supervisor_count_children/0,
    num_children/0,
    child_id/1,
    child_pid/1,
    child_meta/1,
    update_child_meta/2
]).

%% @doc
%% Initializes the state of the parent process.
%%
%% This function should be invoked once inside the parent process before other functions from this
%% module are used. If a parent behaviour, such as `Parent.GenServer`, is used, this function must
%% not be invoked.
-spec initialize() -> ok.
initialize() ->
    is_initialized() andalso error("Parent state is already initialized"),
    process_flag(trap_exit, true),
    store(parent_state:initialize()).

%% @doc Returns true if the parent state is initialized.
-spec is_initialized() -> boolean.
is_initialized() -> undefined =/= get(?MODULE).

%% @doc Starts the child described by the specification.
-spec start_child(start_spec()) -> supervisor:startchild_ret().
start_child(StartSpec) ->
    start_child(StartSpec, #{}).

-spec start_child(start_spec(), map() | list({term(), term()})) ->
    supervisor:startchild_ret().
start_child(StartSpec, Overrides) when is_map(Overrides) ->
    State = state(),
    ChildSpec = child_spec(StartSpec, Overrides),

    case start_child_process(State, ChildSpec) of
        {ok, Pid, TRef} ->
            store(parent_state:register_child(State, Pid, ChildSpec, TRef)),
            {ok, Pid};
        Error ->
            Error
    end;
start_child(StartSpec, Overrides) when is_list(Overrides) ->
    start_child(StartSpec, maps:from_list(Overrides)).

%% @doc
%% Terminates the child.
%%
%% This function waits for the child to terminate. In the case of explicit
%% termination, `handle_child_terminated/5` will not be invoked.
%% @end
-spec shutdown_child(child_id()) -> ok.
shutdown_child(ChildId) ->
    State = state(),

    case parent_state:child_pid(State, ChildId) of
        error ->
            error("trying to terminate an unknown child");
        {ok, Pid} ->
            {ok, Child, NewState} = parent_state:pop(State, Pid),
            do_shutdown_child(Child, shutdown),
            store(NewState)
    end.

%% @doc
%%  Terminates all running child processes.
%%
%%  Children are terminated synchronously, in the reverse order from the order they
%%  have been started in.
%% @end

shutdown_all() ->
    shutdown_all(shutdown).

-spec shutdown_all(term()) -> ok.
shutdown_all(normal) ->
    shutdown_all(shutdown);
shutdown_all(Reason) ->
    Children = parent_state:children(state()),
    SChildren = lists:sort(
        fun(#{startup_index := I1}, #{startup_index := I2}) ->
            I1 >= I2
        end,
        Children
    ),
    lists:foreach(fun(Child) -> do_shutdown_child(Child, Reason) end, SChildren),

    store(parent_state:initialize()).

%% @doc
%%  Should be invoked by the parent process for each incoming message.
%%
%%  If the given message is not handled, this function returns `nil`. In such cases, the client code
%%  should perform standard message handling. Otherwise, the message has been handled by the parent,
%%  and the client code ->esn't shouldn't treat this message as a standard message (e.g. by calling
%%  `handle_info` of the callback module).
%%
%%  However, in some cases, a client might want to -> some special processing, so the return value
%%  will contain information which might be of interest to the client. Possible values are:
%%
%%    - `{:EXIT, pid, id, child_meta, reason :: term}` - a child process has terminated
%%    - `ignore` - `Parent` handled this message, but there's no useful information to return
%%
%%  Note that you ->n't need to invoke this function in a `Parent.GenServer` callback module.
%% @end
-spec handle_message(term()) -> handle_message_response() | undefined.
handle_message(Message) ->
    case do_handle_message(state(), Message) of
        {Result, State} ->
            store(State),
            Result;
        Error ->
            Error
    end.

%% @doc
%%  Awaits for the child to terminate.
%%
%%  If the function succeeds, `handle_child_terminated/5` will not be invoked.
%% @end
-spec await_child_termination(child_id(), non_neg_integer() | infinity) ->
    {pid(), child_meta(), Reason :: term()} | timeout.
await_child_termination(ChildId, Timeout) ->
    State = state(),
    case parent_state:child_pid(State, ChildId) of
        error ->
            error("unknown child");
        {ok, Pid} ->
            receive
                {'EXIT', Pid, Reason} ->
                    {ok, Child, NewState} = parent_state:pop(State, Pid),
                    #{id := ChildId, timer_ref := Tref, meta := Meta} = Child,
                    kill_timer(Tref, Pid),
                    store(NewState),
                    {Pid, Meta, Reason}
            after Timeout -> timeout
            end
    end.

%% @doc "Returns the list of running child processes."
-spec children() -> [child()].
children() ->
    lists:map(
        fun(#{id := Id, pid := Pid, meta := Meta}) ->
            {Id, Pid, Meta}
        end,
        parent_state:children(state())
    ).

%% @doc
%%  Returns true if the child process is still running, false otherwise.
%%
%%  Note that this function might return true even if the child has terminated.
%%  This can happen if the corresponding `:EXIT` message still hasn't been
%%  processed.
%% @end
-spec is_child(child_id()) -> boolean().
is_child(Id) ->
    case child_pid(Id) of
        {ok, _} -> true;
        _ -> false
    end.

%% @doc
%%  Should be invoked by the behaviour when handling `:which_children` GenServer call.
%%
%%  You only need to invoke this function if you're implementing a parent process using a behaviour
%%  which forwards `GenServer` call messages to the `handle_call` callback. In such cases you need
%%  to respond to the client with the result of this function. Note that parent behaviours such as
%%  `Parent.GenServer` will -> this automatically.
%%
%%  If no translation of `GenServer` messages is taking place, i.e. if you're handling all messages
%%  in their original shape, this function will be invoked through `handle_message/1`.
%% @end
-spec supervisor_which_children() -> [{term(), pid(), worker, [module()] | dynamic}].
supervisor_which_children() ->
    lists:map(
        fun(#{id := Id, pid := Pid, type := Type, modules := Modules}) ->
            {Id, Pid, Type, Modules}
        end,
        parent_state:children(state())
    ).

%% @doc
%%  Should be invoked by the behaviour when handling `:count_children` GenServer call.
%%
%%  See `supervisor_which_children/0` for details.
%% @end
-spec supervisor_count_children() -> list().
%[
%  {specs, non_neg_integer()},
%  {active, non_neg_integer()},
%  {supervisors, non_neg_integer()},
%  {workers, non_neg_integer()}
%].
supervisor_count_children() ->
    maps:to_list(
        lists:foldl(
            fun(
                #{type := Type} = _Child,
                Acc = #{specs := S, active := A, supervisors := SV, workers := W}
            ) ->
                Acc#{
                    specs => S + 1,
                    active => A + 1,
                    workers => W +
                        (if
                            Type == worker -> 1;
                            true -> 0
                        end),
                    supervisors => SV +
                        (if
                            Type == supervisor -> 1;
                            true -> 0
                        end)
                }
            end,
            #{specs => 0, active => 0, supervisors => 0, workers => 0},
            parent_state:children(state())
        )
    ).

%% @doc "Returns the count of running child processes."
-spec num_children() -> non_neg_integer().
num_children() -> parent_state:num_children(state()).

%% @doc "Returns the id of a child process with the given pid."
-spec child_id(pid()) -> {ok, child_id()} | error.
child_id(Pid) -> parent_state:child_id(state(), Pid).

%% @doc "Returns the pid of a child process with the given id."
-spec child_pid(child_id()) -> {ok, pid()} | error.
child_pid(Id) -> parent_state:child_pid(state(), Id).

%% @doc "Returns the meta associated with the given child id."
-spec child_meta(child_id) -> {ok, child_meta} | error.
child_meta(Id) -> parent_state:child_meta(state(), Id).

%% @doc "Updates the meta of the given child process."
-spec update_child_meta(
    child_id(),
    fun((child_meta()) -> child_meta())
) -> ok | error.
update_child_meta(Id, UpdaterFun) ->
    case parent_state:update_child_meta(state(), Id, UpdaterFun) of
        {ok, NewState} -> store(NewState);
        Error -> Error
    end.

%%%-------------------------------------------------------------------
%% internal functions
%%%-------------------------------------------------------------------
-define(default_spec, #{meta => undefined, timeout => infinity}).

child_spec(Spec, Overrides) ->
    maps:merge(expand_child_spec(Spec), Overrides).

expand_child_spec(Mod) when is_atom(Mod) ->
    expand_child_spec({Mod, undefined});
expand_child_spec({Mod, Arg}) ->
    expand_child_spec(Mod:child_spec(Arg));
expand_child_spec(#{start := ChildStart} = ChildSpec) ->
    Spec = maps:merge(
        ?default_spec,
        default_type_and_shutdown_spec(maps:get(type, ChildSpec, worker))
    ),
    maps:merge(Spec#{modules => default_modules(ChildStart)}, ChildSpec);
expand_child_spec(_other) ->
    error("invalid child_spec").

default_type_and_shutdown_spec(worker) ->
    #{type => worker, shutdown => timer:seconds(5)};
default_type_and_shutdown_spec(supervisor) ->
    #{type => supervisor, shutdown => infinity}.

default_modules({Mod, _Fun, _Args}) ->
    [Mod];
default_modules(Fun) when is_function(Fun) ->
    [proplists:get_value(module, erlang:fun_info(Fun))].

validate_spec(State, ChildSpec) ->
    Id = maps:get(id, ChildSpec),
    do([error_m ||
        ok <- check_id_type(Id),
        ok <- check_id_uniqueness(State, Id),
        %ok <- check_missing_deps(State, ChildSpec),
        %ok <- check_valid_shutdown_group(State, ChildSpec)
        ok
    ]).

check_id_type(Pid) when is_pid(Pid) -> {error, invalid_child_id};
check_id_type(_Other) -> ok.

check_id_uniqueness(State, Id) ->
    case parent_state:child_pid(State, Id) of
        {ok, Pid} -> {error, {already_started, Pid}};
        error -> ok
    end.

invoke_start_function({Mod, Func, Args}) -> apply(Mod, Func, Args);
invoke_start_function(Fun) when is_function(Fun, 0) -> Fun().

start_child_process(State, ChildSpec) ->
    case validate_spec(State, ChildSpec) of
        ok ->
            case invoke_start_function(maps:get(start, ChildSpec)) of
                ignore ->
                    {ok, undefined}; % ok, undefined, nil?
                {ok, Pid} ->
                    TRef =
                        case maps:get(timeout, ChildSpec) of
                            infinity -> undefined;
                            Timeout ->
                                erlang:send_after(
                                    Timeout,
                                    self(),
                                    {?MODULE, child_timeout, Pid}
                                )
                        end,
                    {ok, Pid, TRef};
                Error ->
                    Error
            end;
        Error -> Error
    end.

do_handle_message(State, {'EXIT', Pid, Reason}) ->
    case parent_state:pop(State, Pid) of
        {ok, #{id := Id, meta := Meta, timer_ref := TRef} = _Child, NewState} ->
            kill_timer(TRef, Pid),
            {{'EXIT', Pid, Id, Meta, Reason}, NewState};
        error ->
            undefined
    end;
do_handle_message(State, {?MODULE, child_timeout, Pid}) ->
    {ok, #{id := Id, meta := Meta} = Child, NewState} =
        parent_state:pop(State, Pid),
    do_shutdown_child(Child, kill),
    {{'EXIT', Pid, Id, Meta, timeout}, NewState};
do_handle_message(State, {'$gen_call', Client, which_children}) ->
    gen_server:reply(Client, supervisor_which_children()),
    {ignore, State};
do_handle_message(State, {'$gen_call', Client, count_children}) ->
    gen_server:reply(Client, supervisor_count_children()),
    {ignore, State};
do_handle_message(_State, _Other) ->
    undefined.

do_shutdown_child(Child, Reason) ->
    #{pid := Pid, timer_ref := TRef, shutdown := Shutdown} = Child,
    kill_timer(TRef, Pid),

    ExitSignal =
        if
            Shutdown == brutal_kill -> kill;
            true -> Reason
        end,
    WaitTime =
        if
            ExitSignal == kill -> infinity;
            true -> Shutdown
        end,

    sync_stop_process(Pid, ExitSignal, WaitTime).

sync_stop_process(Pid, ExitSignal, WaitTime) ->
    exit(Pid, ExitSignal),

    receive
        {'EXIT', Pid, _Reason} -> ok
    after WaitTime ->
        exit(Pid, kill),
        receive
            {'EXIT', Pid, _Reason} -> ok
        end
    end.

kill_timer(undefined, _Pid) ->
    ok;
kill_timer(TimerRef, Pid) ->
    erlang:cancel_timer(TimerRef),
    receive
        {_Parent, child_timeout, Pid} -> ok
    after 0 -> ok
    end.

-spec state() -> parent_state:t().
state() ->
    State = get(?MODULE),
    undefined =:= State andalso error("Parent is not initialized"),
    State.

-spec store(parent_state:t()) -> ok.
store(State) ->
    put(?MODULE, State),
    ok.
