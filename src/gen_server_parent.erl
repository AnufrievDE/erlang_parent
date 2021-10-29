-module(gen_server_parent).

-behavior(gen_server).

-export([
    start_link/2,
    start_link/3,
    start_link/4,
    init/1,
    handle_info/2,
    handle_call/3,
    handle_cast/2,
    format_status/2,
    code_change/3,
    terminate/2,
    handle_continue/2,
    child_spec/1,
    whereis/1
]).

%%%-------------------------------------------------------------------
%% @doc A gen_server extension which simplifies parenting of child processes.
%% This behaviour helps implementing a gen_server which also needs to directly
%% start child processes and handle their termination.
%%
%% ## Starting the process
%%
%% The usage is similar to gen_server. You need to use the module and start the
%% process:
%%
%% ```
%% -module(my_parent_process).
%% -behavior(gen_server_parent).
%%
%% start_link(Arg) ->
%%     ...
%%     gen_server_parent:start_link(ServerName, ?MODULE, Arg, Options).
%% ```
%%
%% The expression `-behavior(gen_server_parent)` will also inject `-behavior(gen_server)` into
%% your code. Your parent process is a gen_server, and this behaviour doesn't try
%% to hide it. Except when starting the process, you work with the parent exactly
%% as you work with any gen_server, using the same functions, and writing the same
%% callbacks:
%%
%% ```
%% -module(my_parent_process).
%% -behavior(gen_server_parent).
%%
%% do_something(Pid, Arg) -> gen_server:call(Pid, {do_something, Arg}).
%% ...
%%
%% @impl gen_server
%% init(Arg) -> {ok, initial_state(Arg)}.
%%
%% @impl gen_server
%% handle_call({do_something, Arg}, _From, State) ->
%%     {reply, response(State, Arg), next_state(State, Arg)}.
%% ```
%%
%% Compared to plain gen_server, there are following differences:
%%
%% - A gen_server_parent traps exits by default.
%% %- The generated `child_spec/1` has the `:shutdown` configured to `:infinity`.
%% %- The generated `child_spec/1` specifies the `:type` configured to `:supervisor`
%%
%% ## Starting child processes
%%
%% To start a child process, you can invoke `parent:start_child/1` in the parent process:
%%
%% ```
%% handle_call(...) ->
%%     parent:start_child(ChildSpec)
%%     ...
%% ```
%%
%% The function takes a child spec map which is similar to supervisor child
%% specs. The map has the following keys:
%%
%%     - `id` (required) - a term uniquely identifying the child
%%     - `start` (required) - an MFA, or a zero arity lambda invoked to start the child
%%     - `meta` (optional) - a term associated with the started child, defaults to `undefined`
%%     - `shutdown` (optional) - same as with `supervisor`, defaults to 5000
%%     - `timeout` (optional) - timeout after which the child is killed by the parent,
%%       see the timeout section below, defaults to `infinity`
%%
%% The function described with `start` needs to start a linked process and return
%% the result as `{ok, Pid}`. For example:
%%
%% ```
%% parent:start_child(#{
%%     id => hello_world,
%%     start => {Module, start_link, [fun() -> io:format("Hello, World!~n") end]}
%% })
%% ```
%%
%% You can also pass a zero-arity lambda for `start`:
%%
%% ```
%% parent:start_child(#{
%%     id => hello_world,
%%     start => fun() -> Module:start_link(fun() -> io:format("Hello, World!~n") end) end
%% })
%% ```
%%
%% Finally, a child spec can also be a module, or a `{Module, Arg}` function.
%% This works similarly to supervisor specs, invoking `Module:child_spec/1`
%% is which must provide the final child specification.
%%
%% ## Handling child termination
%%
%% When a child process terminates, `handle_child_terminated/5` will be invoked.
%% The default implementation is injected into the module, but you can of course
%% override it:
%%
%%  ```
%% @impl gen_server_parent
%% handle_child_terminated(Id, ChildMeta, Pid, Reason, State) ->
%%     ...
%%     {noreply, State}
%% ```
%%
%% The return value of `handle_child_terminated` is the same as for `handle_info`.
%%
%% ## Timeout
%%
%% If a positive integer is provided via the `timeout` option, the parent will
%% terminate the child if it doesn't stop within the given time. In this case,
%% `handle_child_terminated/5` will be invoked with the exit reason `timeout`.
%%
%% ## Working with child processes
%%
%% The `parent` module provides various functions for managing child processes.
%% For example, you can enumerate running children with `parent:children/0`,
%% fetch child meta with `parent:child_meta/1`, or terminate a child process with
%% `parent:shutdown_child/1`.
%%
%% ## Termination
%%
%% The behaviour takes down the child processes during termination, to ensure that
%% no child process is running after the parent has terminated. The children are
%% terminated synchronously, one by one, in the reverse start order.
%%
%% The termination of the children is done after the `terminate/1` callback returns.
%% Therefore in `terminate/1` the child processes are still running, and you can
%% interact with them.
%%
%% ## Supervisor compliance
%%
%% A process powered by `parent:gen_server` can handle supervisor specific
%% messages, which means that for all intents and purposes, such process is
%% treated as a supervisor. As a result, children of parent will be included in
%% the hot code reload process.
%% @end
%%%-------------------------------------------------------------------

