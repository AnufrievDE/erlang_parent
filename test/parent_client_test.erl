-module(parent_client_test).

%-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

returns_the_pid_of_the_given_child_test() ->
    Parent = start_parent(
        [child_spec(#{id => child1}), child_spec(#{id => child2})]
        %,registry?: unquote(registry?)
    ),

    {ok, Pid1} = parent_client:child_pid(Parent, child1),
    {ok, Pid2} = parent_client:child_pid(Parent, child2),

    ?assertMatch([{child1, Pid1, _, _}, {child2, Pid2, _, _}],
        supervisor:which_children(Parent)).

can_dereference_aliases_test() ->
    RegisteredName = list_to_atom(io_lib:format(
        "alias_~b", [erlang:unique_integer([positive, monotonic])])),
    Parent = start_parent({local, RegisteredName}, [child_spec(#{id => child})]),
    global:register_name(RegisteredName, Parent),

    ?assertMatch({ok, _}, parent_client:child_pid(RegisteredName, child)),
    ?assertMatch({ok, _}, parent_client:child_pid({global, RegisteredName}, child)),
    ?assertMatch({ok, _}, parent_client:child_pid({via, global, RegisteredName}, child)).

child_pid_returns_error_when_child_is_unknown_test() ->
    Parent = start_parent([]), %, registry?: unquote(registry?))
    ?assert(parent_client:child_pid(Parent, child) =:= error).

returns_error_if_child_is_stopped_test() ->
    Parent = start_parent(
        [child_spec(#{id => child1}), child_spec(#{id => child2})]
          %,registry?: unquote(registry?)
    ),

    parent_client:shutdown_child(Parent, child1),

      ?assert(parent_client:child_pid(Parent, child1) =:= error),
      ?assertMatch({ok, _}, parent_client:child_pid(Parent, child2)).

returns_children_test() ->
    Parent = start_parent([
        child_spec(#{id => child1, meta => meta1}),
        child_spec(#{id => child2, meta => meta2})
    ]), %], registry?: unquote(registry?)),

    {ok, Child1Pid} = parent_client:child_pid(Parent, child1),
    {ok, Child2Pid} = parent_client:child_pid(Parent, child2),

    ?assertMatch(
        [
            #{id := child1, meta := meta1, pid := Child1Pid},
            #{id := child2, meta := meta2, pid := Child2Pid}
        ], 
        lists:sort(fun(#{id := Id1}, #{id := Id2}) -> Id1 =< Id2 end,
            parent_client:children(Parent))
        %Enum.sort_by(parent_client:children(Parent), &"#{&1.id}") =:= [
    ).

resolves_the_pid_of_the_given_child_test() ->
    Parent = start_parent(
        [child_spec(#{id => child1}), child_spec(#{id => child2})]
            %,registry?: unquote(registry?)
    ),

    Pid1 = gen_server_parent:whereis({via, parent_client, {Parent, child1}}),
    Pid2 = gen_server_parent:whereis({via, parent_client, {Parent, child2}}),

    ?assertMatch([{child1, Pid1, _, _}, {child2, Pid2, _, _}],
        supervisor:which_children(Parent)).

returns_nil_when_child_is_unknown_test() ->
    Parent = start_parent([]), %, registry?: unquote(registry?)),
    ?assertMatch(undefined,
        gen_server_parent:whereis({via, parent_client, {Parent, child}})).

returns_the_meta_of_the_given_child_test() ->
    Parent = start_parent([
            child_spec(#{id => child1, meta => meta1}),
            child_spec(#{meta => meta2})
        ]), %,registry?: unquote(registry?) ),

    Child1Pid = child_pid(Parent, child1),
    Child2Pid = maps:get(pid, hd(
        lists:filter(fun(#{pid := Pid}) -> Pid =/= Child1Pid end,
            parent_client:children(Parent)))),

    ?assert(parent_client:child_meta(Parent, child1) =:= {ok, meta1}),
    ?assert(parent_client:child_meta(Parent, Child1Pid) =:= {ok, meta1}),
    ?assert(parent_client:child_meta(Parent, Child2Pid) =:= {ok, meta2}).

child_meta_returns_error_when_child_is_unknown_test() ->
    Parent = start_parent(),
    ?assert(parent_client:child_meta(Parent, child) =:= error).

succeeds_if_child_exists_test() ->
    Parent = start_parent([child_spec(#{id => child, meta => 1})]),
    UpdateRes = parent_client:update_child_meta(
        Parent, child, fun(Meta) -> Meta + 1 end),
    ?assertMatch(ok, UpdateRes),
    ?assertMatch({ok, 2}, parent_client:child_meta(Parent, child)).

update_child_meta_returns_error_when_child_is_unknown_test() ->
    Parent = start_parent(),
    UpdateRes = parent_client:update_child_meta(Parent, child, fun(A) -> A end),
    ?assertMatch(error, UpdateRes).

adds_the_additional_child_test() ->
    Parent = start_parent([child_spec(#{id => child1})]),
    {ok, Child2Pid} = parent_client:start_child(Parent, child_spec(#{id => child2})),
    ?assertMatch(Child2Pid, child_pid(Parent, child2)).

returns_error_test() ->
    Parent = start_parent([child_spec(#{id => child1})]),
    {ok, Child2Pid} = parent_client:start_child(Parent, child_spec(#{id => child2})),

    ?assertMatch({error, {already_started, Child2Pid}},
        parent_client:start_child(Parent, child_spec(#{id => child2}))),

    ?assertMatch([child1, child2], child_ids(Parent)),
    ?assertMatch(Child2Pid, child_pid(Parent, child2)).

handles_child_start_crash_test() ->
    Parent = start_parent([child_spec(#{id => child1})]),

    spawn(
        fun() ->
            Spec = child_spec(#{id => child2, start =>
                {test_server, start_link, [fun() -> error("some error") end]}}),

            {error, {_Error, _Stacktrace}} =
                parent_client:start_child(Parent, Spec),
            timer:sleep(100)
        end),

    ?assertMatch([child1], child_ids(Parent)).

stops_the_given_child_with_shutdown_test() ->
    Parent = start_parent([child_spec(#{id => child})]),
    %?assertMatch({ok, _Info}, parent_client:shutdown_child(Parent, child)),
    ?assertMatch(ok, parent_client:shutdown_child(Parent, child)),
    ?assertMatch(error, parent_client:child_pid(Parent, child)),
    ?assertMatch([], child_ids(Parent)).

shutdown_child_returns_error_when_child_is_unknown_test() ->
    Parent = start_parent(),
    ?assertMatch(error, parent_client:shutdown_child(Parent, child)).

%stops_the_given_child_with_restart_test() ->
%    Parent = start_parent([child_spec(#{id => child})]),
%    Pid1 = child_pid(Parent, child),
%    ?assertMatch(ok, parent_client:restart_child(Parent, child)),
%    ?assertMatch([child], child_ids(Parent)),
%    ?assert(child_pid(Parent, child) =/= Pid1).
%
%restart_child_returns_error_when_child_is_unknown_test() ->
%    Parent = start_parent(),
%    ?assertMatch(error, parent_client:restart_child(Parent, child)).

stops_all_children_test() ->
    Parent = start_parent([
        child_spec(#{id => child1}), child_spec(#{id => child2})]),
    %?assert(maps:keys(parent_client:shutdown_all(Parent)) =:= [child1, child2]),
    ?assertMatch(ok, parent_client:shutdown_all(Parent)),
    ?assert(child_ids(Parent) =:= []).

%returns_all_given_children_test() ->
%    Parent =
%        start_parent([
%            child_spec(#{id => child1, shutdown_group => group1}),
%            child_spec(#{id => child2, binds_to => [child1], shutdown_group => group2}),
%            child_spec(#{id => child3, binds_to => [child2]}),
%            child_spec(#{id => child4, shutdown_group => group1}),
%            child_spec(#{id => child5, shutdown_group => group2}),
%            child_spec(#{id => child6})
%        ]),
%
%    {ok, StoppedChildren} = parent_client:shutdown_child(Parent, child4),
%
%    ?assert(child_ids(Parent) =:= [child6]),
%    ?assert(parent_client:return_children(Parent, StoppedChildren) =:= ok),
%    ?assert(child_ids(Parent) =:=
%        [child1, child2, child3, child4, child5, child6]).

start_parent() -> start_parent([]).
%start_parent(Children) -> start_parent(Children, []).
%start_parent(Children, Opts) ->
start_parent(Children) ->
    {ok, Parent} = test_server:start_link(
        fun() -> parent:start_all_children(Children) end),
    %Parent = start_supervised!({parent:Supervisor, {Children, Opts}}),
    %Mox.allow(parent:RestartCounter.TimeProvider.Test, self(), Parent)
    Parent.
start_parent(ServerName, Children) ->
    {ok, Parent} = test_server:start_link(ServerName,
        fun() -> parent:start_all_children(Children) end),
    Parent.

child_spec(Overrides) ->
    parent:child_spec(#{
        start => {test_server, start_link, [fun() -> ok end]}}, Overrides).

child_pid(Parent, ChildId) ->
  {ok, Pid} = parent_client:child_pid(Parent, ChildId),
  Pid.

child_ids(Parent) ->
    lists:map(fun(#{id := Id}) -> Id end, parent_client:children(Parent)).