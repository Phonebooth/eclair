#!/usr/bin/env escript
%%! -pa .eclair/deps/mini_s3/ebin -pa .eclair/deps/ibrowse/ebin

-mode(compile).

-define(AccessKey, "{{ access_key }}").
-define(SecretKey, "{{ secret_key }}").
-define(Root, "{{ root }}").
-define(Version, "{{ version }}").
-define(Tags, "{{ tags }}").

-record(host_data, {
    hostname,
    cwd_app,
    epmd_names
    }).

-record(app_details, {
        cwd,
        app,
        deps
    }).

main(["bootstrap"|Args]) ->
    bootstrap(Args);
main(Args) ->
    {Props, _Data} = args_to_properties(Args),
    Props2 = ensure_with_doteclair_config(Props),
    Props3 = ensure_with_hardcoded_config(Props2),
    ok = application:start(ibrowse),
    HostData = gather_host_data(),
    Root = proplists:get_value(root, Props3),
    Version = normalize_version_input(proplists:get_value(version, Props3)),
    Tags = proplists:get_value(tags, Props3),
    Config = mini_s3:new(proplists:get_value(access_key, Props3),
            proplists:get_value(secret_key, Props3)),
    Paths = build_paths(Root, Version, Tags, HostData, Config),
    lists:foreach(fun(X) ->
                io:format("Searching path ~p~n", [X]),
                get_path(X, Config)
        end, Paths).

get_path(Path, Config) ->
    {Bucket, Prefix, Contents} = list_path(Path, Config),
    get_files(Bucket, Prefix, Contents, Config).

list_path(Path, Config) ->
    {Bucket, Prefix} = s3split_path(Path),
    Response = mini_s3:list_objects(Bucket, [{prefix, Prefix}], Config),
    Contents = proplists:get_value(contents, Response),
    RealContents = lists:filter(fun(X) ->
                % 3Hub creates dummy files to support empty directories. An
                % annoying hack to get rid of them, but practical for our toolset
                Key = proplists:get_value(key, X),
                nomatch =:= re:run(Key, "\\$folder\\$", [{capture, none}])
        end, Contents),
    {Bucket, Prefix, RealContents}.


s3split_path(Path) ->
    Split = filename:split(Path),
    Bucket = hd(Split),
    Prefix = filename:join(tl(Split)),
    {Bucket, Prefix}.

get_files(_Bucket, _Prefix, [], _Config) ->
    ok;
get_files(Bucket, Prefix, [X|Contents], Config) ->
    Key = proplists:get_value(key, X),
    Obj = mini_s3:get_object(Bucket, Key, [], Config),
    case get_relative_path(Prefix, Key) of
        {ok, RelativePath} ->
            place_file(Obj, RelativePath);
        {error, prefix_mismatch} ->
            io:format("Skipping file due to prefix mismatch: ~s~n", [Key])
    end,
    get_files(Bucket, Prefix, Contents, Config).

place_file(Obj, RelativePath) ->
    Dirs = filename:split(RelativePath),
    ok = make_path(Dirs, ""),
    Bytes = proplists:get_value(content, Obj),
    case file:write_file(RelativePath, Bytes, [exclusive]) of
        ok ->
            io:format("Placed new file ~s successfully~n", [RelativePath]);
        {error, eexist} ->
            handle_file_collision(RelativePath, Bytes)
    end.

handle_file_collision(RelativePath, Bytes) ->
    try try_file_merge(RelativePath, Bytes) of
        Result ->
            io:format("Merged in new data for ~s~n", [RelativePath]),
            Result
        catch _:_ ->
            % Overwrite the file
            io:format("Overwriting file ~p~n", [RelativePath]),
            ok = file:write_file(RelativePath, Bytes, [])
    end.

