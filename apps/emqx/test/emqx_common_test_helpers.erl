%%--------------------------------------------------------------------
%% Copyright (c) 2019-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_common_test_helpers).

-type special_config_handler() :: fun().

-type apps() :: list(atom()).

-export([
    all/1,
    boot_modules/1,
    start_apps/1,
    start_apps/2,
    stop_apps/1,
    reload/2,
    app_path/2,
    proj_root/0,
    deps_path/2,
    flush/0,
    flush/1,
    render_and_load_app_config/1
]).

-export([
    client_ssl/0,
    client_ssl/1,
    client_ssl_twoway/0,
    client_ssl_twoway/1,
    ensure_mnesia_stopped/0,
    ensure_quic_listener/2,
    is_all_tcp_servers_available/1,
    is_tcp_server_available/2,
    is_tcp_server_available/3,
    load_config/2,
    load_config/3,
    not_wait_mqtt_payload/1,
    read_schema_configs/2,
    render_config_file/2,
    wait_for/4,
    wait_mqtt_payload/1
]).

-export([
    emqx_cluster/1,
    emqx_cluster/2,
    start_epmd/0,
    start_slave/2,
    stop_slave/1
]).

-export([clear_screen/0]).
-export([with_mock/4]).
-export([
    on_exit/1,
    call_janitor/0
]).

%% Toxiproxy API
-export([
    with_failure/5,
    reset_proxy/2
]).

-define(CERTS_PATH(CertName), filename:join(["etc", "certs", CertName])).

-define(MQTT_SSL_CLIENT_CERTS, [
    {keyfile, ?CERTS_PATH("client-key.pem")},
    {cacertfile, ?CERTS_PATH("cacert.pem")},
    {certfile, ?CERTS_PATH("client-cert.pem")}
]).

-define(TLS_1_3_CIPHERS, [
    {versions, ['tlsv1.3']},
    {ciphers, [
        "TLS_AES_256_GCM_SHA384",
        "TLS_AES_128_GCM_SHA256",
        "TLS_CHACHA20_POLY1305_SHA256",
        "TLS_AES_128_CCM_SHA256",
        "TLS_AES_128_CCM_8_SHA256"
    ]}
]).

-define(TLS_OLD_CIPHERS, [
    {versions, ['tlsv1.1', 'tlsv1.2']},
    {ciphers, [
        "ECDHE-ECDSA-AES256-GCM-SHA384",
        "ECDHE-RSA-AES256-GCM-SHA384",
        "ECDHE-ECDSA-AES256-SHA384",
        "ECDHE-RSA-AES256-SHA384",
        "ECDHE-ECDSA-DES-CBC3-SHA",
        "ECDH-ECDSA-AES256-GCM-SHA384",
        "ECDH-RSA-AES256-GCM-SHA384",
        "ECDH-ECDSA-AES256-SHA384",
        "ECDH-RSA-AES256-SHA384",
        "DHE-DSS-AES256-GCM-SHA384",
        "DHE-DSS-AES256-SHA256",
        "AES256-GCM-SHA384",
        "AES256-SHA256",
        "ECDHE-ECDSA-AES128-GCM-SHA256",
        "ECDHE-RSA-AES128-GCM-SHA256",
        "ECDHE-ECDSA-AES128-SHA256",
        "ECDHE-RSA-AES128-SHA256",
        "ECDH-ECDSA-AES128-GCM-SHA256",
        "ECDH-RSA-AES128-GCM-SHA256",
        "ECDH-ECDSA-AES128-SHA256",
        "ECDH-RSA-AES128-SHA256",
        "DHE-DSS-AES128-GCM-SHA256",
        "DHE-DSS-AES128-SHA256",
        "AES128-GCM-SHA256",
        "AES128-SHA256",
        "ECDHE-ECDSA-AES256-SHA",
        "ECDHE-RSA-AES256-SHA",
        "DHE-DSS-AES256-SHA",
        "ECDH-ECDSA-AES256-SHA",
        "ECDH-RSA-AES256-SHA",
        "AES256-SHA",
        "ECDHE-ECDSA-AES128-SHA",
        "ECDHE-RSA-AES128-SHA",
        "DHE-DSS-AES128-SHA",
        "ECDH-ECDSA-AES128-SHA",
        "ECDH-RSA-AES128-SHA",
        "AES128-SHA"
    ]}
]).

