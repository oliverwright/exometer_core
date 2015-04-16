%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.  All Rights Reserved.
%%
%%   This Source Code Form is subject to the terms of the Mozilla Public
%%   License, v. 2.0. If a copy of the MPL was not distributed with this
%%   file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%% -------------------------------------------------------------------
-module(exometer_report_SUITE).

%% common_test exports
-export(
   [
    all/0, groups/0, suite/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2
   ]).

%% test case exports
-export(
   [
    test_newentry/1,
    test_subscribe/1,
    test_subscribe_find/1,
    test_subscribe_select/1,
    test_logger_flow_control/1,
    test_logger_flow_control_2/1
   ]).

-behaviour(exometer_report_logger).
-export([logger_init_output/1,
         logger_handle_data/2]).

-include_lib("common_test/include/ct.hrl").
-include_lib("exometer_core/include/exometer.hrl").

-define(DEFAULT_PORT, 8888).

all() ->
    [
     {group, test_reporter},
     {group, test_logger}
    ].

groups() ->
    [
     {test_reporter, [shuffle],
      [
       test_newentry,
       test_subscribe,
       test_subscribe_find,
       test_subscribe_select
      ]},
     {test_logger, [],
      [
       test_logger_flow_control,
       test_logger_flow_control_2
      ]}
    ].

suite() ->
    [].

init_per_suite(Config) ->
    Config.

init_per_testcase(_Case, Config) ->
    {ok, StartedApps} = exometer_test_util:ensure_all_started(exometer_core),
    [{started_apps, StartedApps} | Config].

end_per_testcase(_Case, Config) ->
    stop_started_apps(Config).

end_per_suite(_Config) ->
    ok.

stop_started_apps(Config) ->
    [application:stop(App) ||
        App <- lists:reverse(?config(started_apps, Config))].

test_newentry(Config) ->
    {ok, Info} = start_logger_and_reporter(test_udp, Config),
    Tab = ets_tab(Info),
    [] = ets:tab2list(Tab),
    exometer:new([c], counter, []),
    %% exometer_report:trigger_interval(test_udp, main),
    R1 = check_logger_msg(),
    [{_,{newentry,#exometer_entry{name = [c], type = counter}} = R1}] =
        ets:tab2list(Tab),
    ok.

test_subscribe(Config) ->
    ok = exometer:new([c], counter, []),
    {ok, _Info} = start_logger_and_reporter(test_udp, Config),
    exometer_report:subscribe(test_udp, [c], value, main, true),
    %% exometer_report:trigger_interval(test_udp, main),
    {subscribe, [{metric, [c]},
                 {datapoint, value} | _]} = check_logger_msg(),
    ok.

test_subscribe_find(Config) ->
    ok = exometer:new([c,1], counter, []),
    ok = exometer:new([c,2], counter, []),
    {ok, Info} = start_logger_and_reporter(test_udp, Config),
    exometer_report:subscribe(test_udp, {find,[c,'_']}, value, main, true),
    {subscribe, [{metric, {find,[c,'_']}},
                 {datapoint, value} | _]} = R1 = check_logger_msg(),
    exometer_report:trigger_interval(test_udp, main),
    {report, [{prefix,[]},{metric,[c,1]}|_]} = R2 = check_logger_msg(),
    {report, [{prefix,[]},{metric,[c,2]}|_]} = R3 = check_logger_msg(),
    Tab = ets_tab(Info),
    [{_,R1},{_,R2},{_,R3}] = ets:tab2list(Tab),
    ok.

test_subscribe_select(Config) ->
    ok = exometer:new([c,1], counter, []),
    ok = exometer:new([c,2], counter, []),
    ok = exometer:new([c,3], counter, []),
    {ok, Info} = start_logger_and_reporter(test_udp, Config),
    exometer_report:subscribe(
      test_udp,
      {select,[{ {[c,'$1'],'_','_'},[{'<','$1',3}], ['$_'] }]},
      value, main, true),
    {subscribe, [{metric, {select,_}},
                 {datapoint, value} | _]} = R1 = check_logger_msg(),
    exometer_report:trigger_interval(test_udp, main),
    {report, [{prefix,[]},{metric,[c,1]}|_]} = R2 = check_logger_msg(),
    {report, [{prefix,[]},{metric,[c,2]}|_]} = R3 = check_logger_msg(),
    Tab = ets_tab(Info),
    [{_,R1},{_,R2},{_,R3}] = ets:tab2list(Tab),
    ok.

test_logger_flow_control(Config) ->
    ok = test_subscribe_find([{input_port_options, [{active, false}]}|Config]).

test_logger_flow_control_2(Config) ->
    ok = test_subscribe_find([{input_port_options, [{active, once}]}|Config]).

start_logger_and_reporter(Reporter, Config) ->
    Port = get_port(Config),
    IPO = config(input_port_options, Config, []),
    ct:log("IPO = ~p~n", [IPO]),
    Res = exometer_report_logger:new(
            [{id, ?MODULE},
             {input, [{mode, plugin},
                      {module, exometer_test_udp_reporter},
                      {state, {Port, IPO}}]},
             {output, [{mode, plugin},
                       {module, exometer_test_udp_reporter}]},
             {output, [{mode, ets}]},
             {output, [{mode, plugin},
                       {module, ?MODULE},
                       {state, self()}]}]),
    ct:log("Logger start: ~p~n", [Res]),
    Info = exometer_report_logger:info(),
    ct:log("Logger Info = ~p~n", [Info]),
    ok = exometer_report:add_reporter(
           Reporter,
           [{module, exometer_test_udp_reporter},
            {hostname, "localhost"},
            {port, Port},
            {intervals, [{main, manual}]}]),
    {ok, Info}.

check_logger_msg() ->
    receive
        {logger_got, Data} ->
            ct:log("logger_got: ~p~n", [Data]),
            Data
    after 1000 ->
            error(logger_ack_timeout)
    end.

ets_tab(Info) ->
    [T] = [tree_opt([output,ets,tab], I) || {_,[{id,?MODULE}|I]} <- Info],
    T.

get_port(Config) ->
    config(port, Config, ?DEFAULT_PORT).

config(Key, Config, Default) ->
    case ?config(Key, Config) of
        undefined ->
            Default;
        Value ->
            Value
    end.

tree_opt([H|T], L) when is_list(L) ->
    case lists:keyfind(H, 1, L) of
        {_, Val} ->
            case T of
                [] -> Val;
                [_|_] ->
                    tree_opt(T, Val)
            end;
        false ->
            undefined
    end;
tree_opt([], _) ->
    undefined.


logger_init_output(Pid) ->
    {ok, Pid}.

logger_handle_data(Data, Pid) ->
    Pid ! {logger_got, Data},
    {Data, Pid}.
