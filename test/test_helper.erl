-module(test_helper).

-include("test.hrl").

-export([receive_loop/0, receive_loop/1,
    receive_once/0, receive_once/1
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