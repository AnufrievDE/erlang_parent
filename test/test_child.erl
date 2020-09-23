-module(test_child).

-behavior(gen_server).

-export([
    start_link/0, start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    terminate/2,
    child_spec/1, child_spec/2
]).

start_link() ->
    start_link([]).

start_link(undefined) ->
    start_link([]);
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%  @impl GenServer
init(Args) ->
    proplists:get_value(is_trap_exit, Args, false) andalso
        process_flag(trap_exit, true),
    (proplists:get_value(init, Args, fun(A) -> {ok, A} end))(Args).

%  @impl GenServer
handle_call(_, _From, State) ->
    {reply, ignore, State}.

%  @impl GenServer
handle_cast(_, State) ->
    {noreply, State}.

%  @impl GenServer
terminate(_Reason, Opts) ->
    proplists:get_value(is_block_terminate, Opts, false) andalso
        timer:sleep(infinity).

child_spec(InitArg) ->
    child_spec(InitArg, #{}).

child_spec(InitArg, Opts) ->
    Default = #{
        id => ?MODULE,
        start => {?MODULE, start_link, [InitArg]}
    },
    maps:merge(Default, Opts).
