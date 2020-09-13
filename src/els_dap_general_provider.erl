%%==============================================================================
%% @doc Erlang DAP General Provider
%%
%% Implements the logic for hanlding all of the commands in the protocol.
%%
%% The functionality in this module will eventually be broken into several
%% different providers.
%% @end
%%==============================================================================
-module(els_dap_general_provider).

-behaviour(els_provider).
-export([ handle_request/2
        , handle_info/2
        , is_enabled/0
        , init/0
        ]).

-export([ capabilities/0
        ]).

%%==============================================================================
%% Types
%%==============================================================================

%% Protocol
-type capabilities() :: #{}.
-type request()      :: {Command :: binary(), Params :: map()}.
-type result()       :: #{}.

%% Internal
-type frame_id()     :: pos_integer().
-type frame()        :: #{ module    := module()
                         , function  := atom()
                         , arguments := [any()]
                         , source    := binary()
                         , line      := integer()
                         , bindings  := any()}.
-type thread()       :: #{ pid := pid()
                         , frames := #{frame_id() => frame()}
                         }.
-type thread_id()    :: integer().
-type state()        :: #{ threads => #{thread_id() => thread()}
                         , project_node => atom()
                         }.

%%==============================================================================
%% els_provider functions
%%==============================================================================

-spec is_enabled() -> boolean().
is_enabled() -> true.

-spec init() -> state().
init() ->
  #{threads => #{}}.

-spec handle_request(request(), state()) -> {result(), state()}.
handle_request({<<"initialize">>, _Params}, State) ->
  {capabilities(), State};
