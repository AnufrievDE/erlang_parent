-module(parent_test).

%-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(test_helper, [receive_once/0, receive_once/1]).

% "initialize/0_test() ->
traps_exists_test() ->
    process_flag(trap_exit, false),
    parent:initialize(),
    ?assert(process_info(self(), trap_exit) == {trap_exit, true}).

raises_if_called_multiple_times_test() ->
    parent:initialize(),
    ?assertException(error, "Parent state is already initialized", parent:initialize()).

% "start_child_test() ->
returns_the_pid_of_the_started_process_on_success_test() ->
    parent:initialize(),
    Parent = self(),
    {ok, Child} =
        parent:start_child({test_server, fun() -> Parent ! self() end}),
    ?assertMatch(Child, receive_once()).

%assert_receive Child.

accepts_module_as_a_single_argument_test() ->
    parent:initialize(),
    ?assertMatch({ok, _Child}, parent:start_child(test_child)).

accepts_a_child_specification_map_test() ->
    parent:initialize(),

    ?assertMatch(
        {ok, _Child},
        parent:start_child(#{id => child, start => {test_child, start_link, []}})
    ).

accepts_a_zero_arity_function_in_the_start_key_of_the_child_spec_test() ->
    parent:initialize(),

    ?assertMatch(
        {ok, _Child},
        parent:start_child(#{id => child, start => fun() -> test_child:start_link() end})
    ).

handles_ignore_by_started_process_test() ->
    parent:initialize(),
    ?assertEqual({ok, undefined}, parent:start_child({test_child, [{init, fun(_) -> ignore end}]})).

handles_error_by_the_started_process_test() ->
    parent:initialize(),

    ?assertEqual(
        {error, some_reason},
        parent:start_child({test_child, [{init, fun(_) -> {stop, some_reason} end}]})
    ).


fails_if_the_id_is_already_taken_test() ->
    parent:initialize(),
    {ok, Child} = start_child(#{id => child}),
    ?assertMatch({error, {already_started, Child}}, start_child(#{id => child})).

fails_if_the_parent_is_not_initialized_test() ->
    ?assertException(error, "Parent is not initialized", start_child()).

% "shutdown_child/1_test() ->
stops_the_child_synchronously_handling_the_exit_message_test() ->
    parent:initialize(),

    {ok, Child} = parent:start_child(test_child, #{id => child}),

    parent:shutdown_child(child),
    ?assertMatch(false, erlang:is_process_alive(Child)),
    ?assertNotMatch({'EXIT', Child, _Reason}, receive_once(1000)).

forcefully_terminates_the_child_if_shutdown_is_brutal_kill_test() ->
    parent:initialize(),

    {ok, Child} =
        parent:start_child(
            {test_child, [{is_block_terminate, true}, {is_trap_exit, true}]},
            #{id => child, shutdown => brutal_kill}
        ),

    erlang:monitor(process, Child),
    parent:shutdown_child(child),
    ?assertMatch({'DOWN', _Mref, process, Child, killed}, receive_once()).

forcefully_terminates_a_child_if_it_doesnt_stop_in_the_given_time_test() ->
    parent:initialize(),

    {ok, Child} =
        parent:start_child(
            {test_child, [{is_block_terminate, true}, {is_trap_exit, true}]},
            #{id => child, shutdown => 10}
        ),

    erlang:monitor(process, Child),
    parent:shutdown_child(child),
    ?assertMatch({'DOWN', _Mref, process, Child, killed}, receive_once(15000)).

fails_if_an_unknown_child_is_given_test() ->
    parent:initialize(),
    ?assertMatch(error, parent:shutdown_child(child)).

fails_if_the_parent_is_not_initialized2_test() ->
    ?assertException(error, "Parent is not initialized", parent:shutdown_child(1)).

% "shutdown_all/1_test() ->
terminates_all_children_in_the_opposite_startup_order_test() ->
    parent:initialize(),

    Child1 = do_start_child(#{id => child1}),
    erlang:monitor(process, Child1),

    Child2 = do_start_child(#{id => child2}),
    erlang:monitor(process, Child2),

    parent:shutdown_all(),

    ?assertMatch({'DOWN', _Mref, process, Child2, _Reason}, receive_once()),
    ?assertMatch({'DOWN', _Mref, process, Child1, _Reason}, receive_once()).

fails_if_the_parent_is_not_initialized3_test() ->
    ?assertException(error, "Parent is not initialized", parent:shutdown_all()).

% "await_child_termination/1_test() ->
waits_for_the_child_to_stop_test() ->
    parent:initialize(),

    Child = do_start_child(#{id => child, meta => meta}),

    spawn_link(fun() ->
        timer:sleep(50),
        gen_server:stop(Child)
    end),

    ?assertEqual({Child, meta, normal}, parent:await_child_termination(child, 1000)),
    ?assertEqual(false, erlang:is_process_alive(Child)).

returns_timeout_if_the_child_didnt_stop_test() ->
    parent:initialize(),
    Child = do_start_child(#{id => child, meta => meta}),
    ?assertEqual(timeout, parent:await_child_termination(child, 0)),
    ?assert(erlang:is_process_alive(Child)).

raises_if_unknown_child_is_given_test() ->
    parent:initialize(),

    ?assertException(error, "unknown child", parent:await_child_termination(child, 1000)).

fails_if_the_parent_is_not_initialized4_test() ->
    ?assertException(
        error,
        "Parent is not initialized",
        parent:await_child_termination(foo, infinity)
    ).

% "children/0_test() ->
returns_child_processes_test() ->
    parent:initialize(),
    ?assert(parent:children() == []),

    Child1 = do_start_child(#{id => child1, meta => meta1}),
    ?assertMatch([#{id := child1, pid := Child1, meta := meta1}], parent:children()),

    Child2 = do_start_child(#{id => child2, meta => meta2}),
    ?assertMatch([
        #{id := child1, pid := Child1, meta := meta1},
        #{id := child2, pid := Child2, meta := meta2}
    ], parent:children()),

    parent:shutdown_child(child1),
    ?assertMatch([#{id := child2, pid := Child2, meta := meta2}], parent:children()).

fails_if_the_parent_is_not_initialized5_test() ->
    ?assertException(error, "Parent is not initialized", parent:children()).

% "num_children/0_test() ->
returns_the_number_of_child_processes_test() ->
    parent:initialize(),
    ?assert(parent:num_children() == 0),

    do_start_child(#{id => child1}),
    ?assert(parent:num_children() == 1),

    do_start_child(),
    ?assert(parent:num_children() == 2),

    parent:shutdown_child(child1),
    ?assert(parent:num_children() == 1).

fails_if_the_parent_is_not_initialized6_test() ->
    ?assertException(error, "Parent is not initialized", parent:num_children()).

% "child?/0_test() ->
returns_true_for_known_children_false_otherwise_test() ->
    parent:initialize(),

    ?assertEqual(false, parent:is_child(child1)),
    ?assertEqual(false, parent:is_child(child2)),

    do_start_child(#{id => child1}),
    do_start_child(#{id => child2}),

    ?assert(parent:is_child(child1)),
    ?assert(parent:is_child(child2)),

    parent:shutdown_child(child1),
    ?assertEqual(false, parent:is_child(child1)),
    ?assert(parent:is_child(child2)).

fails_if_the_parent_is_not_initialized7_test() ->
    ?assertException(error, "Parent is not initialized", parent:is_child(foo)).

% "child_pid/1_test() ->
returns_the_pid_of_the_given_child_error_otherwise_test() ->
    parent:initialize(),

    Child1 = do_start_child(#{id => child1}),
    Child2 = do_start_child(#{id => child2}),

    ?assert(parent:child_pid(child1) == {ok, Child1}),
    ?assert(parent:child_pid(child2) == {ok, Child2}),
    ?assert(parent:child_pid(unknown_child) == error),

    parent:shutdown_child(child1),
    ?assert(parent:child_pid(child1) == error),
    ?assert(parent:child_pid(child2) == {ok, Child2}).

fails_if_the_parent_is_not_initialized8_test() ->
    ?assertException(error, "Parent is not initialized", parent:child_pid(foo)).

% "child_id/1_test() ->
returns_the_id_of_the_given_child_error_otherwise_test() ->
    parent:initialize(),

    Child1 = do_start_child(#{id => child1}),
    Child2 = do_start_child(#{id => child2}),

    ?assert(parent:child_id(Child1) == {ok, child1}),
    ?assert(parent:child_id(Child2) == {ok, child2}),
    ?assert(parent:child_id(self()) == error),

    parent:shutdown_child(child1),
    ?assert(parent:child_id(Child1) == error),
    ?assert(parent:child_id(Child2) == {ok, child2}).

fails_if_the_parent_is_not_initialized9_test() ->
    ?assertException(error, "Parent is not initialized", parent:child_id(self())).

% "child_meta/1_test() ->
returns_the_meta_of_the_given_child_error_otherwise_test() ->
    parent:initialize(),

    do_start_child(#{id => child1, meta => meta1}),
    do_start_child(#{id => child2, meta => meta2}),

    ?assert(parent:child_meta(child1) == {ok, meta1}),
    ?assert(parent:child_meta(child2) == {ok, meta2}),
    ?assert(parent:child_meta(unknown_child) == error),

    parent:shutdown_child(child1),
    ?assert(parent:child_meta(child1) == error),
    ?assert(parent:child_meta(child2) == {ok, meta2}).

fails_if_the_parent_is_not_initialized10_test() ->
    ?assertException(error, "Parent is not initialized", parent:child_meta(child)).

% "update_child_meta/2_test() ->
updates_meta_of_the_known_child_fails_otherwise_test() ->
    parent:initialize(),

    do_start_child(#{id => child1, meta => 1}),
    do_start_child(#{id => child2, meta => 2}),

    parent:update_child_meta(child2, fun(Count) -> Count + 1 end),

    ?assert(parent:child_meta(child1) == {ok, 1}),
    ?assert(parent:child_meta(child2) == {ok, 3}),

    parent:shutdown_child(child1),
    ?assert(parent:update_child_meta(child1, fun(C) -> C end) == error).

fails_if_the_parent_is_not_initialized11_test() ->
    ?assertException(
        error,
        "Parent is not initialized",
        parent:update_child_meta(child, fun(C) -> C end)
    ).

% "handle_message/1_test() ->
handles_child_termination_test() ->
    parent:initialize(),
    Child = do_start_child(#{id => child, meta => meta}),
    gen_server:stop(Child),
    Message = {'EXIT', Child, _Reason} = receive_once(),
    %assert_receive {'EXIT', Child, _Reason} = message,

    ?assertEqual(
        {'EXIT', Child, child, meta, normal},
        parent:handle_message(Message)
    ),

    ?assert(parent:num_children() == 0),
    ?assert(parent:children() == []),
    ?assert(parent:child_id(Child) == error),
    ?assert(parent:child_pid(child) == error).

handles_child_timeout_by_stopping_the_child_test() ->
    parent:initialize(),
    Child = do_start_child(#{id => child, meta => meta, timeout => 0}),
    Message = {parent, child_timeout, Child} = receive_once(),

    ?assertEqual(
        {'EXIT', Child, child, meta, timeout},
        parent:handle_message(Message)
    ),

    ?assert(parent:num_children() == 0),
    ?assert(parent:children() == []),
    ?assert(parent:child_id(Child) == error),
    ?assert(parent:child_pid(child) == error).

handles_supervisor_calls_test() ->
    parent:initialize(),
    Parent = self(),
    Child = do_start_child(#{id => child}),

    %Task =
    %  Task.async(fun() ->
    [_Pid1, _Pid2] = [
        spawn(Task)
        || Task <- [
               fun() ->
                   ?assertEqual(
                       [{child, Child, worker, [test_child]}],
                       supervisor:which_children(Parent)
                   )
               end,

               fun() ->
                   ?assertEqual(
                       [{specs, 1}, {active, 1}, {supervisors, 0}, {workers, 1}],
                       supervisor:count_children(Parent)
                   )
               end
           ]
    ],

    Message = receive_once(),
    %assert_receive message,
    ?assert(parent:handle_message(Message) == ignore),

    Message2 = receive_once(),
    %assert_receive message,
    ?assert(parent:handle_message(Message2) == ignore).

%Task.

ignores_unknown_messages_test() ->
    parent:initialize(),
    ?assertEqual(undefined, parent:handle_message({'EXIT', self(), normal})),
    ?assertEqual(undefined, parent:handle_message(unknown_message)).

fails_if_the_parent_is_not_initialized12_test() ->
    ?assertException(error, "Parent is not initialized", parent:handle_message(foo)).

start_child() ->
    start_child(#{}).

start_child(Overrides) ->
    ParentSpec = #{
        id => erlang:unique_integer([positive, monotonic]),
        start => {test_child, start_link, []}
    },
    parent:start_child(maps:merge(ParentSpec, Overrides)).

do_start_child() ->
    do_start_child(#{}).

do_start_child(Overrides) ->
    {ok, Pid} = start_child(Overrides),
    Pid.
