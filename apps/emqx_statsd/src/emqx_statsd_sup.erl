%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%%-------------------------------------------------------------------
%% @doc emqx_statsd top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(emqx_statsd_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    ensure_child_started/1,
    ensure_child_stopped/1
]).

-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(Mod, Opts), #{
    id => Mod,
    start => {Mod, start_link, Opts},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [Mod]
}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec ensure_child_started(atom()) -> ok.
ensure_child_started(Mod) when is_atom(Mod) ->
    assert_started(supervisor:start_child(?MODULE, ?CHILD(Mod, []))).

%% @doc Stop the child worker process.
-spec ensure_child_stopped(any()) -> ok.
ensure_child_stopped(ChildId) ->
    case supervisor:terminate_child(?MODULE, ChildId) of
        ok ->
            %% with terminate_child/2 returned 'ok', it's not possible
            %% for supervisor:delete_child/2 to return {error, Reason}
            ok = supervisor:delete_child(?MODULE, ChildId);
        {error, not_found} ->
            ok
    end.

init([]) ->
    Children =
        case emqx_conf:get([statsd, enable], false) of
            true -> [?CHILD(emqx_statsd, [])];
            false -> []
        end,
    {ok, {{one_for_one, 100, 3600}, Children}}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

assert_started({ok, _Pid}) -> ok;
assert_started({error, {already_started, _Pid}}) -> ok;
assert_started({error, Reason}) -> erlang:error(Reason).
