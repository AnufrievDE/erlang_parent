-module(parent).

%%%-------------------------------------------------------------------
%% @doc Functions for implementing a parent process.
%%
%% A parent process has the following properties:
%%
%% 1. It traps exits.
%% 2. It tracks its children inside the process dictionary.
%% 3. Before terminating, it stops its children synchronously, in the reverse startup order.
%%
%% In most cases the simplest option is to start a parent process using a higher-level abstraction
%% such as `gen_server_parent`. In this case you will use a subset of the API from this module to
%% start, stop, and enumerate your children.
%%
%% If available parent behaviours doesn't fit your purposes, you can consider building your own
%% behaviour or a concrete process. In this case, the functions of this module will provide the
%% necessary plumbing. To implement a parent process you need to -> the following:
%%
%% 1. Invoke `initialize/0` when the process is started.
%% 2. Use functions such as `start_child/1` to work with child processes.
%% 3. When a message is received, invoke `handle_message/1` before handling the message yourself.
%% 4. If you receive a shutdown exit message from your parent, stop the process.
%% 5. Before terminating, invoke `shutdown_all/1` to stop all the children.
%% 6. Use `infinity` as the shutdown strategy for the parent process, and `supervisor` for its type.
%% 7. If the process is a `gen_server`, handle supervisor calls (see `supervisor:which_children/0`
%%    and `supervisor:count_children/0`).
%% 8. Implement `format_status/2` (see `gen_server_parent` for details) where applicable.
%%
%% If the parent process is powered by a code that not adhering to the OTP Design Principles
%% (e.g. plain erlang, modules that does not implement gen_* behaviors), make sure
%% to receive messages sent to that process, and handle them properly (see points 3 and 4).
%%
%% You can take a look at the code of `gen_server_parent` for specific details.
%% @end
%%%-------------------------------------------------------------------

-include("parent.hrl").
-include_lib("kernel/include/logger.hrl").

-export_type([child_spec/0, child_id/0, child_meta/0, shutdown/0, start_spec/0,
    child/0, handle_message_response/0]).

-export([
    child_spec/1, child_spec/2,
    parent_spec/0, parent_spec/1,
    initialize/0,
    is_initialized/0,
    start_child/1, start_child/2,
    start_all_children/1,
    shutdown_child/1,
    shutdown_all/0, shutdown_all/1,
    handle_message/1,
    await_child_termination/2,
    children/0,
    is_child/1,
    supervisor_which_children/0,
    supervisor_count_children/0,
    supervisor_get_childspec/1,
    num_children/0,
    child_id/1,
    child_pid/1,
    child_meta/1,
    update_child_meta/2
]).

