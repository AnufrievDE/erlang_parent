-type child_spec() :: #{
    id := child_id(),
    start := start(),
    modules => [module()] | dynamic,
    type => worker | supervisor,
    meta => child_meta(),
    shutdown => shutdown(),
    timeout => pos_integer() | infinity
}.

-type child_id() :: term().
-type child_meta() :: term().

-type child_ref() :: child_id() | pid().

-type start() :: fun(() -> supervisor:startchild_ret()) | {module(), atom(), [term()]}.

-type shutdown() :: non_neg_integer() | infinity | brutal_kill.

-type start_spec() :: child_spec() | module() | {module(), term()}.

-type child() :: #{id := child_id(), pid := pid() | undefined, meta := child_meta()}.

-type handle_message_response() ::
    {'EXIT', pid(), child_id(), child_meta(), Reason :: term()} | ignore.