try_file_merge(RelativePath, Bytes) ->
    % Merge proplists in Bytes with proplists at RelativePath. Clobbers
    % config formatting (output is always ~p
    {ok, [OldProplist]} = file:consult(RelativePath),
    {ok, [NewProplist]} = bytes_consult(Bytes),
    MergedProplist = merge(NewProplist, OldProplist, use_source),
    {ok, Io} = file:open(RelativePath, [write]),
    file:write(Io, io_lib:format("~p.~n", [MergedProplist])),
    file:close(Io).

bytes_consult(Bytes) ->
    % I could not find a way to consult bytes, so we use a temp file
    {A,B,C} = now(),
    N = node(),
    TempFile = "/tmp/" ++ lists:flatten(io_lib:format("~p-~p.~p.~p",[N,A,B,C])),
    file:write_file(TempFile, Bytes),
    {ok, Consult} = file:consult(TempFile),
    file:delete(TempFile),
    {ok, Consult}.

make_path([_], _) ->
    ok;
make_path([Dir|Dirs], Path) ->
    DirPath = case Path of "" -> Dir; _ -> filename:join([Path, Dir]) end,
    file:make_dir(DirPath),
    make_path(Dirs, DirPath).

get_relative_path(Prefix, Key) ->
    case re:run(Key, Prefix ++ "/(?<cap>.*)", [{capture, [cap], list}]) of
        {match, [RelativePath]} ->
            {ok, RelativePath};
        nomatch ->
            {error, prefix_mismatch}
    end.

gather_host_data() ->
    EpmdModule = net_kernel:epmd_module(),
    {ok, Host} = inet:gethostname(),
    {ok, CwdApp} = get_cwd_app(),
    {ok, Names} = EpmdModule:names(),
    #host_data{
        hostname=Host,
        cwd_app=CwdApp,
        epmd_names=Names
    }.

build_paths(Root, Version, Tags, #host_data{hostname=Hostname,
        cwd_app=#app_details{app=App},
        epmd_names=EpmdNames}, Config) ->
    % Paths are searched in this order:
    %      1. root path
    %      2. tags
    %      3. epmd nodes
    %      4. hostname
    AppName = case lists:keyfind(application, 1, App) of
        false ->
            undefined;
        Tuple ->
            element(2, Tuple)
    end,
    NewRoot = case find_closest_version(Version, Root, App, AppName, Config) of
        {error, none} ->
            filename:join([Root, AppName]);
        {ok, Vsn} ->
            filename:join([Root, AppName, "version", Vsn])
    end,
    SplitTags = ["root"] ++ 
                split_tags(Tags) ++ 
                [ "epmd/" ++ X || {X,_} <- EpmdNames ] ++
                ["host/"++Hostname],
    lists:map(fun(X) ->
                filename:join([NewRoot, X])
        end, SplitTags).

find_closest_version(none, _, _, _, _) ->
    {error, none};
find_closest_version(auto, Root, App, AppName, Config) ->
    {_, _, Details} = lists:keyfind(application, 1, App),
    AutoVsn = proplists:get_value(vsn, Details),
    find_closest_version(AutoVsn, Root, App, AppName, Config);
find_closest_version(Vsn, Root, _App, AppName, Config) ->
    io:format("Looking for version root ~p~n", [Vsn]),
    S3Versions = get_versions(Root, AppName, Config),
    closest_version_match(Vsn, S3Versions).

closest_version_match(Vsn, VsnList) ->
    case lists:member(Vsn, VsnList) of
        true ->
            {ok, Vsn};
        false ->
            case extract_numbered_version(Vsn) of
                {ok, InputVsn} ->
                    LongVsns = lists:filtermap(fun(X) ->
                                case extract_numbered_version(X) of
                                    {ok, NV} ->
                                        {true, {version_to_long(NV), X}};
                                    {error, no_numbering} ->
                                        false
                                end
                        end, VsnList),
                    LongVsns2 = lists:sort(LongVsns),
                    {ok, search_versions(version_to_long(InputVsn), LongVsns2, undefined)};
                {error, no_numbering} ->
                    {error, version_mismatch}
            end
    end.

search_versions(_In, [], Previous) ->
    Previous;
