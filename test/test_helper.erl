-module(test_helper).

-include("test.hrl").

-export([
    receive_loop/0,
    receive_loop/1,
    receive_once/0,
    receive_once/1,
    child_spec/2
]).

receive_loop() ->
    receive_loop(?timeout).

receive_loop(Timeout) ->
    receive_once(Timeout),
    receive_loop(Timeout).

receive_once() ->
    receive_once(?timeout).

receive_once(Timeout) ->
    receive
        Msg ->
            Msg
    after Timeout -> timeout
    end.

%child_spec({Module, Args}, Opts) ->
%    maps:merge(Module:child_spec(Args),Opts).

child_spec(ModuleOrMap, Overrides) ->
    maps:fold(
        fun
            (K, V, Acc) when
                K == id; K == start; K == restart; K == shutdown; K == type; K == modules
            ->
                Acc#{K => V};
            (K, _V, _Acc) ->
                error(
                    io_lib:format(
                        "unknown key ~s in child specification override",
                        [K]
                    )
                )
        end,
        init_child(ModuleOrMap),
        Overrides
    ).

init_child(Module) when is_atom(Module) ->
    init_child({Module, []});
init_child({Module, Args}) when is_atom(Module) ->
    Module:child_spec(Args);
init_child(Map) when is_map(Map) ->
    Map.
