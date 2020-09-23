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

-type start() :: fun(() -> supervisor:startchild_ret()) | {module(), atom(), [term()]}.

-type shutdown() :: non_neg_integer() | infinity | brutal_kill.

-type start_spec() :: child_spec() | module() | {module(), term()}.

-type child() :: {child_id(), pid(), child_meta()}.

-type handle_message_response() ::
    {'EXIT', pid(), child_id(), child_meta(), Reason :: term()} | ignore.

-export_type([child_spec/0]).