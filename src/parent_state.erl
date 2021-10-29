-module(parent_state).

-type t() :: #{
    id_to_pid := #{parent:child_id() => pid()},
    children := #{pid() => child()},
    startup_index := non_neg_integer()
}.

-type child() :: #{
    spec := parent:child_spec(),

    meta := parent:child_meta(),
    pid := pid(),
    timer_ref := reference() | undefined,
    startup_index := non_neg_integer()
}.

-export_type([child/0]).

-export([
    initialize/0,
    register_child/4,
    children/1,
    pop/2,
    num_children/1,
    child/2,
    child_id/2,
    child_pid/2,
    child_meta/2,
    update_child_meta/3
]).

-spec initialize() -> t().
initialize() -> #{id_to_pid => #{}, children => #{}, startup_index => 0}.

-spec register_child(t(), pid() | undefined, parent:child_spec(), timer:tref() | undefined) -> t().
register_child(State, Pid,  #{id := ChildId} = ChildSpec, TimerRef) ->
    #{id_to_pid := IdsToPids, children := Children, startup_index := I} = State,
    
    false = maps:is_key(Pid, Children),
    false = maps:is_key(ChildId, IdsToPids),

    Child = #{
        spec => ChildSpec,
        meta => maps:get(meta, ChildSpec),
        pid => Pid,
        timer_ref => TimerRef,
        startup_index => I
    },

    State#{
        id_to_pid := IdsToPids#{ChildId => Pid},
        children := Children#{Pid => Child},
        startup_index := I + 1
    }.

-spec children(t()) -> [child()].
children(#{children := Children}) -> maps:values(Children).

-spec pop(t(), parent:child_ref()) -> {ok, child(), t()} | error.
pop(State, ChildRef) ->
    case child(State, ChildRef) of
        {ok, #{spec := #{id := Id}, pid := Pid} = Child} ->
            {ok, Child, State#{
                id_to_pid := maps:remove(Id, maps:get(id_to_pid, State)),
                children := maps:remove(Pid, maps:get(children, State))
            }};
        error -> error
    end.

-spec num_children(t()) -> non_neg_integer().
num_children(#{children := Children}) -> maps:size(Children).

-spec child(t(), parent:child_ref()) -> {ok, child()} | error.
child(_State, undefined) -> error;
child(#{children := Children}, Pid) when is_pid(Pid) ->
    maps:find(Pid, Children);
child(#{id_to_pid := IdsToPids} = State, Id) ->
    case maps:find(Id, IdsToPids) of
        {ok, Pid} -> child(State, Pid);
        error -> error
    end.

-spec child_id(t(), pid()) -> {ok, parent:child_id()} | error.
child_id(#{children := Children}, Pid) ->
    case maps:find(Pid, Children) of
        {ok, #{spec := #{id := ChildId}}} ->
            {ok, ChildId};
        error ->
            error
    end.

-spec child_pid(t(), parent:child_id()) -> {ok, pid()} | error.
child_pid(#{id_to_pid := IdsToPids}, Id) ->
    maps:find(Id, IdsToPids).

-spec child_meta(t(), parent:child_ref()) -> {ok, parent:child_meta()} | error.
child_meta(State, ChildRef) ->
    case child(State, ChildRef) of
        {ok, #{meta := Meta}} -> {ok, Meta};
        error -> error
    end.

-spec update_child_meta(t(), parent:child_ref(),
        fun((parent:child_meta()) -> parent:child_meta())
    ) -> {ok, t()} | error.
update_child_meta(State, ChildRef, UpdaterFun) ->
    case child(State, ChildRef) of
        {ok, #{pid := Pid} = Child} ->
            UpdatedChild = maps:update_with(meta, UpdaterFun, Child),
            UState = maps:update_with(children,
                fun(Children) -> Children#{Pid := UpdatedChild} end, State),
            {ok, UState};
        error -> error
    end.