handle_request({<<"launch">>, Params}, State) ->
  #{<<"cwd">> := Cwd} = Params,
  ok = file:set_cwd(Cwd),

  ProjectNode = node_name("dap_project_", Cwd),
  spawn(fun() -> els_utils:cmd("rebar3", ["shell", "--name", ProjectNode]) end),

  LocalNode = node_name("dap_", Cwd),
  els_distribution_server:start_distribution(LocalNode),

  els_distribution_server:wait_connect_and_monitor(ProjectNode, 5),

  els_dap_server:send_event(<<"initialized">>, #{}),

  {#{}, State#{project_node => ProjectNode}};
handle_request( {<<"configurationDone">>, _Params}
              , #{project_node := ProjectNode} = State
              ) ->
  inject_dap_agent(ProjectNode),
  %% TODO: Fetch stack_trace mode from Launch Config
  rpc:call(ProjectNode, int, stack_trace, [all]),
  Args = [[break], {els_dap_agent, int_cb, [self()]}],
  rpc:call(ProjectNode, int, auto_attach, Args),
  %% TODO: Potentially fetch this from the Launch config
  rpc:cast(ProjectNode, daptoy_fact, fact, [5]),
  {#{}, State};
handle_request( {<<"setBreakpoints">>, Params}
              , #{project_node := ProjectNode} = State
              ) ->
  #{<<"source">> := #{<<"path">> := Path}} = Params,
  SourceBreakpoints = maps:get(<<"breakpoints">>, Params, []),
  _SourceModified = maps:get(<<"sourceModified">>, Params, false),
  Module = els_uri:module(els_uri:uri(Path)),
  %% TODO: Keep a list of interpreted modules, not to re-interpret them
  rpc:call(ProjectNode, int, i, [Module]),
  [rpc:call(ProjectNode, int, break, [Module, Line]) ||
    #{<<"line">> := Line} <- SourceBreakpoints],
  Breakpoints = [#{<<"verified">> => true, <<"line">> => Line} ||
                  #{<<"line">> := Line} <- SourceBreakpoints],
  {#{<<"breakpoints">> => Breakpoints}, State};
handle_request({<<"setExceptionBreakpoints">>, _Params}, State) ->
  {#{}, State};
handle_request({<<"threads">>, _Params}, #{threads := Threads0} = State) ->
  Threads =
    [ #{ <<"id">> => Id
       , <<"name">> => els_utils:to_binary(io_lib:format("~p", [Pid]))
       } || {Id, #{pid := Pid} = _Thread} <- maps:to_list(Threads0)
    ],
  {#{<<"threads">> => Threads}, State};
handle_request({<<"stackTrace">>, Params}, #{threads := Threads} = State) ->
  #{<<"threadId">> := ThreadId} = Params,
  Thread = maps:get(ThreadId, Threads),
  Frames = maps:get(frames, Thread),
  StackFrames =
    [ #{ <<"id">> => Id
       , <<"name">> => format_mfa(M, F, length(A))
       , <<"source">> => #{<<"path">> => Source}
       , <<"line">> => Line
       , <<"column">> => 0
       }
      || { Id
         , #{ module := M
            , function := F
            , arguments := A
            , line := Line
            , source := Source
            }
         } <- maps:to_list(Frames)
    ],
  {#{<<"stackFrames">> => StackFrames}, State};
handle_request({<<"scopes">>, Params}, State) ->
  #{<<"frameId">> := _FrameId} = Params,
  {#{<<"scopes">> => []}, State};
handle_request( {<<"next">>, Params}
              , #{ threads := Threads
                 , project_node := ProjectNode
                 } = State
              ) ->
  #{<<"threadId">> := ThreadId} = Params,
  Pid = to_pid(ThreadId, Threads),
  ok = rpc:call(ProjectNode, int, next, [Pid]),
  {#{}, State};
handle_request( {<<"continue">>, Params}
              , #{ threads := Threads
                 , project_node := ProjectNode
                 } = State
              ) ->
  #{<<"threadId">> := ThreadId} = Params,
  Pid = to_pid(ThreadId, Threads),
  ok = rpc:call(ProjectNode, int, continue, [Pid]),
  {#{}, State};
handle_request( {<<"stepIn">>, Params}
              , #{ threads := Threads
                 , project_node := ProjectNode
                 } = State
              ) ->
  #{<<"threadId">> := ThreadId} = Params,
  Pid = to_pid(ThreadId, Threads),
  ok = rpc:call(ProjectNode, int, step, [Pid]),
  {#{}, State};
handle_request({<<"evaluate">>, #{ <<"context">> := <<"hover">>
                                 , <<"frameId">> := FrameId
                                 , <<"expression">> := Expr
                                 } = _Params}, #{threads := Threads} = State) ->
  Frame = frame_by_id(FrameId, maps:values(Threads)),
  Bindings = maps:get(bindings, Frame),
  {ok, Tokens, _} = erl_scan:string(unicode:characters_to_list(Expr) ++ "."),
  {ok, Exprs} = erl_parse:parse_exprs(Tokens),
  %% TODO: Evaluate the expressions on the project node
  {value, Value, _NewBindings} = erl_eval:exprs(Exprs, Bindings),
  Result = unicode:characters_to_binary(io_lib:format("~p", [Value])),
  {#{<<"result">> => Result}, State};
handle_request({<<"variables">>, _Params}, State) ->
  %% TODO: Return variables
  {#{<<"variables">> => []}, State}.

-spec handle_info(any(), state()) -> state().
handle_info( {int_cb, ThreadPid}
           , #{ threads := Threads
              , project_node := ProjectNode
              } = State
           ) ->
  lager:debug("Int CB called. thread=~p", [ThreadPid]),
  ThreadId = id(ThreadPid),
  Thread = #{ pid    => ThreadPid
            , frames => stack_frames(ThreadPid, ProjectNode)
            },
  els_dap_server:send_event(<<"stopped">>, #{ <<"reason">> => <<"breakpoint">>
                                            , <<"threadId">> => ThreadId
                                            }),
  State#{threads => maps:put(ThreadId, Thread, Threads)}.

%%==============================================================================
%% API
%%==============================================================================

-spec capabilities() -> capabilities().
capabilities() ->
  #{}.

%%==============================================================================
%% Internal Functions
%%==============================================================================
-spec inject_dap_agent(atom()) -> ok.
inject_dap_agent(Node) ->
  Module = els_dap_agent,
  {Module, Bin, File} = code:get_object_code(Module),
  {_Replies, _} = rpc:call(Node, code, load_binary, [Module, File, Bin]),
  ok.

-spec node_name(string(), binary()) -> atom().
node_name(Prefix, Binary) ->
  <<SHA:160/integer>> = crypto:hash(sha, Binary),
  Id = lists:flatten(io_lib:format("~40.16.0b", [SHA])),
  {ok, Hostname} = inet:gethostname(),
  list_to_atom(Prefix ++ Id ++ "@" ++ Hostname).

-spec id(pid()) -> integer().
id(Pid) ->
  erlang:phash2(Pid).

-spec stack_frames(pid(), atom()) -> #{frame_id() => frame()}.
stack_frames(Pid, ProjectNode) ->
  %% TODO: Abstract RPC into a function
  {ok, Meta} =
    rpc:call(ProjectNode, dbg_iserver, safe_call, [{get_meta, Pid}]),
  %% TODO: Also examine rest of list
  [{_Level, {M, F, A}}|_] =
    rpc:call(ProjectNode, int, meta, [Meta, backtrace, all]),
  Bindings = rpc:call(ProjectNode, int, meta, [Meta, bindings, nostack]),
  StackFrameId = erlang:unique_integer([positive]),
  StackFrame = #{ module    => M
                , function  => F
                , arguments => A
                , source    => source(M, ProjectNode)
                , line      => break_line(Pid, ProjectNode)
                , bindings  => Bindings
                },
  #{StackFrameId => StackFrame}.

-spec break_line(pid(), atom()) -> integer().
break_line(Pid, ProjectNode) ->
  Snapshots = rpc:call(ProjectNode, int, snapshot, []),
  {Pid, _Function, break, {_Module, Line}} = lists:keyfind(Pid, 1, Snapshots),
  Line.

-spec source(atom(), atom()) -> binary().
source(M, ProjectNode) ->
  CompileOpts = rpc:call(ProjectNode, M, module_info, [compile]),
  Source = proplists:get_value(source, CompileOpts),
  unicode:characters_to_binary(Source).

-spec to_pid(pos_integer(), #{thread_id() => thread()}) -> pid().
to_pid(ThreadId, Threads) ->
  Thread = maps:get(ThreadId, Threads),
  maps:get(pid, Thread).

-spec frame_by_id(frame_id(), [thread()]) -> frame().
frame_by_id(FrameId, Threads) ->
  [Frame] = [ maps:get(FrameId, Frames)
              ||  #{frames := Frames} <- Threads, maps:is_key(FrameId, Frames)
            ],
  Frame.

-spec format_mfa(module(), atom(), integer()) -> binary().
format_mfa(M, F, A) ->
  els_utils:to_binary(io_lib:format("~p:~p/~p", [M, F, A])).