search_versions(In, [{H, OrigVsn}|T], Previous) ->
    if
        In < H ->
            Previous;
        true ->
            search_versions(In, T, OrigVsn)
    end.

extract_numbered_version(Vsn) ->
    case re:run(Vsn, "(?<n>[0-9]+)(\\.|$)", [global, {capture, [n], list}]) of
        {match, SplitNums} ->
            {ok, [ list_to_integer(X) || [X] <- SplitNums ]};
        nomatch ->
            {error, no_numbering}
    end.

version_to_long([Major]) -> version_to_long([Major, 0]);
version_to_long([Major, Minor]) -> version_to_long([Major, Minor, 0]);
version_to_long([Major, Minor, Bugfix]) -> version_to_long([Major, Minor, Bugfix, 0]);
version_to_long([Major, Minor, Bugfix, Build]) when is_integer(Major) andalso
                                                    is_integer(Minor) andalso
                                                    is_integer(Bugfix) andalso
                                                    is_integer(Build) ->
    Major bsl (3*16) +
    Minor bsl (2*16) +
    Bugfix bsl (1*16) +
    Build.

get_versions(Root, AppName, Config) ->
    {Bucket, Prefix} = s3split_path(filename:join([Root, AppName, "version"])),
    Response = mini_s3:list_objects(Bucket, [{prefix, Prefix++"/"},{delimiter, "/"}], Config),
    S3Versions = lists:foldl(fun(X, A) ->
                case proplists:get_value(prefix, X) of
                    undefined ->
                        A;
                    VsnPrefix ->
                        case re:run(VsnPrefix, "version/(?<vsn>[^/]*)", [{capture, ['vsn'], list}]) of
                            {match, [V]} ->
                                [V|A];
                            nomatch ->
                                A
                        end
                end
        end, [], proplists:get_value(common_prefixes, Response)),
    lists:reverse(S3Versions).

split_tags(Tags) ->
    string:tokens(Tags, ",").

get_cwd_app() ->
    {ok, Cwd} = file:get_cwd(),
    App = case filelib:wildcard(Cwd ++ "/ebin/*.app") of
        [] ->
            undefined;
        [AppFile] ->
            {ok, PL} = file:consult(AppFile),
            PL;
        _ ->
            undefined
    end,
    Deps = case file:list_dir(Cwd ++ "/deps") of
        {error, enoent} ->
            [];
        {ok, Ls} ->
            Ls
    end,
    {ok, #app_details{
        cwd=Cwd,
        app=App,
        deps=Deps
    }}.

args_to_properties(Args) ->
    args_to_properties(Args, none, [], []).

args_to_properties([], none, Proplist, Data) ->
    {lists:reverse(Proplist), lists:reverse(Data)};
args_to_properties([], {value, Key}, Proplist, Data) ->
    args_to_properties([], none, [{Key, true}|Proplist], Data);
args_to_properties(["-"++Key|Args], none, Proplist, Data) ->
    args_to_properties(Args, {value, list_to_atom(Key)}, Proplist, Data);
args_to_properties([Value|Args], none, Proplist, Data) ->
    args_to_properties(Args, none, Proplist, [Value|Data]);
args_to_properties(["-"++Key2|Args], {value, Key1}, Proplist, Data) ->
    args_to_properties(Args, {value, Key2}, [{Key1, true}|Proplist], Data);
args_to_properties([Value|Args], {value, Key}, Proplist, Data) ->
    args_to_properties(Args, none, [{Key, Value}|Proplist], Data).

bootstrap(Args) ->
    file:make_dir(".eclair"),
    {Props, _Data} = args_to_properties(Args),
    Props2 = ensure_with_doteclair_config(Props),
    AccessKey = getline_arg(access_key, Props2),
    SecretKey = getline_arg(secret_key, Props2),
    Root = getline_arg(root, Props2),
    Version = normalize_version_input(getline_arg(version, Props2)),
    Tags = getline_arg(tags, Props2),
    write_doteclair([{access_key, AccessKey},
                    {secret_key, SecretKey},
                    {root, Root},
                    {version, Version},
                    {tags, Tags}]).

