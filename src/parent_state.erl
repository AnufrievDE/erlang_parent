-module(parent_state).

-opaque t() :: #{
    id_to_pid := #{parent:child_id() => pid()},
    children := #{pid => child()},
    startup_index := non_neg_integer()
}.

-type child() :: #{
    id := parent:child_id(),
    pid := pid(),
    shutdown := parent:shutdown(),
    meta := parent:child_meta(),
    type := worker | supervisor,
    modules := [module] | dynamic,
    timer_ref := reference() | undefined,
    startup_index := non_neg_integer()
}.

-export([
    initialize/0,
    register_child/4,
    children/1,
    pop/2,
    num_children/1,
    child_id/2,
    child_pid/2,
    child_meta/2,
    update_child_meta/3
]).

-spec initialize() -> t().
initialize() -> #{id_to_pid => #{}, children => #{}, startup_index => 0}.

-spec register_child(t(), pid(), parent:child_spec(), reference() | undefined) -> t().
register_child(State, Pid, #{id := ChildId} = FullChildSpec, TimerRef) ->
    #{id_to_pid := IdsToPids, children := Children, startup_index := I} = State,
    Child = #{
        id => ChildId,
        pid => Pid,
        shutdown => maps:get(shutdown, FullChildSpec),
        meta => maps:get(meta, FullChildSpec),
        type => maps:get(type, FullChildSpec),
        modules => maps:get(modules, FullChildSpec),
        timer_ref => TimerRef,
        startup_index => I
    },

    false = maps:is_key(Pid, Children),
    false = maps:is_key(ChildId, IdsToPids),

    State#{
        id_to_pid => IdsToPids#{ChildId => Pid},
        children => Children#{Pid => Child},
        startup_index => I + 1
    }.

-spec children(t()) -> [child()].
children(#{children := Children}) -> maps:values(Children).

-spec pop(t(), pid()) -> {ok, child(), t()} | error.
pop(#{children := Children, id_to_pid := IdsToPids} = State, Pid) ->
    case maps:find(Pid, Children) of
        {ok, #{id := ChildId} = Child} ->
            {ok, Child, State#{
                id_to_pid => maps:remove(ChildId, IdsToPids),
                children => maps:remove(Pid, Children)
            }};
        error ->
            error
    end.

-spec num_children(t()) -> non_neg_integer().
num_children(#{children := Children}) -> maps:size(Children).

-spec child_id(t(), pid()) -> {ok, parent:child_id()} | error.
child_id(#{children := Children}, Pid) ->
    case maps:find(Pid, Children) of
        {ok, #{id := ChildId}} ->
            {ok, ChildId};
        error ->
            error
    end.

-spec child_pid(t(), parent:child_id()) -> {ok, pid()} | error.
child_pid(#{id_to_pid := IdsToPids}, Id) ->
    maps:find(Id, IdsToPids).

-spec child_meta(t(), parent:child_id()) -> {ok, parent:child_meta()} | error.
child_meta(#{children := Children} = State, Id) ->
    case child_pid(State, Id) of
        {ok, Pid} ->
            case maps:find(Pid, Children) of
                {ok, #{meta := Meta} = _Child} -> {ok, Meta};
                error -> error
            end;
        error ->
            error
    end.

-spec update_child_meta(
    t(),
    parent:child_id(),
    fun((parent:child_meta()) -> parent:child_meta())
) -> {ok, t()} | error.
update_child_meta(#{children := Children} = State, Id, UpdaterFun) ->
    case child_pid(State, Id) of
        %update(State, Pid, &update_in(&1.meta, updater));
        {ok, Pid} ->
            case maps:find(Pid, Children) of
                {ok, Child} ->
                    UpdatedChild = maps:update_with(meta, UpdaterFun, Child),
                    UpdatedChildren = Children#{Pid => UpdatedChild},
                    {ok, State#{children => UpdatedChildren}};
                error ->
                    error
            end;
        error ->
            error
    end.
