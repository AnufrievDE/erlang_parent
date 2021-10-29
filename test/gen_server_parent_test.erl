-module(gen_server_parent_test).

-include("test.hrl").

-include_lib("eunit/include/eunit.hrl").

init_test() ->
    {ok, Pid} = test_server:start_link(fun() -> initial_state end),
    ?assert(sys:get_state(Pid) == initial_state).

call_test() ->
    {ok, Pid} = test_server:start_link(fun() -> initial_state end),

    ?assert(
        test_server:call(
            Pid,
            fun(State) -> {{response, State}, new_state} end
        ) ==
            {response, initial_state}
    ),
    ?assert(sys:get_state(Pid) == new_state).

call_which_throws_a_reply_test() ->
    {ok, Pid} = test_server:start_link(fun() -> initial_state end),
    Res = test_server:call(Pid, fun(_State) -> throw({reply, response, new_state}) end),
    ?assertEqual(response, Res),
    %?assert(test_server:call(Pid, fun(_State) -> throw({reply, response, new_state}) end)),
    ?assert(sys:get_state(Pid) == new_state).

cast_test() ->
    {ok, Pid} = test_server:start_link(fun() -> initial_state end),
    ?assert(test_server:cast(Pid, fun(State) -> {updated_state, State} end) == ok),
    ?assert(sys:get_state(Pid) == {updated_state, initial_state}).

send_test() ->
    {ok, Pid} = test_server:start_link(fun() -> initial_state end),
    test_server:send(Pid, fun(State) -> {updated_state, State} end),
    ?assert(sys:get_state(Pid) == {updated_state, initial_state}).

starting_a_child_test() ->
    {ok, Parent} = test_server:start_link(fun() -> initial_state end),
    ChildId = make_ref(),

    start_child(Parent, #{
        id => ChildId,
        start => fun() -> {ok, spawn_link(fun test_helper:receive_loop/0)} end,
        %start => {erlang, spawn_link, [fun test_helper:receive_loop/0]},
        %start => {Agent, start_link, [fun() -> ok end]},
        type => worker
    }),

    ?assert(test_server:call(Parent, fun(State) -> {parent:is_child(ChildId), State} end)).

terminates_children_before_the_parent_stops_test() ->
    {ok, Parent} = test_server:start_link(fun() -> initial_state end),

    ChildId = make_ref(),

    start_child(Parent, #{
        id => ChildId,
        start => fun() -> {ok, spawn_link(fun test_helper:receive_loop/0)} end,
        %start => {Agent, start_link, [fun() -> ok end]},
        type => worker
    }),

    {ok, Child} = test_server:call(Parent, fun(State) -> {parent:child_pid(ChildId), State} end),

    erlang:monitor(process, Parent),
    erlang:monitor(process, Child),

    gen_server:stop(Parent),

    F = fun() ->
        receive
            {'DOWN', _, process, Pid, _} -> Pid
        after ?timeout -> false
        end
    end,

    Pid1 = F(),
    Pid2 = F(),

    ?assert([Pid1, Pid2] == [Child, Parent]).

%  describe "supervisor_test() ->
which_children_test() ->
    {ok, Pid} = test_server:start_link(fun() -> initial_state end),
    StartFun = fun() -> {ok, spawn_link(fun test_helper:receive_loop/0)} end,

    [#{pid := Child1Pid}, #{pid := Child2Pid}] = [
        start_child(Pid, Spec)
        || Spec <- [
               #{id => 1, type => worker, start => StartFun},
               #{id => 2, type => supervisor, start => StartFun}
           ]
    ],

    Children = supervisor:which_children(Pid),
    ?assertMatch([_Child1, _Child2], Children),
    [Child1, Child2] = Children,
    ?assertMatch({1, Child1Pid, worker, [?MODULE]}, Child1),
    ?assertMatch({2, Child2Pid, supervisor, [?MODULE]}, Child2).

count_children_test() ->
    {ok, Pid} = test_server:start_link(fun() -> initial_state end),

    lists:map(
        fun({Id, Type}) ->
            start_child(
                Pid,
                #{
                    id => Id,
                    start => fun() -> {ok, spawn_link(fun test_helper:receive_loop/0)} end,
                    %start => {Agent, start_link, [fun() -> ok end]},
                    type => Type
                }
            )
        end,
        [{1, worker}, {2, supervisor}]
    ),

    ?assert(
        supervisor:count_children(Pid) == [{specs, 2}, {active, 2}, {supervisors, 1}, {workers, 1}]
    ).

get_callback_module_test() ->
    {ok, Pid} = test_server:start_link(fun() -> initial_state end),
    ?assert(supervisor:get_callback_module(Pid) == test_server).

start_child(ParentPid, ChildSpec) ->
    Id = maps:get(id, ChildSpec, make_ref()),
    #{id := ChildId, meta := ChildMeta} = ChildSpec =
        maps:merge(#{id => Id, meta => {Id, meta}}, ChildSpec),

    test_server:call(
        ParentPid,
        fun(State) ->
            {ok, ChildPid} = parent:start_child(ChildSpec),
            {#{id => ChildId, pid => ChildPid, meta => ChildMeta}, State}
        end
    ).
