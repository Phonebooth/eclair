#!/usr/bin/env escript
%%! -pa .eclair/deps/mini_s3/ebin -pa .eclair/deps/ibrowse/ebin

-mode(compile).

-define(AccessKey, "{{ access_key }}").
-define(SecretKey, "{{ secret_key }}").
-define(Root, "{{ root }}").

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
    Props2 = merge_doteclair_config(Props),
    Props3 = merge_hardcoded_config(Props2),
    ok = application:start(ibrowse),
    HostData = gather_host_data(),
    Path = build_path(proplists:get_value(root, Props3), HostData),
    Config = mini_s3:new(proplists:get_value(access_key, Props3),
            proplists:get_value(secret_key, Props3)),
    {Bucket, Prefix, Contents} = list_path(Path, Config),
    get_files(Bucket, Prefix, Contents, Config).

list_path(Path, Config) ->
    Split = filename:split(Path),
    Bucket = hd(Split),
    Prefix = filename:join(tl(Split)),
    Response = mini_s3:list_objects(Bucket, [{prefix, Prefix}], Config),
    Contents = proplists:get_value(contents, Response),
    RealContents = lists:filter(fun(X) ->
                % 3Hub creates dummy files to support empty directories. An
                % annoying hack to get rid of them, but practical for our toolset
                Key = proplists:get_value(key, X),
                nomatch =:= re:run(Key, "\\$folder\\$", [{capture, none}])
        end, Contents),
    {Bucket, Prefix, RealContents}.

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
            io:format("File collision detected for ~s~n", [RelativePath]),
            handle_file_collision(RelativePath, Bytes)
    end.

handle_file_collision(RelativePath, Bytes) ->
    % Merge proplists in Bytes with proplists at RelativePath
    {ok, OldProplists} = file:consult(RelativePath),
    {ok, NewProplists} = bytes_consult(Bytes),
    % TODO - merge proplists by building all xpaths first
    ok.

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

build_path(Root, #host_data{hostname=Hostname, cwd_app=#app_details{app=App}}) ->
    AppName = case lists:keyfind(application, 1, App) of
        false ->
            undefined;
        Tuple ->
            element(2, Tuple)
    end,
    filename:join([Root, Hostname, AppName]).

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
    Props2 = merge_doteclair_config(Props),
    AccessKey = getline_arg(access_key, Props2),
    SecretKey = getline_arg(secret_key, Props2),
    Root = getline_arg(root, Props2),
    write_doteclair([{access_key, AccessKey},
                    {secret_key, SecretKey},
                    {root, Root}]).

s3cfg(Key) when Key =:= "access_key" orelse Key =:= "secret_key" ->
    os:cmd("awk -F= '/'"++Key++"'/ {print $2}' ~/.s3cfg | tr -d ' \\n'");
s3cfg(_) -> [].

getline_arg(Key, Props) ->
    case proplists:get_value(Key, Props) of
        undefined ->
            case s3cfg(atom_to_list(Key)) of
                [] ->
                    string:strip(io:get_line(atom_to_list(Key)++"> "), right, $\n);
                V0 ->
                    io:format("Found ~p in .s3cfg.~n", [Key]),
                    V0
            end;
        V1 ->
            io:format("Found ~p in eclair input.~n", [Key]),
            V1
    end.

merge_doteclair_config(Props) ->
    case file:consult(".eclair/secure.config") of
        {error, enoent} ->
            Props;
        {ok, [Access]} ->
            merge_proplist(Access, Props)
    end.

merge_hardcoded_config(Props) ->
    merge_proplist([{access_key, ?AccessKey},
                    {secret_key, ?SecretKey},
                    {root, ?Root}], Props).

merge_proplist(From, To) ->
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