normalize_version_input("") -> none;
normalize_version_input("none") -> none;
normalize_version_input("auto") -> auto;
normalize_version_input(V) -> V.

s3cfg(Key) when Key =:= "access_key" orelse Key =:= "secret_key" ->
    os:cmd("awk -F= '/'"++Key++"'/ {print $2}' ~/.s3cfg | tr -d ' \\n'");
s3cfg(_) -> [].

prompt(version) -> "version (none|auto|x.y.z)> ";
prompt(Key) -> atom_to_list(Key) ++ "> ".

getline_arg(Key, Props) ->
    case proplists:get_value(Key, Props) of
        undefined ->
            case s3cfg(atom_to_list(Key)) of
                [] ->
                    case proplists:get_value(quiet, Props) of
                        true ->
                            io:format("Missing data and quiet flag given. Exiting with failure~n", []),
                            halt(1);
                        _ ->
                            string:strip(io:get_line(prompt(Key)), right, $\n)
                    end;
                V0 ->
                    io:format("Found ~p in .s3cfg.~n", [Key]),
                    V0
            end;
        V1 ->
            io:format("Found ~p in eclair input.~n", [Key]),
            V1
    end.

ensure_with_doteclair_config(Props) ->
    case file:consult(".eclair/secure.config") of
        {error, enoent} ->
            Props;
        {ok, [Access]} ->
            ensure_proplist(Access, Props)
    end.

ensure_with_hardcoded_config(Props) ->
    ensure_proplist([{access_key, ?AccessKey},
                    {secret_key, ?SecretKey},
                    {root, ?Root},
                    {version, ?Version},
                    {tags, ?Tags}], Props).

ensure_proplist(From, To) ->
    Props2 = lists:foldl(fun({X, Y}, A) ->
                case lists:keyfind(X, 1, A) of
                    false ->
                        [{X, Y}|A];
                    _ ->
                        A
                end
        end, To, From),
    lists:reverse(Props2).

write_doteclair(Props) ->
    Bytes = io_lib:format("~p.~n", [Props]),
    file:write_file(".eclair/secure.config", Bytes).

merge(Src, Dest, MismatchPolicy) ->
    DestPaths = xpaths(Dest),
    SrcPaths = xpaths(Src),
    DestKeyset = sets:from_list(element(1, lists:unzip(DestPaths))),
    SrcKeyset = sets:from_list(element(1, lists:unzip(SrcPaths))),
    AddsKeyset = sets:subtract(SrcKeyset, DestKeyset),
    UpdatesKeyset = sets:intersection(SrcKeyset, DestKeyset),

    % Find xpaths in the source that would clobber depth in the dest.
    % We will either (A) ignore these paths such that depth is always preferred
    % or (B) delete any paths in the dest that begin with the shallow paths,
    % thus prefering the source data.
    AllKeyset = sets:union(SrcKeyset, DestKeyset),
    AllKeylist = sets:to_list(AllKeyset),
    Stems = [ lists:sublist(X, 1, length(X)-1) || X <- AllKeylist ],
    Leaves = [ lists:last(X) || X <- AllKeylist ],
    ShallowLeaves = lists:filter(fun(X) ->
                lists:any(fun(Z) -> Z end, [ lists:member(X, Y) || Y <- Stems ])
        end, Leaves),
    ShallowPaths = lists:filter(fun(X) ->
                lists:member(lists:last(X), ShallowLeaves)
        end, AllKeylist),

    {AddsKeyset2, UpdatesKeyset2, DestPaths2} = 
        case MismatchPolicy of
            favor_depth ->
                IgnoreSrcKeyset = sets:from_list(ShallowPaths),
                AK2 = sets:subtract(AddsKeyset, IgnoreSrcKeyset),
                UK2 = sets:subtract(UpdatesKeyset, IgnoreSrcKeyset),
                {AK2, UK2, DestPaths};
            use_source ->
                DP2 = lists:filter(fun({X, _}) ->
                            not lists:any(fun(Y) ->
                                        lists:sublist(X, 1, length(Y)) =:= Y
                                end, ShallowPaths)
                    end, DestPaths),
                {AddsKeyset, UpdatesKeyset, DP2}
        end,

    AddsKeylist = sets:to_list(AddsKeyset2),
    UpdatesKeylist = sets:to_list(UpdatesKeyset2),

    AddsPaths = [ {X, proplists:get_value(X, SrcPaths)} || X <- AddsKeylist ],
    UpdatesPaths = [ {X, proplists:get_value(X, SrcPaths)} || X <- UpdatesKeylist ],

    if
        length(AddsPaths) > 0 ->
            io:format("[adds]~n", []),
            lists:foreach(fun(X) ->
                        io:format("    n ~p~n", [X])
                end, AddsPaths);
        true ->
            ok
    end,

    if
        length(UpdatesPaths) > 0 ->
            io:format("[updates]~n", []);
        true ->
            ok
    end,

    Merged = lists:sort(
        lists:foldl(fun(U = {KU, _VU}, Acc) ->
                    io:format("    - ~p~n", [proplists:lookup(KU, Acc)]),
                    io:format("    + ~p~n~n", [U]),
                proplists:delete(KU, Acc) ++ [U]
        end, DestPaths2, UpdatesPaths) ++ AddsPaths
    ),
    from_xpaths(Merged).

