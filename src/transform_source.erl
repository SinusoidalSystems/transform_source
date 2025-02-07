-module(transform_source).

-export([
    init/1,
    do/1
]).

-define(PROVIDER, transform_source).

%% Need compile here if we were to run edoc alone
%%    to have the parse transform available
%% if we run ex_doc then compile not needed, since it already compiles
-define(DEPS, [{default, lock}]).

-define(DEFAULT_DIR, "doc_src").

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    State1 = rebar_state:add_provider(
        State,
        providers:create([
            {name, ?PROVIDER},
            {module, ?MODULE},
            {bare, true},
            {deps, ?DEPS},
            {example, "transform_source"},
            {short_desc, "Applying parse transform to generate source code"},
            {desc, "Generate source code in file after applying a specified parse transform"},
            {opts, [
                {app, $a, "app", string, "Specific application in umbrella project"},
                {parse_transform, $t, "parse_transform", atom, "parse transformation to use"},
                {output, $o, "output", {string, ?DEFAULT_DIR}, "Directory to store generated source code"}
            ]},
            {profiles, [docs]}  %% This is why we generate the source
        ])
    ),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()} | {error, {module(), any()}}.
do(State) ->
   case os:getenv("OVERWRITE_SRC") of
     false -> rebar_api:abort("Set OS env OVERWRITE_SRC if you really want ~p", [?PROVIDER]);
     _ -> ok
   end,
   {Opts, _Args} = rebar_state:command_parsed_args(State),
   TransOpts = rebar_state:get(State, ?MODULE, []),
   Apps = get_apps(State),
   AppOpts =
     case [ {app, rebar_utils:to_binary(AppName)} || {apps, AppNames} <- TransOpts, AppName <- AppNames ] of
       [] ->
         %% None specified, perform on all by detection
         [{app, rebar_app_info:name(App)} || App <- Apps];
       SelectedApps ->
         SelectedApps
     end,
   cp_apps_src(State, Apps, AppOpts ++ TransOpts ++ Opts).

-spec cp_apps_src(rebar_state:t(), rebar_app_info:t(), rebar:rebar_dict()) -> {ok, rebar_state:t()} | {error, string()} | {error, {module(), any()}}.
cp_apps_src(State, [], _TransOpts) ->
  {ok, State};
cp_apps_src(State, [App|Apps], TransOpts) ->
  case lists:member({app, rebar_app_info:name(App)}, TransOpts) of
    false ->
      rebar_api:info("Running ~p for ~p: no transformed code", [?PROVIDER, rebar_app_info:name(App)]),
      cp_apps_src(State, Apps, TransOpts);
    true ->
      OutDir = rebar_app_info:out_dir(App),
      DestDir = filename:join(OutDir, proplists:get_value(output, TransOpts, ?DEFAULT_DIR)),
      case cp_app_src(App, DestDir, TransOpts) of
        no_change ->
          rebar_api:info("Running ~p for ~p: no transformed code", [?PROVIDER, rebar_app_info:name(App)]),
          cp_apps_src(State, Apps, TransOpts);
        {change, Changes} ->
          rebar_api:info("Running ~p for ~p", [?PROVIDER, rebar_app_info:name(App)]),
          [ begin
              rebar_api:info("Overwriting ~p", [Dest]),
              ok = file:write_file(Dest, Data)
            end || {Dest, Data} <- Changes ],
          cp_apps_src(State, Apps, TransOpts);
        Error -> Error
      end
  end.

%% The original idea was to copy all code to different directory
%% hence a bit more code then needed now that we overwrite
cp_app_src(App, _DestDir, Opts) ->
   Context = rebar_compiler_erl:context(App),
   AppDir = rebar_app_info:dir(App),
   SrcDirs = [ filename:join(AppDir, SrcDir) || SrcDir <- maps:get(src_dirs, Context) ],
   Files =
     lists:foldl(fun(SrcDir, Fs) ->
                     {ok, NewFs} = file:list_dir(SrcDir),
                     Fs ++ [filename:join(SrcDir, F) || F <- NewFs]
                 end, [], SrcDirs),
   rebar_api:debug("Analysing files ~p", [Files]),
   {Change, Errors} =
     lists:foldl(fun(File, {C, Es}) ->
                     try transformed(File, Context, Opts) of
                       {true, NewSrc} ->
                         {[{File, NewSrc}|C], Es};
                       false ->
                         {C, Es}
                     catch _:_ ->
                        {C, Es ++ [{error, io_lib:format("file handling error ~s", [File])}]}
                     end
                 end, {[], []}, Files),
   case {Change, Errors} of
     {[], []} -> no_change;
     {_, []}  -> {change, Change};
     {_, [_|_]} ->
       %% fail with the first error found
       hd(Errors)
   end.

transformed(File, Context, Opts) ->
  PT = proplists:get_value(parse_transform, Opts),
  {ok, Forms} = epp:parse_file(File, [{includes, maps:get(include_dirs, Context)}]),
  case parse_transform_present(Forms, PT) of
    false -> false;
    true ->
      NewForms = PT:parse_transform(Forms, []),
      NewSrc = io_lib:format("~s", [erl_prettypr:format(erl_syntax:form_list(NewForms))]),
      {true, NewSrc}
  end.

parse_transform_present(Forms, PT) ->
  Attrs = proplists:get_value(attributes,  erl_syntax_lib:analyze_forms(Forms), []),
  CompileAttrs = lists:foldl(fun({compile, Opts}, Os) when is_list(Opts) -> Opts ++ Os;
                                ({compile, Opt}, Os) -> [Opt|Os];
                                (_, Os) -> Os
                             end, [], Attrs),
  rebar_api:debug("compiler attributes ~p (looking for ~p)", [CompileAttrs, PT]),
  lists:member({parse_transform, PT}, CompileAttrs).

-spec get_apps(rebar_state:t()) -> [rebar_app_info:t()].
get_apps(State) ->
  case rebar_state:current_app(State) of
    undefined ->
      rebar_state:project_apps(State);
    AppInfo ->
      [AppInfo]
  end.

