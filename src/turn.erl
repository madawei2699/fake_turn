%%%-------------------------------------------------------------------
%%% File    : turn.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description : Handles TURN allocations, see RFC5766
%%% Created : 23 Aug 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% Copyright (C) 2002-2021 ProcessOne, SARL. All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%%-------------------------------------------------------------------

-module(turn).

-define(GEN_FSM, p1_fsm).

-behaviour(?GEN_FSM).

%% API
-export([start_link/1, start/1, stop/1, route/2]).
%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3,
         code_change/4]).
%% gen_fsm states
-export([wait_for_allocate/2, active/2]).

-include("stun.hrl").
-include("stun_logger.hrl").

-define(MAX_LIFETIME, 3600000). %% 1 hour
-define(DEFAULT_LIFETIME, 600000). %% 10 minutes
-define(PERMISSION_LIFETIME, 300000). %% 5 minutes
-define(CHANNEL_LIFETIME, 600000). %% 10 minutes
-define(INITIAL_BLACKLIST,
        [%% Could be used to circumvent blocking of loopback addresses:
         {{0, 0, 0, 0}, 8},
         {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
         %% RFC 6156, 9.1: "a TURN relay MUST NOT accept Teredo or 6to4 addresses".
         {{8193, 0, 0, 0, 0, 0, 0, 0}, 32},   % 2001::/32 (Teredo).
         {{8194, 0, 0, 0, 0, 0, 0, 0}, 16}]). % 2002::/16 (6to4).

-type addr() :: {inet:ip_address(), inet:port_number()}.
-type subnet() :: {inet:ip4_address(), 0..32} | {inet:ip6_address(), 0..128}.
-type blacklist() :: [subnet()].

-export_type([blacklist/0]).

-record(state,
        {sock_mod = gen_udp :: gen_udp | gen_tcp | fast_tls,
         sock :: inet:socket() | fast_tls:tls_socket() | undefined,
         addr = {{0, 0, 0, 0}, 0} :: addr(), owner = self() :: pid(),
         username = <<"">> :: binary(), realm = <<"">> :: binary(),
         key = {<<"">>, <<"">>, <<"">>} :: {binary(), binary(), binary()},
         server_name = <<"">> :: binary(), peers = #{} :: map(), channels = #{} :: map(),
         permissions = #{} :: map(), max_permissions :: non_neg_integer() | atom() | undefined,
         relay_ipv4_ip = {127, 0, 0, 1} :: inet:ip4_address(),
         relay_ipv6_ip :: inet:ip6_address() | undefined, min_port = 49152 :: non_neg_integer(),
         mock_relay_ip = {127, 0, 0, 1} :: inet:ip4_address(),
         max_port = 65535 :: non_neg_integer(), relay_addr :: addr() | undefined,
         last_trid :: non_neg_integer() | undefined, last_pkt = <<>> :: binary(),
         seq = 1 :: non_neg_integer(), life_timer :: reference() | undefined,
         blacklist = [] :: blacklist(), hook_fun :: function() | undefined, session_id :: binary(),
         rcvd_bytes = 0 :: non_neg_integer(), rcvd_pkts = 0 :: non_neg_integer(),
         sent_bytes = 0 :: non_neg_integer(), sent_pkts = 0 :: non_neg_integer(),
         parent :: pid() | undefined, parent_resolver :: function() | undefined,
         start_timestamp = get_timestamp() :: integer(), unknonw_ports :: sets:set(),
         candidate_addr :: {inet:ip4_address(), inet:port_number()} | undefined,
         server_pid :: pid()}).

%%====================================================================
%% API
%%====================================================================
start_link(Opts) ->
    ?GEN_FSM:start_link(?MODULE, [Opts], []).

start(Opts) ->
    supervisor:start_child(turn_tmp_sup, [Opts]).

stop(Pid) ->
    ?GEN_FSM:send_all_state_event(Pid, stop).

route(Pid, Msg) ->
    ?GEN_FSM:send_event(Pid, Msg).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
init([Opts]) ->
    process_flag(trap_exit, true),
    ID = proplists:get_value(session_id, Opts),
    Owner = proplists:get_value(owner, Opts),
    Username = proplists:get_value(username, Opts),
    Realm = proplists:get_value(realm, Opts),
    AddrPort = proplists:get_value(addr, Opts),
    SockMod = proplists:get_value(sock_mod, Opts),
    HookFun = proplists:get_value(hook_fun, Opts),
    Blacklist = proplists:get_value(blacklist, Opts) ++ ?INITIAL_BLACKLIST,
    State =
        #state{sock_mod = SockMod,
               sock = proplists:get_value(sock, Opts),
               key = proplists:get_value(key, Opts),
               relay_ipv4_ip = proplists:get_value(relay_ipv4_ip, Opts),
               relay_ipv6_ip = proplists:get_value(relay_ipv6_ip, Opts),
               mock_relay_ip = proplists:get_value(mock_relay_ip, Opts),
               min_port = proplists:get_value(min_port, Opts),
               max_port = proplists:get_value(max_port, Opts),
               max_permissions = proplists:get_value(max_permissions, Opts),
               server_name = proplists:get_value(server_name, Opts),
               parent = proplists:get_value(parent, Opts),
               parent_resolver = proplists:get_value(parent_resolver, Opts),
               server_pid = proplists:get_value(server_pid, Opts),
               unknonw_ports = sets:new([{version, 2}]),
               username = Username,
               realm = Realm,
               addr = AddrPort,
               session_id = ID,
               owner = Owner,
               hook_fun = HookFun,
               blacklist = Blacklist},
    stun_logger:set_metadata(turn, SockMod, ID, AddrPort, Username),
    MaxAllocs = proplists:get_value(max_allocs, Opts),
    if is_pid(Owner) ->
           erlang:monitor(process, Owner);
       true ->
           ok
    end,
    Lifetime =
        case proplists:get_value(lifetime, Opts) of
            N when erlang:is_number(N), N >= 600 ->
                N * 1000;
            _else ->
                ?DEFAULT_LIFETIME
        end,
    TRef = erlang:start_timer(Lifetime, self(), stop),
    case turn_sm:add_allocation(AddrPort, Username, Realm, MaxAllocs, self()) of
        ok ->
            run_hook(turn_session_start, State),
            {ok, wait_for_allocate, State#state{life_timer = TRef}}        %%
                                                                           %% turn_sm:add_allocation/5 currently doesn't return errors.
                                                                           %%
                                                                           %% {error, Reason} ->
                                                                           %%     {stop, Reason}
    end.

wait_for_allocate(#stun{class = request, method = ?STUN_METHOD_ALLOCATE} = Msg, State) ->
    Family =
        case Msg#stun.'REQUESTED-ADDRESS-FAMILY' of
            undefined ->
                inet;
            ipv4 ->
                inet;
            ipv6 ->
                inet6
        end,
    IsBlacklisted = blacklisted(State),
    Resp = prepare_response(State, Msg),
    if Msg#stun.'REQUESTED-TRANSPORT' == undefined ->
           ?LOG_NOTICE("Rejecting allocation request: no transport requested"),
           R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(400)},
           {stop, normal, send(State, R)};
       Msg#stun.'REQUESTED-TRANSPORT' == unknown ->
           ?LOG_NOTICE("Rejecting allocation request: unsupported transport"),
           R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(442)},
           {stop, normal, send(State, R)};
       Msg#stun.'DONT-FRAGMENT' == true ->
           ?LOG_NOTICE("Rejecting allocation request: dont-fragment not "
                       "supported"),
           R = Resp#stun{class = error,
                         'UNKNOWN-ATTRIBUTES' = [?STUN_ATTR_DONT_FRAGMENT],
                         'ERROR-CODE' = stun_codec:error(420)},
           {stop, normal, send(State, R)};
       Family == inet6, State#state.relay_ipv6_ip == undefined ->
           ?LOG_NOTICE("Rejecting allocation request: IPv6 not supported"),
           R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(440)},
           {stop, normal, send(State, R)};
       IsBlacklisted ->
           ?LOG_NOTICE("Rejecting allocation request: Client address is "
                       "blacklisted"),
           R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(403)},
           {stop, normal, send(State, R)};
       true ->
           MockRelayPort = stun:rand_uniform(State#state.min_port, State#state.max_port),
           MockRelayAddr = {State#state.mock_relay_ip, MockRelayPort},
           Lifetime = time_left(State#state.life_timer),
           AddrPort = stun:unmap_v4_addr(State#state.addr),
           R = Resp#stun{class = response,
                         'XOR-RELAYED-ADDRESS' = MockRelayAddr,
                         'LIFETIME' = Lifetime,
                         'XOR-MAPPED-ADDRESS' = AddrPort},
           NewState = send(State, R),
           {next_state, active, NewState#state{relay_addr = MockRelayAddr}}
    end;
wait_for_allocate(Event, State) ->
    ?LOG_ERROR("Unexpected event in 'wait_for_allocate': ~p", [Event]),
    {next_state, wait_for_allocate, State}.

active(#stun{trid = TrID}, #state{last_trid = TrID} = State) ->
    send(State, State#state.last_pkt),
    {next_state, active, State};
active(#stun{class = request, method = ?STUN_METHOD_ALLOCATE} = Msg, State) ->
    ?LOG_NOTICE("Rejecting allocation request: Relay already allocated"),
    Resp = prepare_response(State, Msg),
    R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(437)},
    {next_state, active, send(State, R)};
active(#stun{class = request,
             'REQUESTED-ADDRESS-FAMILY' = ipv4,
             method = ?STUN_METHOD_REFRESH} =
           Msg,
       #state{relay_addr = {{_, _, _, _, _, _, _, _}, _}} = State) ->
    ?LOG_NOTICE("Rejecting refresh request: IPv4 requested for IPv6 peer"),
    Resp = prepare_response(State, Msg),
    R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(443)},
    {next_state, active, send(State, R)};
active(#stun{class = request,
             'REQUESTED-ADDRESS-FAMILY' = ipv6,
             method = ?STUN_METHOD_REFRESH} =
           Msg,
       #state{relay_addr = {{_, _, _, _}, _}} = State) ->
    ?LOG_NOTICE("Rejecting refresh request: IPv6 requested for IPv4 peer"),
    Resp = prepare_response(State, Msg),
    R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(443)},
    {next_state, active, send(State, R)};
active(#stun{class = request, method = ?STUN_METHOD_REFRESH} = Msg, State) ->
    Resp = prepare_response(State, Msg),
    case Msg#stun.'LIFETIME' of
        0 ->
            ?LOG_DEBUG("Client requested closing the TURN session"),
            R = Resp#stun{class = response, 'LIFETIME' = 0},
            {stop, normal, send(State, R)};
        LifeTime ->
            cancel_timer(State#state.life_timer),
            MSecs =
                if LifeTime == undefined ->
                       ?DEFAULT_LIFETIME;
                   true ->
                       lists:min([LifeTime * 1000, ?MAX_LIFETIME])
                end,
            ?LOG_NOTICE("Refreshing TURN allocation (lifetime: ~B seconds)", [MSecs div 1000]),
            TRef = erlang:start_timer(MSecs, self(), stop),
            R = Resp#stun{class = response, 'LIFETIME' = MSecs div 1000},
            {next_state, active, send(State#state{life_timer = TRef}, R)}
    end;
active(#stun{class = request,
             'XOR-PEER-ADDRESS' = XorPeerAddrs,
             method = ?STUN_METHOD_CREATE_PERMISSION} =
           Msg,
       State) ->
    {Addrs, _Ports} = lists:unzip(XorPeerAddrs),
    Resp = prepare_response(State, Msg),
    case update_permissions(State, Addrs) of
        {ok, NewState} ->
            R = Resp#stun{class = response},
            {next_state, active, send(NewState, R)};
        {error, Code} ->
            Err = {_, Txt} = stun_codec:error(Code),
            ?LOG_NOTICE("Rejecting permission creation request: ~s", [Txt]),
            R = Resp#stun{class = error, 'ERROR-CODE' = Err},
            {next_state, active, send(State, R)}
    end;
active(#stun{class = indication,
             method = ?STUN_METHOD_SEND,
             'XOR-PEER-ADDRESS' = [{Addr, Port}],
             'DATA' = Data},
       State)
    when is_binary(Data) ->
    State1 =
        case State#state.candidate_addr of
            undefined ->
                State#state{candidate_addr = {Addr, Port}};
            {_Addr, _Port} ->
                State
        end,
    State3 =
        case maps:find(Addr, State#state.permissions) of
            {ok, _} ->
                State2 = send_payload_to_parent(State1, Data),
                count_sent(State2, Data);
            error ->
                State1
        end,
    {next_state, active, State3};
active(#stun{class = request,
             'CHANNEL-NUMBER' = Channel,
             'XOR-PEER-ADDRESS' = [{Addr, _Port} = Peer],
             method = ?STUN_METHOD_CHANNEL_BIND} =
           Msg,
       State)
    when is_integer(Channel), Channel >= 16#4000, Channel =< 16#7ffe ->
    Resp = prepare_response(State, Msg),
    case {maps:find(Channel, State#state.channels), maps:find(Peer, State#state.peers)} of
        {_, {ok, OldChannel}} when Channel /= OldChannel ->
            ?LOG_NOTICE("Rejecting channel binding request: Peer already bound "
                        "to a different channel (~.16B)",
                        [OldChannel]),
            R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(400)},
            {next_state, active, send(State, R)};
        {{ok, {OldPeer, _}}, _} when Peer /= OldPeer ->
            ?LOG_NOTICE("Rejecting channel binding request: Channel already "
                        "bound to a different peer (~s)",
                        [stun_logger:encode_addr(OldPeer)]),
            R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(400)},
            {next_state, active, send(State, R)};
        {FindResult, _} ->
            case update_permissions(State, [Addr]) of
                {ok, NewState0} ->
                    NewState1 =
                        case NewState0#state.candidate_addr of
                            undefined ->
                                NewState0#state{candidate_addr = Peer};
                            {_Addr, _Port1} ->
                                NewState0
                        end,
                    _Op = case FindResult of
                              {ok, {_, OldTRef}} ->
                                  cancel_timer(OldTRef),
                                  maybe_log(<<"Refreshing">>);
                              _ ->
                                  maybe_log(<<"Binding">>)
                          end,
                    TRef =
                        erlang:start_timer(?CHANNEL_LIFETIME, self(), {channel_timeout, Channel}),
                    Peers = maps:put(Peer, Channel, State#state.peers),
                    Chans = maps:put(Channel, {Peer, TRef}, State#state.channels),
                    NewState = NewState1#state{peers = Peers, channels = Chans},
                    ?LOG_DEBUG("~s TURN channel ~.16B for peer ~s",
                              [_Op, Channel, stun_logger:encode_addr(Peer)]),
                    R = Resp#stun{class = response},
                    {next_state, active, send(NewState, R)};
                {error, Code} ->
                    Err = {_, Txt} = stun_codec:error(Code),
                    ?LOG_NOTICE("Rejecting channel binding request: ~s", [Txt]),
                    R = Resp#stun{class = error, 'ERROR-CODE' = Err},
                    {next_state, active, send(State, R)}
            end
    end;
active(#stun{class = request, method = ?STUN_METHOD_CHANNEL_BIND} = Msg, State) ->
    ?LOG_NOTICE("Rejecting channel binding request: Missing channel number "
                "and/or peer address"),
    Resp = prepare_response(State, Msg),
    R = Resp#stun{class = error, 'ERROR-CODE' = stun_codec:error(400)},
    {next_state, active, send(State, R)};
active(#turn{channel = Channel, data = Data}, State) ->
    case maps:find(Channel, State#state.channels) of
        {ok, _} ->
            State1 = send_payload_to_parent(State, Data),
            State2 = count_sent(State1, Data),
            {next_state, active, State2};
        error ->
            {next_state, active, State}
    end;
active(Event, State) ->
    ?LOG_ERROR("Unexpected event in 'active': ~p", [Event]),
    {next_state, active, State}.

handle_event(stop, _StateName, State) ->
    {stop, normal, State};
handle_event(Event, StateName, State) ->
    ?LOG_ERROR("Unexpected event in '~s': ~p", [StateName, Event]),
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, {error, badarg}, StateName, State}.

handle_info({timeout, _Tref, stop}, _StateName, State) ->
    {stop, normal, State};
handle_info({timeout, _Tref, {permission_timeout, Addr}}, StateName, State) ->
    ?LOG_DEBUG("TURN permission for ~s timed out", [stun_logger:encode_addr(Addr)]),
    case maps:find(Addr, State#state.permissions) of
        {ok, _} ->
            Perms = maps:remove(Addr, State#state.permissions),
            {next_state, StateName, State#state{permissions = Perms}};
        error ->
            {next_state, StateName, State}
    end;
handle_info({timeout, _Tref, {channel_timeout, Channel}}, StateName, State) ->
    case maps:find(Channel, State#state.channels) of
        {ok, {Peer, _}} ->
            ?LOG_DEBUG("TURN channel ~.16B for peer ~s timed out",
                      [Channel, stun_logger:encode_addr(Peer)]),
            Chans = maps:remove(Channel, State#state.channels),
            Peers = maps:remove(Peer, State#state.peers),
            {next_state, StateName, State#state{channels = Chans, peers = Peers}};
        error ->
            {next_state, StateName, State}
    end;
handle_info({'DOWN', _Ref, _, _, _}, _StateName, State) ->
    {stop, normal, State};
handle_info({send_connectivity_check, Params}, StateName, State) ->
    {_RelayAddr, RelayPort} = State#state.relay_addr,
    Class = proplists:get_value(class, Params),
    XorMappedAddress =
        case Class of
            response ->
                {State#state.mock_relay_ip, RelayPort};
            _ ->
                undefined
        end,
    IcePwd = proplists:get_value(ice_pwd, Params),
    StunMsg =
        #stun{class = Class,
              method = ?STUN_METHOD_BINDING,
              magic = proplists:get_value(magic, Params),
              trid = proplists:get_value(trid, Params),
              'USERNAME' = proplists:get_value(username, Params),
              'PRIORITY' = proplists:get_value(priority, Params),
              'USE-CANDIDATE' = proplists:get_value(use_candidate, Params, false),
              'ICE-CONTROLLING' = proplists:get_value(ice_controlling, Params, false),
              'ICE-CONTROLLED' = proplists:get_value(ice_controlled, Params, false),
              'XOR-MAPPED-ADDRESS' = XorMappedAddress,
              'ERROR-CODE' =
                  stun_codec:error(
                      proplists:get_value(error_code, Params))},
    Payload =
        stun_codec:add_fingerprint(
            stun_codec:encode(StunMsg, IcePwd)),
    NewState = send_payload_to_client(Payload, State),
    {next_state, StateName, NewState};
handle_info({send_ice_payload, Payload}, StateName, State) ->
    NewState = send_payload_to_client(Payload, State),
    {next_state, StateName, NewState};
handle_info(Info, StateName, State) ->
    ?LOG_ERROR("Unexpected info in '~s': ~p", [StateName, Info]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, State) ->
    AddrPort = State#state.addr,
    Username = State#state.username,
    Realm = State#state.realm,
    RcvdBytes = State#state.rcvd_bytes,
    RcvdPkts = State#state.rcvd_pkts,
    SentBytes = State#state.sent_bytes,
    SentPkts = State#state.sent_pkts,
    case State#state.relay_addr of
        undefined ->
            ok;
        _RAddrPort ->
            ?LOG_DEBUG("Deleting TURN allocation")
    end,
    if is_pid(State#state.owner) ->
           stun:stop(State#state.owner);
       true ->
           ok
    end,
    if State#state.parent /= undefined ->
           State#state.parent ! {alloc_deleting, self()};
       true ->
           ok
    end,
    ?LOG_DEBUG("Relayed ~B KiB (in ~B B / ~B packets, out ~B B / ~B packets), "
                "duration: ~B seconds",
                [round((RcvdBytes + SentBytes) / 1024),
                 RcvdBytes,
                 RcvdPkts,
                 SentBytes,
                 SentPkts,
                 get_duration(State, second)]),
    run_hook(turn_session_stop, State),
    turn_sm:del_allocation(AddrPort, Username, Realm).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
update_permissions(_State, []) ->
    {error, 400};
update_permissions(#state{permissions = Perms, max_permissions = Max}, Addrs)
    when map_size(Perms) + length(Addrs) > Max ->
    {error, 508};
update_permissions(#state{relay_addr = {IP, _}} = State, Addrs) ->
    case {families_match(IP, Addrs), blacklisted(State, Addrs)} of
        {true, false} ->
            Perms =
                lists:foldl(fun(Addr, Acc) ->
                               _Op = case maps:find(Addr, Acc) of
                                         {ok, OldTRef} ->
                                             cancel_timer(OldTRef),
                                             maybe_log(<<"Refreshing">>);
                                         error ->
                                             maybe_log(<<"Creating">>)
                                     end,
                               TRef =
                                   erlang:start_timer(?PERMISSION_LIFETIME,
                                                      self(),
                                                      {permission_timeout, Addr}),
                               ?LOG_DEBUG("~s TURN permission for ~s",
                                         [_Op, stun_logger:encode_addr(Addr)]),
                               maps:put(Addr, TRef, Acc)
                            end,
                            State#state.permissions,
                            Addrs),
            {ok, State#state{permissions = Perms}};
        {false, _} ->
            {error, 443};
        {_, true} ->
            {error, 403}
    end.

send(State, Pkt) when is_binary(Pkt) ->
    SockMod = State#state.sock_mod,
    Sock = State#state.sock,
    if SockMod == gen_udp ->
           {Addr, Port} = State#state.addr,
           gen_udp:send(Sock, Addr, Port, Pkt);
       true ->
           case SockMod:send(Sock, Pkt) of
               ok ->
                   ok;
               _ ->
                   ?LOG_DEBUG("Cannot respond to client: Connection closed"),
                   exit(normal)
           end
    end;
send(State, Msg) ->
    Key = State#state.key,
    case Msg of
        #stun{class = indication} ->
            send(State, stun_codec:encode(Msg)),
            State;
        #stun{class = response} ->
            Pkt = stun_codec:encode(Msg, Key),
            send(State, Pkt),
            State#state{last_trid = Msg#stun.trid, last_pkt = Pkt};
        _ ->
            send(State, stun_codec:encode(Msg, Key)),
            State
    end.

send_payload_to_client(Payload, State) ->
    CandidateAddr = State#state.candidate_addr,
    {CandidateIP, _} = CandidateAddr,
    case {maps:find(CandidateIP, State#state.permissions),
          maps:find(CandidateAddr, State#state.peers)}
    of
        {{ok, _}, {ok, Channel}} ->
            TurnMsg = #turn{channel = Channel, data = Payload},
            State1 = count_rcvd(State, Payload),
            send(State1, TurnMsg);
        {{ok, _}, error} ->
            Seq = State#state.seq,
            Ind = #stun{class = indication,
                        method = ?STUN_METHOD_DATA,
                        trid = Seq,
                        'XOR-PEER-ADDRESS' = [CandidateAddr],
                        'DATA' = Payload},
            State1 = count_rcvd(State, Payload),
            send(State1#state{seq = Seq + 1}, Ind);
        {error, _} ->
            State
    end.

is_stun_packet(<<Head:8, _Tail/binary>>) when Head < 2 ->
    true;
is_stun_packet(_Pkt) ->
    false.

send_payload_to_parent(State, Payload) ->
    NewState = try_resolve_parent(State),

    case {NewState#state.parent, is_stun_packet(Payload)} of
        {undefined, _IsStunPacket} ->
            pass;
        {Parent, true} ->
            {ok, StunMsg} = stun_codec:decode(Payload, datagram),
            Parent
            ! {connectivity_check,
               [{class, StunMsg#stun.class},
                {magic, StunMsg#stun.magic},
                {trid, StunMsg#stun.trid},
                {username, StunMsg#stun.'USERNAME'},
                {priority, StunMsg#stun.'PRIORITY'},
                {use_candidate, StunMsg#stun.'USE-CANDIDATE'},
                {ice_controlled, StunMsg#stun.'ICE-CONTROLLED'},
                {ice_controlling, StunMsg#stun.'ICE-CONTROLLING'}],
               self()};
        {Parent, false} ->
            Parent ! {ice_payload, Payload}
    end,
    NewState.

try_resolve_parent(#state{parent = undefined} = State) ->
    {_Addr, Port} = State#state.candidate_addr,
    case sets:is_element(Port, State#state.unknonw_ports) of
        true ->
            State;
        false ->
            case (State#state.parent_resolver)(Port) of
                {ok, Parent} ->
                    State#state{parent = Parent};
                {error, _Reason} ->
                    ?LOG_DEBUG("Parent assigned to port ~B could not be resolved", [Port]),
                    NewUnknownPorts = sets:add_element(Port, State#state.unknonw_ports),
                    State#state{unknonw_ports = NewUnknownPorts}
            end
    end;
try_resolve_parent(State) ->
    State.

time_left(TRef) ->
    erlang:read_timer(TRef) div 1000.

families_match(RelayAddr, Addrs) ->
    lists:all(fun(Addr) -> family_matches(RelayAddr, Addr) end, Addrs).

family_matches({_, _, _, _}, {_, _, _, _}) ->
    true;
family_matches({_, _, _, _, _, _, _, _}, {_, _, _, _, _, _, _, _}) ->
    true;
family_matches(_Addr1, _Addr2) ->
    false.

blacklisted(#state{addr = {IP, _Port}} = State) ->
    blacklisted(State, [IP]).

blacklisted(#state{blacklist = Blacklist}, IPs) ->
    lists:any(fun(IP) ->
                 lists:any(fun({Net, Mask}) -> match_subnet(IP, Net, Mask) end, Blacklist)
              end,
              IPs).

match_subnet({_, _, _, _} = IP, {_, _, _, _} = Net, Mask) ->
    IPInt = ip_to_integer(IP),
    NetInt = ip_to_integer(Net),
    M = bnot (1 bsl (32 - Mask) - 1),
    IPInt band M =:= NetInt band M;
match_subnet({_, _, _, _, _, _, _, _} = IP, {_, _, _, _, _, _, _, _} = Net, Mask) ->
    IPInt = ip_to_integer(IP),
    NetInt = ip_to_integer(Net),
    M = bnot (1 bsl (128 - Mask) - 1),
    IPInt band M =:= NetInt band M;
match_subnet({_, _, _, _} = IP, {0, 0, 0, 0, 0, 16#FFFF, _, _} = Net, Mask) ->
    IPInt = ip_to_integer({0, 0, 0, 0, 0, 16#FFFF, 0, 0}) + ip_to_integer(IP),
    NetInt = ip_to_integer(Net),
    M = bnot (1 bsl (128 - Mask) - 1),
    IPInt band M =:= NetInt band M;
match_subnet({0, 0, 0, 0, 0, 16#FFFF, _, _} = IP, {_, _, _, _} = Net, Mask) ->
    IPInt = ip_to_integer(IP) - ip_to_integer({0, 0, 0, 0, 0, 16#FFFF, 0, 0}),
    NetInt = ip_to_integer(Net),
    M = bnot (1 bsl (32 - Mask) - 1),
    IPInt band M =:= NetInt band M;
match_subnet(_, _, _) ->
    false.

ip_to_integer({IP1, IP2, IP3, IP4}) ->
    IP1 bsl 8 bor IP2 bsl 8 bor IP3 bsl 8 bor IP4;
ip_to_integer({IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}) ->
    IP1 bsl 16 bor IP2 bsl 16 bor IP3 bsl 16 bor IP4 bsl 16 bor IP5 bsl 16 bor IP6 bsl 16
    bor IP7
    bsl 16
    bor IP8.

format_error({error, Reason}) ->
    case inet:format_error(Reason) of
        "unknown POSIX error" ->
            Reason;
        Res ->
            Res
    end.

cancel_timer(undefined) ->
    ok;
cancel_timer(TRef) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive
                {timeout, TRef, _} ->
                    ok
            after 0 ->
                ok
            end;
        _ ->
            ok
    end.

get_timestamp() ->
    erlang:monotonic_time().

get_duration(State, Unit) ->
    erlang:convert_time_unit(get_duration(State), native, Unit).

get_duration(#state{start_timestamp = Start}) ->
    get_timestamp() - Start.

prepare_response(State, Msg) ->
    #stun{method = Msg#stun.method,
          magic = Msg#stun.magic,
          trid = Msg#stun.trid,
          'SOFTWARE' = State#state.server_name}.

count_sent(#state{sent_bytes = SentSize, sent_pkts = SentPkts} = State, Data) ->
    State#state{sent_bytes = SentSize + byte_size(Data), sent_pkts = SentPkts + 1}.

count_rcvd(#state{rcvd_bytes = RcvdSize, rcvd_pkts = RcvdPkts} = State, Data) ->
    State#state{rcvd_bytes = RcvdSize + byte_size(Data), rcvd_pkts = RcvdPkts + 1}.

run_hook(HookName,
         #state{session_id = ID,
                username = User,
                realm = Realm,
                addr = Client,
                sock_mod = SockMod,
                hook_fun = HookFun} =
             State)
    when is_function(HookFun) ->
    Info0 =
        #{id => ID,
          user => User,
          realm => Realm,
          client => Client,
          transport => stun_logger:encode_transport(SockMod)},
    Info =
        case {HookName, State} of
            {turn_session_start, _State} ->
                Info0;
            {turn_session_stop,
             #state{sent_bytes = SentBytes,
                    sent_pkts = SentPkts,
                    rcvd_bytes = RcvdBytes,
                    rcvd_pkts = RcvdPkts}} ->
                Info0#{sent_bytes => SentBytes,
                       sent_pkts => SentPkts,
                       rcvd_bytes => RcvdBytes,
                       rcvd_pkts => RcvdPkts,
                       duration => get_duration(State)}
        end,
    ?LOG_DEBUG("Running '~s' hook", [HookName]),
    try
        HookFun(HookName, Info)
    catch
        _:Err ->
            ?LOG_ERROR("Hook '~s' failed: ~p", [HookName, Err])
    end;
run_hook(HookName, _State) ->
    ?LOG_DEBUG("No callback function specified for '~s' hook", [HookName]),
    ok.

-ifdef(USE_OLD_LOGGER).
-ifdef(debug).

maybe_log(Term) ->
    Term.

-else.

maybe_log(_Term) ->
    ok.

-endif.

-else.

maybe_log(Term) ->
    Term.

-endif.