xpaths(A) ->
    RevResult = depthfold(fun(Keys, Val, Accum) ->
                [{Keys, Val}|Accum]
        end, [], A),
    lists:reverse(RevResult).

depthfold(Fun, Accum, A) ->
    {_, Result} = depthfold_(Fun, A, {[], Accum}),
    Result.

depthfold_(_Fun, [], {Keys, Accum}) ->
    {Keys, Accum};
depthfold_(Fun, [{Key, Value}|A], {Keys, Accum}) ->
    {_Keys2, Accum2} = depthfold_(Fun, Value, {[Key|Keys], Accum}),
    depthfold_(Fun, A, {Keys, Accum2});
depthfold_(Fun, Value, {Keys, Accum}) ->
    {Keys, Fun(lists:reverse(Keys), Value, Accum)}.

from_xpaths(XPaths) ->
    lists:foldl(fun ensure_proplist_keypath/2, [], XPaths).

ensure_proplist_keypath({[Key|KeyPath], Value}, Proplist) ->
    case proplists:lookup(Key, Proplist) of
        none ->
            case KeyPath of
                [] ->
                    lists:sort([{Key, Value}|Proplist]);
                _ ->
                    Sub = ensure_proplist_keypath({KeyPath, Value}, []),
                    lists:sort([{Key, Sub}|Proplist])
            end;
        {_, Sub} ->
            Sub2 = ensure_proplist_keypath({KeyPath, Value}, Sub),
            lists:sort([{Key, Sub2}|proplists:delete(Key, Proplist)])
    end.

%test_merge() ->
%    Src = [{a, [
%                {aa, "srcaa"}
%            ]},
%           {b,
%               [
%                   {ba,
%                       [
%                           {baa, "srcbaa"}
%                       ]
%                   }
%               ]
%           },
%           {c, "c"}],
%      Dest = [{a, 
%                [
%                    {aa, [
%                            {aaa, "aaa"}
%                        ]}, 
%                    {ab,"ab"}
%                ]
%            },
%          {b,
%              [
%                  {ba, [
%                          {baa, "baa"},
%                          {bab, "bab"}
%                      ]
%                  },
%                  {bb, "bb"},
%                  {bc, [
%                          {bca, [
%                                  {bcaa, "bcaa"}
%                              ]
%                          }
%                      ]
%                  }
%              ]
%          },
%          {d, 1}
%        ],
%        [{use_source, merge(Src, Dest, use_source)},
%            {favor_depth, merge(Src, Dest, favor_depth)}].