-type state() :: term().

%% @doc "Invoked when a child has terminated."
-callback handle_child_terminated(
    parent:child_id(),
    parent:child_meta(),
    pid(),
    Reason :: term(),
    state()
) ->
    {noreply, NewState} |
    {noreply, NewState, timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState}
when
    NewState :: state().

-callback child_spec(term()) -> supervisor:child_spec().

%-optional_callbacks([child_spec/1, handle_child_terminated/5]).
%-optional_callbacks([handle_info/2, handle_continue/2, terminate/2,
%    code_change/3, format_status/2]).

%% @doc "Starts the parent process."
-spec start_link(Module :: module(), Arg :: term(), gen:options()) -> gen:start_ret().
start_link(Module, Arg) ->
    start_link(Module, Arg, []).

start_link(Module, Arg, Options) ->
    gen_server:start_link(?MODULE, {Module, Arg}, Options).

start_link(ServerName, Module, Arg, Options) ->
    gen_server:start_link(ServerName, ?MODULE, {Module, Arg}, Options).

init({Callback, Arg}) ->
    % needed to simulate a supervisor
    put('$initial_call', {supervisor, Callback, 1}),

    put({?MODULE, callback}, Callback),
    parent:initialize(),
    invoke_callback(init, [Arg]).

% @impl gen_server
handle_info(Message, State) ->
    case parent:handle_message(Message) of
        {'EXIT', Pid, Id, Meta, Reason} ->
            invoke_callback(
                handle_child_terminated, [Id, Meta, Pid, Reason, State]);
        ignore ->
            {noreply, State};
        undefined ->
            invoke_callback(handle_info, [Message, State])
    end.

% @impl gen_server
handle_call(which_children, _From, State) ->
    {reply, parent:supervisor_which_children(), State};
handle_call(count_children, _From, State) ->
    {reply, parent:supervisor_count_children(), State};
handle_call({get_childspec, ChildIdOrPid}, _From, State) ->
    {reply, parent:supervisor_get_childspec(ChildIdOrPid), State};
handle_call(Message, From, State) ->
    invoke_callback(handle_call, [Message, From, State]).

% @impl gen_server
handle_cast(Message, State) -> invoke_callback(handle_cast, [Message, State]).

% @impl gen_server
%% Needed to support `supervisor:get_callback_module`
format_status(normal, [_PDict, State]) ->
    [
        {data, [{"State", State}]},
        %{supervisor, [{'Callback', supervisor:get_callback_module(self())}]},
        {supervisor, [{"Callback", get({?MODULE, callback})}]}
    ];
format_status(terminate, RDictAndState) ->
    invoke_callback(format_status, [terminate, RDictAndState]).

% @impl gen_server
code_change(OldVsn, State, Extra) ->
    invoke_callback(code_change, [OldVsn, State, Extra]).

% @impl gen_server
terminate(Reason, State) ->
    try
        invoke_callback(terminate, [Reason, State])
    after
        parent:shutdown_all(Reason)
    end.

-ifdef(OTP_RELEASE).
-if(?OTP_RELEASE >= 21).
% @impl gen_server
handle_continue(Continue, State) ->
    invoke_callback(handle_continue, [Continue, State]).
-endif.
-endif.

invoke_callback(Func, Args) ->
    apply(get({?MODULE, callback}), Func, Args).

%invoke_callback(Func, Args) ->
%    invoke_callback(Func, Args, false).
%invoke_callback(Func, Args, false) ->
%    apply(get({?MODULE, callback}), Func, Args);
%invoke_callback(Func, Args, true) ->
%    Module = get({?MODULE, callback}),
%    case erlang:function_exported(Module, Func, length(Args)) of
%        true -> apply(Module, Func, Args);
%        false -> apply(?MODULE, Func, Args)
%    end.

%% @doc false
child_spec(_Arg) ->
    error(io_lib:format("~s can't be used in a child spec.", [?MODULE])).

%% @doc false
whereis(Pid) when is_pid(Pid) ->
    Pid;
whereis(Name) when is_atom(Name) ->
    erlang:whereis(Name);
whereis({global, Name}) ->
    global:whereis_name(Name);
whereis({via, Mod, Name}) ->
    apply(Mod, whereis_name, [Name]);
whereis({Name, Local}) when is_atom(Name) andalso Local =:= node() ->
    erlang:whereis(Name);
whereis({Name, Node} = ServerRef) when is_atom(Name) andalso is_atom(Node) ->
    ServerRef.

% @doc false
% defmacro __using__(opts) do
%   quote location: :keep, bind_quoted: [opts: opts, behaviour: ?MODULE] do
%     use gen_server, opts
%     @behaviour behaviour
%
%     @doc """
%     Returns a specification to start this module under a supervisor.
%     See `Supervisor`.
%     """
%    child_spec(Arg) do
%      Default = #{
%        id => ?MODULE,
%        start => {?MODULE, start_link, [Arg]},
%        shutdown => infinity,
%        type => supervisor
%      }
%
%      supervisor:child_spec(Default, unquote(Macro.escape(opts)))
%    end

% @impl behaviour
% handle_child_terminated(_Id, _Meta, _Pid, _Reason, State) -> {noreply, State}.
%     defoverridable handle_child_terminated: 5, child_spec: 1
%   end
% end
%end