-define(DEFAULT_TCP_SERVER_CHECK_AVAIL_TIMEOUT, 1000).

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

all(Suite) ->
    lists:usort([
        F
     || {F, 1} <- Suite:module_info(exports),
        string:substr(atom_to_list(F), 1, 2) == "t_"
    ]).

%% set emqx app boot modules
-spec boot_modules(all | list(atom())) -> ok.
boot_modules(Mods) ->
    application:set_env(emqx, boot_modules, Mods).

-spec start_apps(Apps :: apps()) -> ok.
start_apps(Apps) ->
    %% to avoid keeping the `db_hostname' that is set when loading
    %% `system_monitor' application in `emqx_machine', and then it
    %% crashing when trying to connect.
    %% FIXME: add an `enable' option to sysmon_top and use that to
    %% decide whether to start it or not.
    DefaultHandler =
        fun(_) ->
            application:set_env(system_monitor, db_hostname, ""),
            ok
        end,
    start_apps(Apps, DefaultHandler).

-spec start_apps(Apps :: apps(), Handler :: special_config_handler()) -> ok.
start_apps(Apps, SpecAppConfig) when is_function(SpecAppConfig) ->
    %% Load all application code to beam vm first
    %% Because, minirest, ekka etc.. application will scan these modules
    lists:foreach(fun load/1, [emqx | Apps]),
    ok = start_ekka(),
    mnesia:clear_table(emqx_admin),
    ok = emqx_ratelimiter_SUITE:load_conf(),
    lists:foreach(fun(App) -> start_app(App, SpecAppConfig) end, [emqx | Apps]).

load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, _}} -> ok;
        {error, Reason} -> error({failed_to_load_app, App, Reason})
    end.

render_and_load_app_config(App) ->
    load(App),
    Schema = app_schema(App),
    Conf = app_path(App, filename:join(["etc", app_conf_file(App)])),
    try
        do_render_app_config(App, Schema, Conf)
    catch
        throw:E:St ->
            %% turn throw into error
            error({Conf, E, St})
    end.

do_render_app_config(App, Schema, ConfigFile) ->
    Vars = mustache_vars(App),
    RenderedConfigFile = render_config_file(ConfigFile, Vars),
    read_schema_configs(Schema, RenderedConfigFile),
    force_set_config_file_paths(App, [RenderedConfigFile]),
    copy_certs(App, RenderedConfigFile),
    ok.

start_app(App, SpecAppConfig) ->
    render_and_load_app_config(App),
    SpecAppConfig(App),
    case application:ensure_all_started(App) of
        {ok, _} ->
            ok = ensure_dashboard_listeners_started(App),
            ok;
        {error, Reason} ->
            error({failed_to_start_app, App, Reason})
    end.

app_conf_file(emqx_conf) -> "emqx.conf.all";
app_conf_file(App) -> atom_to_list(App) ++ ".conf".

app_schema(App) ->
    Mod = list_to_atom(atom_to_list(App) ++ "_schema"),
    try
        true = is_list(Mod:roots()),
        Mod
    catch
        error:undef ->
            no_schema
    end.

mustache_vars(App) ->
    [
        {platform_data_dir, app_path(App, "data")},
        {platform_etc_dir, app_path(App, "etc")},
        {platform_log_dir, app_path(App, "log")}
    ].

render_config_file(ConfigFile, Vars0) ->
    Temp =
        case file:read_file(ConfigFile) of
            {ok, T} -> T;
            {error, Reason} -> error({failed_to_read_config_template, ConfigFile, Reason})
        end,
    Vars = [{atom_to_list(N), iolist_to_binary(V)} || {N, V} <- Vars0],
    Targ = bbmustache:render(Temp, Vars),
    NewName = ConfigFile ++ ".rendered",
    ok = file:write_file(NewName, Targ),
    NewName.

read_schema_configs(no_schema, _ConfigFile) ->
    ok;
read_schema_configs(Schema, ConfigFile) ->
    NewConfig = generate_config(Schema, ConfigFile),
    lists:foreach(
        fun({App, Configs}) ->
            [application:set_env(App, Par, Value) || {Par, Value} <- Configs]
        end,
        NewConfig
    ).

generate_config(SchemaModule, ConfigFile) when is_atom(SchemaModule) ->
    {ok, Conf0} = hocon:load(ConfigFile, #{format => richmap}),
    hocon_tconf:generate(SchemaModule, Conf0).

-spec stop_apps(list()) -> ok.
stop_apps(Apps) ->
    [application:stop(App) || App <- Apps ++ [emqx, ekka, mria, mnesia]],
    ok.

proj_root() ->
    filename:join(
        lists:takewhile(
            fun(X) -> iolist_to_binary(X) =/= <<"_build">> end,
            filename:split(app_path(emqx, "."))
        )
    ).

%% backward compatible
deps_path(App, RelativePath) -> app_path(App, RelativePath).

app_path(App, RelativePath) ->
    Lib = code:lib_dir(App),
    safe_relative_path(filename:join([Lib, RelativePath])).

safe_relative_path(Path) ->
    case filename:split(Path) of
        ["/" | T] ->
            T1 = do_safe_relative_path(filename:join(T)),
            filename:join(["/", T1]);
        _ ->
            do_safe_relative_path(Path)
    end.

do_safe_relative_path(Path) ->
    case safe_relative_path_2(Path) of
        unsafe -> Path;
        OK -> OK
    end.

-if(?OTP_RELEASE < 23).
safe_relative_path_2(Path) ->
    filename:safe_relative_path(Path).
-else.
safe_relative_path_2(Path) ->
    {ok, Cwd} = file:get_cwd(),
    filelib:safe_relative_path(Path, Cwd).
-endif.

-spec reload(App :: atom(), SpecAppConfig :: special_config_handler()) -> ok.
reload(App, SpecAppConfigHandler) ->
    application:stop(App),
    start_app(App, SpecAppConfigHandler),
    application:start(App).

ensure_mnesia_stopped() ->
    mria:stop(),
    mria_mnesia:delete_schema().

%% Help function to wait for Fun to yield 'true'.
wait_for(Fn, Ln, F, Timeout) ->
    {Pid, Mref} = erlang:spawn_monitor(fun() -> wait_loop(F, catch_call(F)) end),
    wait_for_down(Fn, Ln, Timeout, Pid, Mref, false).

flush() ->
    flush([]).

flush(Msgs) ->
    receive
        M -> flush([M | Msgs])
    after 0 -> lists:reverse(Msgs)
    end.

client_ssl_twoway() ->
    client_ssl_twoway(default).

client_ssl_twoway(TLSVsn) ->
    client_certs() ++ ciphers(TLSVsn).

%% Paths prepended to cert filenames
client_certs() ->
    [{Key, app_path(emqx, FilePath)} || {Key, FilePath} <- ?MQTT_SSL_CLIENT_CERTS].

client_ssl() ->
    client_ssl(default).

client_ssl(TLSVsn) ->
    ciphers(TLSVsn) ++ [{reuse_sessions, true}].

%% determined via config file defaults
ciphers(default) -> [];
ciphers('tlsv1.3') -> ?TLS_1_3_CIPHERS;
ciphers(_OlderTLSVsn) -> ?TLS_OLD_CIPHERS.

wait_mqtt_payload(Payload) ->
    receive
        {publish, #{payload := Payload}} ->
            ct:pal("OK - received msg: ~p~n", [Payload])
    after 1000 ->
        ct:fail({timeout, Payload, {msg_box, flush()}})
    end.

not_wait_mqtt_payload(Payload) ->
    receive
        {publish, #{payload := Payload}} ->
            ct:fail({received, Payload})
    after 1000 ->
        ct:pal("OK - msg ~p is not received", [Payload])
    end.

wait_for_down(Fn, Ln, Timeout, Pid, Mref, Kill) ->
    receive
        {'DOWN', Mref, process, Pid, normal} ->
            ok;
        {'DOWN', Mref, process, Pid, {unexpected, Result}} ->
            erlang:error({unexpected, Fn, Ln, Result});
        {'DOWN', Mref, process, Pid, {crashed, {C, E, S}}} ->
            erlang:raise(C, {Fn, Ln, E}, S)
    after Timeout ->
        case Kill of
            true ->
                erlang:demonitor(Mref, [flush]),
                erlang:exit(Pid, kill),
                erlang:error({Fn, Ln, timeout});
            false ->
                Pid ! stop,
                wait_for_down(Fn, Ln, Timeout, Pid, Mref, true)
        end
    end.

wait_loop(_F, ok) ->
    exit(normal);
wait_loop(F, LastRes) ->
    receive
        stop -> erlang:exit(LastRes)
    after 100 ->
        Res = catch_call(F),
        wait_loop(F, Res)
    end.

catch_call(F) ->
    try
        case F() of
            true -> ok;
            Other -> {unexpected, Other}
        end
    catch
        C:E:S ->
            {crashed, {C, E, S}}
    end.
force_set_config_file_paths(emqx_conf, [Path] = Paths) ->
    Bin = iolist_to_binary(io_lib:format("node.config_files = [~p]~n", [Path])),
    ok = file:write_file(Path, Bin, [append]),
    application:set_env(emqx, config_files, Paths);
force_set_config_file_paths(emqx, Paths) ->
    application:set_env(emqx, config_files, Paths);
force_set_config_file_paths(_, _) ->
    ok.

copy_certs(emqx_conf, Dest0) ->
    Dest = filename:dirname(Dest0),
    From = string:replace(Dest, "emqx_conf", "emqx"),
    os:cmd(["cp -rf ", From, "/certs ", Dest, "/"]),
    ok;
copy_certs(_, _) ->
    ok.

load_config(SchemaModule, Config, Opts) ->
    ConfigBin =
        case is_map(Config) of
            true -> jsx:encode(Config);
            false -> Config
        end,
    ok = emqx_config:delete_override_conf_files(),
    ok = emqx_config:init_load(SchemaModule, ConfigBin, Opts),
    ok.

load_config(SchemaModule, Config) ->
    load_config(SchemaModule, Config, #{raw_with_default => false}).

-spec is_all_tcp_servers_available(Servers) -> Result when
    Servers :: [{Host, Port}],
    Host :: inet:socket_address() | inet:hostname(),
    Port :: inet:port_number(),
    Result :: boolean().
is_all_tcp_servers_available(Servers) ->
    Fun =
        fun({Host, Port}) ->
            is_tcp_server_available(Host, Port)
        end,
    case lists:partition(Fun, Servers) of
        {_, []} ->
            true;
        {_, Unavail} ->
            ct:print("Unavailable servers: ~p", [Unavail]),
            false
    end.

-spec is_tcp_server_available(
    Host :: inet:socket_address() | inet:hostname(),
    Port :: inet:port_number()
) -> boolean.
is_tcp_server_available(Host, Port) ->
    is_tcp_server_available(Host, Port, ?DEFAULT_TCP_SERVER_CHECK_AVAIL_TIMEOUT).

-spec is_tcp_server_available(
    Host :: inet:socket_address() | inet:hostname(),
    Port :: inet:port_number(),
    Timeout :: integer()
) -> boolean.
is_tcp_server_available(Host, Port, Timeout) ->
    case gen_tcp:connect(Host, Port, [], Timeout) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            true;
        {error, _} ->
            false
    end.

start_ekka() ->
    try mnesia_hook:module_info() of
        _ -> ekka:start()
    catch
        _:_ ->
            %% Falling back to using Mnesia DB backend.
            application:set_env(mria, db_backend, mnesia),
            ekka:start()
    end.

ensure_dashboard_listeners_started(emqx_dashboard) ->
    true = emqx_dashboard_listener:is_ready(infinity),
    ok;
ensure_dashboard_listeners_started(_App) ->
    ok.

-spec ensure_quic_listener(Name :: atom(), UdpPort :: inet:port_number()) -> ok.
ensure_quic_listener(Name, UdpPort) ->
    application:ensure_all_started(quicer),
    Conf = #{
        acceptors => 16,
        bind => {{0, 0, 0, 0}, UdpPort},
        certfile => filename:join(code:lib_dir(emqx), "etc/certs/cert.pem"),
        ciphers =>
            [
                "TLS_AES_256_GCM_SHA384",
                "TLS_AES_128_GCM_SHA256",
                "TLS_CHACHA20_POLY1305_SHA256"
            ],
        enabled => true,
        idle_timeout => 15000,
        keyfile => filename:join(code:lib_dir(emqx), "etc/certs/key.pem"),
        limiter => #{},
        max_connections => 1024000,
        mountpoint => <<>>,
        zone => default
    },
    emqx_config:put([listeners, quic, Name], Conf),
    case emqx_listeners:start_listener(quic, Name, Conf) of
        ok -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

%%
%% Clusterisation and multi-node testing
%%

-type cluster_spec() :: [node_spec()].
-type node_spec() :: role() | {role(), shortname()} | {role(), shortname(), node_opts()}.
-type role() :: core | replicant.
-type shortname() :: atom().
-type nodename() :: atom().
-type node_opts() :: #{
    %% Need to loaded apps. These apps will be loaded once the node started
    load_apps => list(),
    %% Need to started apps. It is the first arg passed to emqx_common_test_helpers:start_apps/2
    apps => list(),
    %% Extras app starting handler. It is the second arg passed to emqx_common_test_helpers:start_apps/2
    env_handler => fun((AppName :: atom()) -> term()),
    %% Application env preset before calling `emqx_common_test_helpers:start_apps/2`
    env => {AppName :: atom(), Key :: atom(), Val :: term()},
    %% Whether to execute `emqx_config:init_load(SchemaMod)`
    %% default: true
    load_schema => boolean(),
    %% Eval by emqx_config:put/2
    conf => [{KeyPath :: list(), Val :: term()}],
    %% Fast option to config listener port
    %% default rule:
    %% - tcp: base_port
    %% - ssl: base_port + 1
    %% - ws : base_port + 3
    %% - wss: base_port + 4
    listener_ports => [{Type :: tcp | ssl | ws | wss, inet:port_number()}]
}.

-spec emqx_cluster(cluster_spec()) -> [{shortname(), node_opts()}].
emqx_cluster(Specs) ->
    emqx_cluster(Specs, #{}).

-spec emqx_cluster(cluster_spec(), node_opts()) -> [{shortname(), node_opts()}].
emqx_cluster(Specs, CommonOpts) when is_list(CommonOpts) ->
    emqx_cluster(Specs, maps:from_list(CommonOpts));
emqx_cluster(Specs0, CommonOpts) ->
    Specs1 = lists:zip(Specs0, lists:seq(1, length(Specs0))),
    Specs = expand_node_specs(Specs1, CommonOpts),
    %% Assign grpc ports
    GenRpcPorts = maps:from_list([
        {node_name(Name), {tcp, gen_rpc_port(base_port(Num))}}
     || {{_, Name, _}, Num} <- Specs
    ]),
    %% Set the default node of the cluster:
    CoreNodes = [node_name(Name) || {{core, Name, _}, _} <- Specs],
    JoinTo =
        case CoreNodes of
            [First | _] -> First;
            _ -> undefined
        end,
    [
        {Name,
            merge_opts(Opts, #{
                base_port => base_port(Number),
                join_to => JoinTo,
                env => [
                    {mria, core_nodes, CoreNodes},
                    {mria, node_role, Role},
                    {gen_rpc, client_config_per_node, {internal, GenRpcPorts}}
                ]
            })}
     || {{Role, Name, Opts}, Number} <- Specs
    ].

%% Lower level starting API

-spec start_slave(shortname(), node_opts()) -> nodename().
start_slave(Name, Opts) ->
    {ok, Node} = ct_slave:start(
        list_to_atom(atom_to_list(Name) ++ "@" ++ host()),
        [
            {kill_if_fail, true},
            {monitor_master, true},
            {init_timeout, 10000},
            {startup_timeout, 10000},
            {erl_flags, erl_flags()}
        ]
    ),

    pong = net_adm:ping(Node),
    setup_node(Node, Opts),
    Node.

%% Node stopping
stop_slave(Node) ->
    ct_slave:stop(Node).

%% EPMD starting
start_epmd() ->
    [] = os:cmd("\"" ++ epmd_path() ++ "\" -daemon"),
    ok.

epmd_path() ->
    case os:find_executable("epmd") of
        false ->
            ct:pal(critical, "Could not find epmd.~n"),
            exit(epmd_not_found);
        GlobalEpmd ->
            GlobalEpmd
    end.

%% Node initialization

-spec setup_node(nodename(), node_opts()) -> ok.
setup_node(Node, Opts) when is_list(Opts) ->
    setup_node(Node, maps:from_list(Opts));
setup_node(Node, Opts) when is_map(Opts) ->
    %% Default base port is selected upon Node from 1100 to 65530 with step 10
    BasePort = maps:get(base_port, Opts, 1100 + erlang:phash2(Node, 6553 - 110) * 10),
    Apps = maps:get(apps, Opts, []),
    StartApps = maps:get(start_apps, Opts, true),
    JoinTo = maps:get(join_to, Opts, undefined),
    EnvHandler = maps:get(env_handler, Opts, fun(_) -> ok end),
    ConfigureGenRpc = maps:get(configure_gen_rpc, Opts, true),
    LoadSchema = maps:get(load_schema, Opts, true),
    SchemaMod = maps:get(schema_mod, Opts, emqx_schema),
    LoadApps = maps:get(load_apps, Opts, [gen_rpc, emqx, ekka, mria] ++ Apps),
    Env = maps:get(env, Opts, []),
    Conf = maps:get(conf, Opts, []),
    ListenerPorts = maps:get(listener_ports, Opts, [
        {Type, listener_port(BasePort, Type)}
     || Type <- [tcp, ssl, ws, wss]
    ]),

    %% Load env before doing anything to avoid overriding
    [ok = rpc:call(Node, application, load, [App]) || App <- LoadApps],

    %% Needs to be set explicitly because ekka:start() (which calls `gen`) is called without Handler
    %% in emqx_common_test_helpers:start_apps(...)
    ConfigureGenRpc andalso
        begin
            ok = rpc:call(Node, application, set_env, [
                gen_rpc, tcp_server_port, gen_rpc_port(BasePort)
            ]),
            ok = rpc:call(Node, application, set_env, [gen_rpc, port_discovery, manual])
        end,

    %% Setting env before starting any applications
    [
        ok = rpc:call(Node, application, set_env, [Application, Key, Value])
     || {Application, Key, Value} <- Env
    ],

    %% Here we start the apps
    EnvHandlerForRpc =
        fun(App) ->
            %% We load configuration, and than set the special environment variable
            %% which says that emqx shouldn't load configuration at startup
            %% Otherwise, configuration gets loaded and all preset env in EnvHandler is lost
            LoadSchema andalso
                begin
                    emqx_config:init_load(SchemaMod),
                    application:set_env(emqx, init_config_load_done, true)
                end,

            %% Need to set this otherwise listeners will conflict between each other
            [
                ok = emqx_config:put([listeners, Type, default, bind], {
                    {127, 0, 0, 1}, Port
                })
             || {Type, Port} <- ListenerPorts
            ],

            [ok = emqx_config:put(KeyPath, Value) || {KeyPath, Value} <- Conf],
            ok = EnvHandler(App),
            ok
        end,

    StartApps andalso
        begin
            ok = rpc:call(Node, emqx_common_test_helpers, start_apps, [Apps, EnvHandlerForRpc])
        end,

    %% Join the cluster if JoinTo is specified
    case JoinTo of
        undefined ->
            ok;
        _ ->
            case rpc:call(Node, ekka, join, [JoinTo]) of
                ok ->
                    ok;
                ignore ->
                    ok;
                Err ->
                    stop_slave(Node),
                    error({failed_to_join_cluster, #{node => Node, error => Err}})
            end
    end,
    ok.

%% Helpers

node_name(Name) ->
    list_to_atom(lists:concat([Name, "@", host()])).

gen_node_name(Num) ->
    list_to_atom("autocluster_node" ++ integer_to_list(Num)).

host() ->
    [_, Host] = string:tokens(atom_to_list(node()), "@"),
    Host.

merge_opts(Opts1, Opts2) ->
    maps:merge_with(
        fun
            (env, Env1, Env2) -> lists:usort(Env2 ++ Env1);
            (conf, Conf1, Conf2) -> lists:usort(Conf2 ++ Conf1);
            (apps, Apps1, Apps2) -> lists:usort(Apps2 ++ Apps1);
            (load_apps, Apps1, Apps2) -> lists:usort(Apps2 ++ Apps1);
            (_Option, _Old, Value) -> Value
        end,
        Opts1,
        Opts2
    ).

erl_flags() ->
    %% One core and redirecting logs to master
    "+S 1:1 -master " ++ atom_to_list(node()) ++ " " ++ ebin_path().

ebin_path() ->
    string:join(["-pa" | lists:filter(fun is_lib/1, code:get_path())], " ").

is_lib(Path) ->
    string:prefix(Path, code:lib_dir()) =:= nomatch andalso
        string:str(Path, "_build/default/plugins") =:= 0.

%% Ports

base_port(Number) ->
    10000 + Number * 100.

gen_rpc_port(BasePort) ->
    BasePort - 1.

listener_port(BasePort, tcp) ->
    BasePort;
listener_port(BasePort, ssl) ->
    BasePort + 1;
listener_port(BasePort, quic) ->
    BasePort + 2;
listener_port(BasePort, ws) ->
    BasePort + 3;
listener_port(BasePort, wss) ->
    BasePort + 4.

%% Autocluster helpers

expand_node_specs(Specs, CommonOpts) ->
    lists:map(
        fun({Spec, Num}) ->
            {
                case Spec of
                    core ->
                        {core, gen_node_name(Num), CommonOpts};
                    replicant ->
                        {replicant, gen_node_name(Num), CommonOpts};
                    {Role, Name} when is_atom(Name) ->
                        {Role, Name, CommonOpts};
                    {Role, Opts} when is_list(Opts) ->
                        Opts1 = maps:from_list(Opts),
                        {Role, gen_node_name(Num), merge_opts(CommonOpts, Opts1)};
                    {Role, Name, Opts} when is_list(Opts) ->
                        Opts1 = maps:from_list(Opts),
                        {Role, Name, merge_opts(CommonOpts, Opts1)};
                    {Role, Opts} ->
                        {Role, gen_node_name(Num), merge_opts(CommonOpts, Opts)};
                    {Role, Name, Opts} ->
                        {Role, Name, merge_opts(CommonOpts, Opts)}
                end,
                Num
            }
        end,
        Specs
    ).

%% is useful when iterating on the tests in a loop, to get rid of all
%% the garbaged printed before the test itself beings.
clear_screen() ->
    io:format(standard_io, "\033[H\033[2J", []),
    io:format(standard_error, "\033[H\033[2J", []),
    io:format(standard_io, "\033[H\033[3J", []),
    io:format(standard_error, "\033[H\033[3J", []),
    ok.

with_mock(Mod, FnName, MockedFn, Fun) ->
    ok = meck:new(Mod, [non_strict, no_link, no_history, passthrough]),
    ok = meck:expect(Mod, FnName, MockedFn),
    try
        Fun()
    after
        ok = meck:unload(Mod)
    end.

%%-------------------------------------------------------------------------------
%% Toxiproxy utils
%%-------------------------------------------------------------------------------

reset_proxy(ProxyHost, ProxyPort) ->
    Url = "http://" ++ ProxyHost ++ ":" ++ integer_to_list(ProxyPort) ++ "/reset",
    Body = <<>>,
    {ok, {{_, 204, _}, _, _}} = httpc:request(
        post,
        {Url, [], "application/json", Body},
        [],
        [{body_format, binary}]
    ).

with_failure(FailureType, Name, ProxyHost, ProxyPort, Fun) ->
    enable_failure(FailureType, Name, ProxyHost, ProxyPort),
    try
        Fun()
    after
        heal_failure(FailureType, Name, ProxyHost, ProxyPort)
    end.

enable_failure(FailureType, Name, ProxyHost, ProxyPort) ->
    case FailureType of
        down -> switch_proxy(off, Name, ProxyHost, ProxyPort);
        timeout -> timeout_proxy(on, Name, ProxyHost, ProxyPort);
        latency_up -> latency_up_proxy(on, Name, ProxyHost, ProxyPort)
    end.

heal_failure(FailureType, Name, ProxyHost, ProxyPort) ->
    case FailureType of
        down -> switch_proxy(on, Name, ProxyHost, ProxyPort);
        timeout -> timeout_proxy(off, Name, ProxyHost, ProxyPort);
        latency_up -> latency_up_proxy(off, Name, ProxyHost, ProxyPort)
    end.

switch_proxy(Switch, Name, ProxyHost, ProxyPort) ->
    Url = "http://" ++ ProxyHost ++ ":" ++ integer_to_list(ProxyPort) ++ "/proxies/" ++ Name,
    Body =
        case Switch of
            off -> #{<<"enabled">> => false};
            on -> #{<<"enabled">> => true}
        end,
    BodyBin = emqx_json:encode(Body),
    {ok, {{_, 200, _}, _, _}} = httpc:request(
        post,
        {Url, [], "application/json", BodyBin},
        [],
        [{body_format, binary}]
    ).

timeout_proxy(on, Name, ProxyHost, ProxyPort) ->
    Url =
        "http://" ++ ProxyHost ++ ":" ++ integer_to_list(ProxyPort) ++ "/proxies/" ++ Name ++
            "/toxics",
    NameBin = list_to_binary(Name),
    Body = #{
        <<"name">> => <<NameBin/binary, "_timeout">>,
        <<"type">> => <<"timeout">>,
        <<"stream">> => <<"upstream">>,
        <<"toxicity">> => 1.0,
        <<"attributes">> => #{<<"timeout">> => 0}
    },
    BodyBin = emqx_json:encode(Body),
    {ok, {{_, 200, _}, _, _}} = httpc:request(
        post,
        {Url, [], "application/json", BodyBin},
        [],
        [{body_format, binary}]
    );
timeout_proxy(off, Name, ProxyHost, ProxyPort) ->
    ToxicName = Name ++ "_timeout",
    Url =
        "http://" ++ ProxyHost ++ ":" ++ integer_to_list(ProxyPort) ++ "/proxies/" ++ Name ++
            "/toxics/" ++ ToxicName,
    Body = <<>>,
    {ok, {{_, 204, _}, _, _}} = httpc:request(
        delete,
        {Url, [], "application/json", Body},
        [],
        [{body_format, binary}]
    ).

latency_up_proxy(on, Name, ProxyHost, ProxyPort) ->
    Url =
        "http://" ++ ProxyHost ++ ":" ++ integer_to_list(ProxyPort) ++ "/proxies/" ++ Name ++
            "/toxics",
    NameBin = list_to_binary(Name),
    Body = #{
        <<"name">> => <<NameBin/binary, "_latency_up">>,
        <<"type">> => <<"latency">>,
        <<"stream">> => <<"upstream">>,
        <<"toxicity">> => 1.0,
        <<"attributes">> => #{
            <<"latency">> => 20_000,
            <<"jitter">> => 3_000
        }
    },
    BodyBin = emqx_json:encode(Body),
    {ok, {{_, 200, _}, _, _}} = httpc:request(
        post,
        {Url, [], "application/json", BodyBin},
        [],
        [{body_format, binary}]
    );
latency_up_proxy(off, Name, ProxyHost, ProxyPort) ->
    ToxicName = Name ++ "_latency_up",
    Url =
        "http://" ++ ProxyHost ++ ":" ++ integer_to_list(ProxyPort) ++ "/proxies/" ++ Name ++
            "/toxics/" ++ ToxicName,
    Body = <<>>,
    {ok, {{_, 204, _}, _, _}} = httpc:request(
        delete,
        {Url, [], "application/json", Body},
        [],
        [{body_format, binary}]
    ).

%%-------------------------------------------------------------------------------
%% Testcase teardown utilities
%%-------------------------------------------------------------------------------

%% stop the janitor gracefully to ensure proper cleanup order and less
%% noise in the logs.
call_janitor() ->
    Janitor = get_or_spawn_janitor(),
    exit(Janitor, normal),
    ok.

get_or_spawn_janitor() ->
    case get({?MODULE, janitor_proc}) of
        undefined ->
            {ok, Janitor} = emqx_test_janitor:start_link(),
            put({?MODULE, janitor_proc}, Janitor),
            Janitor;
        Janitor ->
            Janitor
    end.

on_exit(Fun) ->
    Janitor = get_or_spawn_janitor(),
    ok = emqx_test_janitor:push_on_exit_callback(Janitor, Fun).
