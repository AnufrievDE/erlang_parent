-module(test_server).

-behavior(gen_server_parent).

%-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    call/2,
    cast/2,
    send/2,
    terminated_jobs/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_child_terminated/5,
    child_spec/1,
    terminate/2,
    code_change/3
]).

start_link(Initializer) -> gen_server_parent:start_link(?MODULE, Initializer).

call(Pid, Fun) -> gen_server:call(Pid, Fun).

cast(Pid, Fun) -> gen_server:cast(Pid, Fun).

send(Pid, Fun) -> Pid ! Fun.

terminated_jobs() -> get(terminated_jobs).

%  @impl GenServer
init(Initializer) ->
    put(terminated_jobs, []),
    {ok, Initializer()}.

%  @impl GenServer
handle_call(Fun, _From, State) ->
    {Response, NewState} = Fun(State),
    {reply, Response, NewState}.

%  @impl GenServer
handle_cast(Fun, State) -> {noreply, Fun(State)}.

%  @impl GenServer
handle_info(Fun, State) -> {noreply, Fun(State)}.

%  @impl Parent.GenServer
handle_child_terminated(Id, Meta, Pid, Reason, State) ->
    TerminationInfo = #{id => Id, meta => Meta, pid => Pid, reason => Reason},
    put(terminated_jobs, [TerminationInfo | get(terminated_jobs)]),
    {noreply, State}.

child_spec(Initializer) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Initializer]},
        shutdown => infinity,
        type => supervisor
    }.

terminate(_Reason, _State) ->
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.