%% ----------------------------------------------------------------------------
%% @doc 
%% Builds and overrides a child specification
%%
%% This operation is similar to
%% [supervisor:child_spec/1]
%% @end
%% ----------------------------------------------------------------------------
-define(default_spec, #{id => undefined, meta => undefined, timeout => infinity}).

-spec child_spec(start_spec(), map() | child_spec()) -> child_spec().
child_spec(Spec) -> child_spec(Spec, #{}).
child_spec(Spec, Overrides) ->
    maps:merge(expand_child_spec(Spec), Overrides).

-spec parent_spec(map() | child_spec()) -> child_spec().
parent_spec() -> parent_spec(#{}).
parent_spec(Overrides) ->
    maps:merge(#{shutdown => infinity, type => supervisor}, Overrides).

%% ----------------------------------------------------------------------------
%% @doc
%% Initializes the state of the parent process.
%%
%% This function should be invoked once inside the parent process before other functions from this
%% module are used. If a parent behaviour, such as `gen_server_parent`, is used, this function must
%% not be invoked.
%% @end
%% ----------------------------------------------------------------------------
-spec initialize() -> ok.
initialize() ->
    is_initialized() andalso error("Parent state is already initialized"),
    process_flag(trap_exit, true),
    store(parent_state:initialize()).

%% @doc Returns true if the parent state is initialized.
-spec is_initialized() -> boolean().
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

%% ----------------------------------------------------------------------------
%% @doc
%% Synchronously starts all children.
%% 
%% If some child fails to start, all of the children will be taken down and the parent process
%% will exit.
%% @end
%% ----------------------------------------------------------------------------
-spec start_all_children([start_spec()]) -> [pid() | undefined].
start_all_children(ChildSpecs) ->
    lists:map(
        fun(ChildSpec) ->
            FullSpec = child_spec(ChildSpec),
            case start_child(FullSpec) of
                {ok, Pid} -> Pid;
                {error, Error} ->
                    Msg = io_lib:format(
                        "Error starting the child ~p: ~p~n",
                        [maps:get(id, FullSpec), Error]),
                    give_up(state(), start_error, Msg)
            end
        end, ChildSpecs).

%% ----------------------------------------------------------------------------
%% @doc
%% Terminates the child.
%%
%% This function waits for the child to terminate. In the case of explicit
%% termination, `handle_child_terminated/5` will not be invoked.
%% @end
%% ----------------------------------------------------------------------------
-spec shutdown_child(child_ref()) -> ok.
shutdown_child(ChildRef) ->
    case parent_state:pop(state(), ChildRef) of
        {ok, Child, NewState} ->
            do_shutdown_child(Child, shutdown),
            store(NewState);
        error -> error
    end.

%% ----------------------------------------------------------------------------
%% @doc
%% Terminates all running child processes.
%%
%% Children are terminated synchronously, in the reverse order from the order they
%% have been started in.
%% @end
%% ----------------------------------------------------------------------------

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

%% ----------------------------------------------------------------------------
%% @doc
%% Should be invoked by the parent process for each incoming message.
%%
%% If the given message is not handled, this function returns `undefined`. In such cases, the client code
%% should perform standard message handling. Otherwise, the message has been handled by the parent,
%% and the client code  doesn't shouldn't treat this message as a standard message (e.g. by calling
%% `handle_info` of the callback module).
%%
%% However, in some cases, a client might want to do some special processing, so the return value
%% will contain information which might be of interest to the client. Possible values are:
%%
%%   - `{'EXIT', Pid, Id, ChildMeta, Reason :: term()}` - a child process has terminated
%%   - `ignore` - `parent` handled this message, but there's no useful information to return
%%
%% Note that you don't need to invoke this function in a `gen_server_parent` callback module.
%% @end
%% ----------------------------------------------------------------------------
-spec handle_message(term()) -> handle_message_response() | undefined.
handle_message({'$parent_call', Client, {parent_client, Function, Args}}) ->
    gen_server:reply(Client, apply(?MODULE, Function, Args)),
    ignore;
handle_message(Message) ->
    case do_handle_message(state(), Message) of
        {Result, State} ->
            store(State),
            Result;
        Error ->
            Error
    end.

%% ----------------------------------------------------------------------------
%% @doc
%% Awaits for the child to terminate.
%%
%% If the function succeeds, `handle_child_terminated/5` will not be invoked.
%% @end
%% ----------------------------------------------------------------------------
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
                    #{spec := #{id := ChildId}, timer_ref := Tref, meta := Meta} = Child,
                    kill_timer(Tref, Pid),
                    store(NewState),
                    {Pid, Meta, Reason}
            after Timeout -> timeout
            end
    end.

%% @doc "Returns the list of running child processes."
-spec children() -> list(child()).
children() ->
    lists:map(
        fun(#{spec := #{id := Id}, pid := Pid, meta := Meta}) -> 
            #{id => Id, pid => Pid, meta => Meta}
        end, lists:sort(
            fun(#{startup_index := I1}, #{startup_index := I2}) ->
                I1 =< I2
            end, parent_state:children(state()))
    ).

%% ----------------------------------------------------------------------------
%% @doc
%% Returns true if the child process is still running, false otherwise.
%%
%% Note that this function might return true even if the child has terminated.
%% This can happen if the corresponding 'EXIT' message still hasn't been
%% processed.
%% @end
%% ----------------------------------------------------------------------------
-spec is_child(child_ref()) -> boolean().
is_child(ChildRef) ->
    error =/= parent_state:child(state(), ChildRef).

%% ----------------------------------------------------------------------------
%% @doc
%% Should be invoked by the behaviour when handling `which_children` gen_server call.
%%
%% You only need to invoke this function if you're implementing a parent process using a behaviour
%% which forwards `gen_server` call messages to the `handle_call` callback. In such cases you need
%% to respond to the client with the result of this function. Note that parent behaviours such as
%% `gen_server_parent` will do this automatically.
%%
%% If no translation of `gen_server` messages is taking place, i.e. if you're handling all messages
%% in their original shape, this function will be invoked through `handle_message/1`.
%% @end
%% ----------------------------------------------------------------------------
-spec supervisor_which_children() ->
    [{term(), pid(), worker | supervisor, [module()] | dynamic}].
supervisor_which_children() ->
    lists:map(
        fun(#{pid := Pid, spec := #{id := Id, type := T, modules := Mods}}) ->
            {Id, Pid, T, Mods}
        end, parent_state:children(state())
    ).

%% ----------------------------------------------------------------------------
%% @doc
%% Should be invoked by the behaviour when handling `count_children` gen_server call.
%%
%% See `supervisor:which_children/0` for details.
%% @end
%% ----------------------------------------------------------------------------
-spec supervisor_count_children() -> 
    [{specs | active | supervisors | workers, non_neg_integer()}].

-define(count_children_acc(Specs, Active, Supervisors, Workers), [
    {specs, Specs},
    {active, Active},
    {supervisors, Supervisors},
    {workers, Workers}
]).

supervisor_count_children() ->
    lists:foldl(fun(#{spec := Spec}, ?count_children_acc(S, A, SV, W)) ->
        case maps:get(type, Spec) of
            worker -> ?count_children_acc(S+1, A+1, SV, W + 1);
            supervisor -> ?count_children_acc(S+1, A+1, SV + 1, W)
        end
    end, ?count_children_acc(0,0,0,0), parent_state:children(state())).


%% ----------------------------------------------------------------------------
%% @doc Should be invoked by the behaviour when handling `get_childspec` gen_server call.
%%
%% See `supervisor:get_childspec/2` for details.
%% @end
%% ----------------------------------------------------------------------------
-spec supervisor_get_childspec(child_ref()) ->
    {ok, child_spec()} | {error, not_found}.
supervisor_get_childspec(ChildRef) ->
    case parent_state:child(state(), ChildRef) of
        {ok, #{spec := Spec}} -> {ok, Spec};
        error -> {error, not_found}
    end.

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
-spec child_meta(child_id()) -> {ok, child_meta()} | error.
child_meta(Id) -> parent_state:child_meta(state(), Id).

%% @doc "Updates the meta of the given child process."
-spec update_child_meta(child_ref(), fun((child_meta()) -> child_meta())) ->
    ok | error.
update_child_meta(ChildRef, UpdaterFun) ->
    case parent_state:update_child_meta(state(), ChildRef, UpdaterFun) of
        {ok, NewState} -> store(NewState);
        Error -> Error
    end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
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
    case check_id_type(Id) of
        ok -> check_id_uniqueness(State, Id);
        Error -> Error
    end.

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
                    {ok, undefined};
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
        {ok, #{spec := Spec, meta := Meta, timer_ref := TRef}, NewState} ->
            kill_timer(TRef, Pid),
            {{'EXIT', Pid, maps:get(id, Spec), Meta, Reason}, NewState};
        error ->
            undefined
    end;
do_handle_message(State, {?MODULE, child_timeout, Pid}) ->
    {ok, #{spec := Spec, meta := Meta} = Child, NewState} =
        parent_state:pop(State, Pid),
    do_shutdown_child(Child, kill),
    {{'EXIT', Pid, maps:get(id, Spec), Meta, timeout}, NewState};
do_handle_message(State, {'$gen_call', Client, which_children}) ->
    gen_server:reply(Client, supervisor_which_children()),
    {ignore, State};
do_handle_message(State, {'$gen_call', Client, count_children}) ->
    gen_server:reply(Client, supervisor_count_children()),
    {ignore, State};
do_handle_message(State, {'$gen_call', Client, {get_childspec, ChildRef}}) ->
    gen_server:reply(Client, supervisor_get_childspec(ChildRef)),
    {ignore, State};
do_handle_message(_State, _Other) ->
    undefined.

do_shutdown_child(Child, Reason) ->
    #{pid := Pid, timer_ref := TRef, spec := #{shutdown := Shutdown}} = Child,
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

%% @doc false
give_up(State, ExitReason, ErrorMsg) ->
    ?LOG(error, ErrorMsg),
    store(State),
    shutdown_all(),
    exit(ExitReason).