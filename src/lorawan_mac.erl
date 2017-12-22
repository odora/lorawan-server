%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_mac).

-export([ingest_frame/1, handle_accept/5, encode_unicast/5, encode_multicast/2]).
-export([binary_to_hex/1, hex_to_binary/1]).
% for unit testing
-export([reverse/1, cipher/5, b0/4]).

-define(MAX_FCNT_GAP, 16384).

-include("lorawan_application.hrl").
-include("lorawan.hrl").

% TODO complete type specification
-spec ingest_frame(binary()) -> any().
ingest_frame(PHYPayload) ->
    Size = byte_size(PHYPayload)-4,
    <<Msg:Size/binary, MIC:4/binary>> = PHYPayload,
    mnesia:transaction(
        fun() ->
            ingest_frame0(Msg, MIC)
        end).

ingest_frame0(<<2#000:3, _:5,
        AppEUI0:8/binary, DevEUI0:8/binary, DevNonce:2/binary>> = Msg, MIC) ->
    {AppEUI, DevEUI} = {reverse(AppEUI0), reverse(DevEUI0)},
    case mnesia:read(devices, DevEUI, read) of
        [] ->
            {error, {device, DevEUI}, unknown_deveui, aggregated};
        [D] when D#device.appeui /= undefined, D#device.appeui /= AppEUI ->
            {error, {device, DevEUI}, {bad_appeui, binary_to_hex(AppEUI)}, aggregated};
        [D] ->
            case aes_cmac:aes_cmac(D#device.appkey, Msg, 4) of
                MIC ->
                    handle_join(D, DevNonce);
                _MIC2 ->
                    {error, {device, DevEUI}, bad_mic}
            end
    end;
ingest_frame0(<<MType:3, _:5,
        DevAddr0:4/binary, ADR:1, ADRACKReq:1, ACK:1, _RFU:1, FOptsLen:4,
        FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, Body/binary>> = Msg, MIC)
        when MType == 2#010; MType == 2#100 ->
    <<Confirm:1, _:2>> = <<MType:3>>,
    DevAddr = reverse(DevAddr0),
    {FPort, FRMPayload} = case Body of
        <<>> -> {undefined, <<>>};
        <<Port:8, Payload/binary>> -> {Port, Payload}
    end,
    Frame = #frame{conf=Confirm, devaddr=DevAddr, adr=ADR, adr_ack_req=ADRACKReq, ack=ACK, fcnt=FCnt, fport=FPort},

    case accept_node_frame(DevAddr, FCnt) of
        {ok, Fresh, {Network, Profile, Node}} ->
            case aes_cmac:aes_cmac(Node#node.nwkskey,
                    <<(b0(MType band 1, DevAddr, Node#node.fcntup, byte_size(Msg)))/binary, Msg/binary>>, 4) of
                MIC ->
                    case FPort of
                        0 when FOptsLen == 0 ->
                            Data = cipher(FRMPayload, Node#node.nwkskey, MType band 1, DevAddr, Node#node.fcntup),
                            {Fresh, {Network, Profile, Node},
                                Frame#frame{fopts=reverse(Data), data= <<>>}};
                        0 ->
                            {error, {node, DevAddr}, double_fopts};
                        _N ->
                            Data = cipher(FRMPayload, Node#node.appskey, MType band 1, DevAddr, Node#node.fcntup),
                            {Fresh, {Network, Profile, Node},
                                Frame#frame{fopts=FOpts, data=reverse(Data)}}
                    end;
                _MIC2 ->
                    {error, {node, DevAddr}, bad_mic}
            end;
        {error, ignored_node} ->
            {ignore, Frame};
        {error, Error, Attr} ->
            {error, {node, DevAddr}, Error, Attr}
    end;
ingest_frame0(Msg, _MIC) ->
    lager:debug("Bad frame: ~p", [Msg]),
    {error, bad_frame}.

handle_join(#device{deveui=DevEUI, profile=ProfID}=Device, DevNonce) ->
    case mnesia:read(profiles, ProfID, read) of
        [] ->
            {error, {device, DevEUI}, {unknown_profile, ProfID}, aggregated};
        [#profile{can_join=false}] ->
            lager:debug("Join ignored from DevEUI ~s", [binary_to_hex(DevEUI)]),
            ignore;
        [#profile{network=NetName}=Profile] ->
            case mnesia:read(networks, NetName, read) of
                [] ->
                    {error, {device, DevEUI}, {unknown_network, NetName}, aggregated};
                [Network] ->
                    DevAddr = get_devaddr(Network, Device),
                    {join, {Network, Profile, Device}, DevAddr, DevNonce}
            end
    end.

get_devaddr(#network{}, #device{node=DevAddr})
        when is_binary(DevAddr), byte_size(DevAddr) == 4 ->
    DevAddr;
get_devaddr(#network{netid=NetID, subid=SubID}, #device{}) ->
    create_devaddr(NetID, SubID, 3).

create_devaddr(NetID, SubID, Attempts) ->
    <<_:17, NwkID:7>> = NetID,
    DevAddr =
        case SubID of
            undefined ->
                <<NwkID:7, (rand_bitstring(25))/bitstring>>;
            Bits ->
                <<NwkID:7, Bits/bitstring, (rand_bitstring(25-bit_size(Bits)))/bitstring>>
        end,
    % assert uniqueness
    case mnesia:read(nodes, DevAddr, read) of
        [] ->
            DevAddr;
        [#node{}] when Attempts > 0 ->
            create_devaddr(NetID, SubID, Attempts-1)
        %% FIXME: do not crash when Attempts == 0
    end.

rand_bitstring(Num) when Num rem 8 > 0 ->
    <<Bits:Num/bitstring, _/bitstring>> = crypto:strong_rand_bytes(1 + Num div 8),
    Bits;
rand_bitstring(Num) when Num rem 8 == 0 ->
    crypto:strong_rand_bytes(Num div 8).

reset_node(DevAddr) ->
    ok = mnesia:dirty_delete(pending, DevAddr),
    % delete previously stored TX frames
    lorawan_db_guard:purge_txframes(DevAddr).


accept_node_frame(DevAddr, FCnt) ->
    case is_ignored(DevAddr, mnesia:dirty_all_keys(ignored_nodes)) of
        false ->
            case load_node(DevAddr) of
                {ok, {Network, Profile, Node}} ->
                    case check_fcnt({Network, Profile, Node}, FCnt) of
                        {ok, Fresh, Node2} ->
                            {ok, Fresh, {Network, Profile, Node2}};
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        true ->
            {error, ignored_node}
    end.

is_ignored(_DevAddr, []) ->
    false;
is_ignored(DevAddr, [Key|Rest]) ->
    [#ignored_node{devaddr=MatchAddr, mask=MatchMask}] = mnesia:dirty_read(ignored_nodes, Key),
    case match(DevAddr, MatchAddr, MatchMask) of
        true -> true;
        false -> is_ignored(DevAddr, Rest)
    end.

match(<<DevAddr:32>>, <<MatchAddr:32>>, undefined) ->
    DevAddr == MatchAddr;
match(<<DevAddr:32>>, <<MatchAddr:32>>, <<MatchMask:32>>) ->
    (DevAddr band MatchMask) == MatchAddr.

load_node(DevAddr) ->
    case mnesia:read(nodes, DevAddr, write) of
        [] ->
            case in_our_network(DevAddr) of
                true ->
                    % report errors for devices from own network only
                    {error, unknown_devaddr, aggregated};
                false ->
                    {error, ignored_node}
            end;
        [#node{profile=ProfID}=Node] ->
            case load_profile(ProfID) of
                {ok, Network, Profile} ->
                    {ok, {Network, Profile, Node}};
                Error ->
                    Error
            end
    end.

in_our_network(DevAddr) ->
    lists:any(
        fun({<<_:17, NwkID:7>>, SubId}) ->
            {MyPrefix, MyPrefixSize} =
                case SubId of
                    undefined ->
                        {NwkID, 7};
                    Bits ->
                        {<<NwkID:7, Bits/bitstring>>, 7+bit_size(Bits)}
                end,
            case DevAddr of
                <<MyPrefix:MyPrefixSize/bitstring, _/bitstring>> ->
                    true;
                _Else ->
                    false
            end
        end,
        mnesia:select(networks, [{#network{netid='$1', subid='$2', _='_'}, [], [{'$1', '$2'}]}], read)).

load_profile(ProfID) ->
    case mnesia:read(profiles, ProfID, read) of
        [] ->
            {error, {unknown_profile, ProfID}, aggregated};
        [#profile{network=NetName}=Profile] ->
            case mnesia:read(networks, NetName, read) of
                [] ->
                    {error, {unknown_network, NetName}, aggregated};
                [Network] ->
                    {ok, Network, Profile}
            end
    end.

check_fcnt({Network, Profile, Node}, FCnt) ->
    {ok, MaxLost} = application:get_env(lorawan_server, max_lost_after_reset),
    if
        Node#node.fcntup == undefined ->
            % first frame after join
            case FCnt of
                N when N == 0; N == 1 ->
                    % some device start with 0, some with 1
                    {ok, uplink, Node#node{fcntup = N}};
                N when N < ?MAX_FCNT_GAP ->
                    lorawan_utils:throw_warning({node, Node#node.devaddr}, {uplinks_missed, N-1}),
                    {ok, uplink, Node#node{fcntup = N}};
                _BigN ->
                    {error, {fcnt_gap_too_large, FCnt}, Node#node.last_rx}
            end;
        (Profile#profile.fcnt_check == 2 orelse Profile#profile.fcnt_check == 3),
                FCnt < Node#node.fcntup, FCnt < MaxLost ->
            lager:debug("~s fcnt reset", [binary_to_hex(Node#node.devaddr)]),
            reset_node(Node#node.devaddr),
            % works for 16b only since we cannot distinguish between reset and 32b rollover
            {ok, uplink, Node#node{fcntup = FCnt, fcntdown=0,
                adr_use=lorawan_mac_region:default_adr(Network#network.region),
                rxwin_use=lorawan_mac_region:default_rxwin(Network#network.region),
                last_reset=calendar:universal_time(), devstat_fcnt=undefined, last_qs=[]}};
        Profile#profile.fcnt_check == 3 ->
            % checks disabled
            {ok, uplink, Node#node{fcntup = FCnt}};
        FCnt == Node#node.fcntup ->
            % retransmission
            {ok, retransmit, Node};
        Profile#profile.fcnt_check == 1 ->
            % strict 32-bit
            case fcnt32_gap(Node#node.fcntup, FCnt) of
                1 ->
                    {ok, uplink, Node#node{fcntup = fcnt32_inc(Node#node.fcntup, 1)}};
                N when N < ?MAX_FCNT_GAP ->
                    lorawan_utils:throw_warning({node, Node#node.devaddr}, {uplinks_missed, N-1}),
                    {ok, uplink, Node#node{fcntup = fcnt32_inc(Node#node.fcntup, N)}};
                _BigN ->
                    {error, {fcnt_gap_too_large, FCnt}, Node#node.last_rx}
            end;
        true ->
            % strict 16-bit (default)
            case fcnt16_gap(Node#node.fcntup, FCnt) of
                1 ->
                    {ok, uplink, Node#node{fcntup = FCnt}};
                N when N < ?MAX_FCNT_GAP ->
                    lorawan_utils:throw_warning({node, Node#node.devaddr}, {uplinks_missed, N-1}),
                    {ok, uplink, Node#node{fcntup = FCnt}};
                _BigN ->
                    {error, {fcnt_gap_too_large, FCnt}, Node#node.last_rx}
            end
    end.

fcnt16_gap(A, B) ->
    if
        A =< B -> B - A;
        A > B -> 16#FFFF - A + B
    end.

fcnt32_gap(A, B) ->
    A16 = A band 16#FFFF,
    if
        A16 > B -> 16#10000 - A16 + B;
        true  -> B - A16
    end.

fcnt32_inc(FCntUp, N) ->
    % L#node.fcntup is 32b, but the received FCnt may be 16b only
    (FCntUp + N) band 16#FFFFFFFF.


handle_accept(Gateways, #network{netid=NetID}=Network, Device, DevAddr, DevNonce) ->
    AppNonce = crypto:strong_rand_bytes(3),
    {atomic, Node} = mnesia:transaction(
        fun() ->
            create_node(Gateways, Network, Device, AppNonce, DevAddr, DevNonce)
        end),
    reset_node(Node#node.devaddr),
    encode_accept(Device, Node, NetID, AppNonce).

create_node(Gateways, #network{netid=NetID}=Network, #device{deveui=DevEUI, appkey=AppKey}, AppNonce, DevAddr, DevNonce) ->
    NwkSKey = crypto:block_encrypt(aes_ecb, AppKey,
        padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    AppSKey = crypto:block_encrypt(aes_ecb, AppKey,
        padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>)),

    [Device] = mnesia:read(devices, DevEUI, write),
    Device2 = Device#device{node=DevAddr, last_join=calendar:universal_time()},
    ok = mnesia:write(devices, Device2, write),

    Node =
        case mnesia:read(nodes, DevAddr, write) of
            [#node{first_reset=First, reset_count=Cnt, last_rx=undefined, devstat=Stats}]
                    when is_integer(Cnt) ->
                lorawan_utils:throw_warning({node, DevAddr}, {repeated_reset, Cnt+1}, First),
                #node{reset_count=Cnt+1, devstat=Stats};
            [#node{devstat=Stats}] ->
                #node{first_reset=calendar:universal_time(), reset_count=0, devstat=Stats};
            [] ->
                #node{first_reset=calendar:universal_time(), reset_count=0, devstat=[]}
        end,

    lorawan_utils:throw_info({device, Device#device.deveui}, {join, binary_to_hex(Device#device.node)}),
    Node2 = Node#node{devaddr=Device#device.node,
        profile=Device#device.profile, appargs=Device#device.appargs,
        nwkskey=NwkSKey, appskey=AppSKey, fcntup=undefined, fcntdown=0,
        last_reset=calendar:universal_time(), last_gateways=Gateways,
        adr_flag=0, adr_set=undefined, adr_use=lorawan_mac_region:default_adr(Network#network.region), adr_failed=[],
        rxwin_use=lorawan_mac_region:default_rxwin(Network#network.region), rxwin_failed=[],
        devstat_fcnt=undefined, last_qs=[]},
    ok = mnesia:write(nodes, Node2, write),
    Node2.

encode_accept(#device{appkey=AppKey}, #node{devaddr=DevAddr, rxwin_use={RX1DROffset, RX2DataRate, _}}=Node, NetID, AppNonce) ->
    lager:debug("Join-Accept ~p, netid ~p, rx1droff ~p, rx2dr ~p, appkey ~p, appnce ~p",
        [binary_to_hex(DevAddr), NetID, RX1DROffset, RX2DataRate, binary_to_hex(AppKey), binary_to_hex(AppNonce)]),
    MHDR = <<2#001:3, 0:3, 0:2>>,
    MACPayload = <<AppNonce/binary, NetID/binary, (reverse(DevAddr))/binary, 0:1, RX1DROffset:3, RX2DataRate:4, 1>>,
    MIC = aes_cmac:aes_cmac(AppKey, <<MHDR/binary, MACPayload/binary>>, 4),

    % yes, decrypt; see LoRaWAN specification, Section 6.2.5
    PHYPayload = crypto:block_decrypt(aes_ecb, AppKey, padded(16, <<MACPayload/binary, MIC/binary>>)),
    {ok, Node, <<MHDR/binary, PHYPayload/binary>>}.

encode_unicast(DevAddr, ADR, ACK, FOpts, TxData) ->
    {atomic, L} = mnesia:transaction(
        fun() ->
            [D] = mnesia:read(nodes, DevAddr, write),
            FCnt = (D#node.fcntdown + 1) band 16#FFFFFFFF,
            NewD = D#node{fcntdown=FCnt},
            ok = mnesia:write(nodes, NewD, write),
            NewD
        end),
    encode_frame(DevAddr, L#node.nwkskey, L#node.appskey,
        L#node.fcntdown, ADR, ACK, FOpts, TxData).

encode_multicast(DevAddr, TxData) ->
    {atomic, G} = mnesia:transaction(
        fun() ->
            [D] = mnesia:read(multicast_channels, DevAddr, write),
            FCnt = (D#multicast_channel.fcntdown + 1) band 16#FFFFFFFF,
            NewD = D#multicast_channel{fcntdown=FCnt},
            ok = mnesia:write(multicast_channels, NewD, write),
            NewD
        end),
    encode_frame(DevAddr, G#multicast_channel.nwkskey, G#multicast_channel.appskey,
        G#multicast_channel.fcntdown, 0, 0, <<>>, TxData).

encode_frame(DevAddr, NwkSKey, _AppSKey, FCnt, ADR, ACK, FOpts,
        #txdata{port=0, data=Data, confirmed=Confirmed, pending=FPending}) ->
    FHDR = <<(reverse(DevAddr)):4/binary, ADR:1, 0:1, ACK:1, (bool_to_pending(FPending)):1, 0:4,
        FCnt:16/little-unsigned-integer>>,
    FRMPayload = cipher(FOpts, NwkSKey, 1, DevAddr, FCnt),
    MACPayload = <<FHDR/binary, 0:8, (reverse(FRMPayload))/binary>>,
    if
        Data == undefined; Data == <<>> -> ok;
        true -> lager:warning("Ignored application data with Port 0")
    end,
    sign_frame(Confirmed, DevAddr, NwkSKey, FCnt, MACPayload);

encode_frame(DevAddr, NwkSKey, AppSKey, FCnt, ADR, ACK, FOpts,
        #txdata{port=FPort, data=Data, confirmed=Confirmed, pending=FPending}) ->
    FHDR = <<(reverse(DevAddr)):4/binary, ADR:1, 0:1, ACK:1, (bool_to_pending(FPending)):1, (byte_size(FOpts)):4,
        FCnt:16/little-unsigned-integer, FOpts/binary>>,
    MACPayload = case FPort of
        undefined when Data == undefined; Data == <<>> ->
            <<FHDR/binary>>;
        undefined ->
            lager:warning("Ignored application data without a Port number"),
            <<FHDR/binary>>;
        Num when Num > 0 ->
            FRMPayload = cipher(Data, AppSKey, 1, DevAddr, FCnt),
            <<FHDR/binary, FPort:8, (reverse(FRMPayload))/binary>>
    end,
    sign_frame(Confirmed, DevAddr, NwkSKey, FCnt, MACPayload).

sign_frame(Confirmed, DevAddr, NwkSKey, FCnt, MACPayload) ->
    MType =
        case Confirmed of
            false -> 2#011;
            true -> 2#101
        end,
    Msg = <<MType:3, 0:3, 0:2, MACPayload/binary>>,
    MIC = aes_cmac:aes_cmac(NwkSKey, <<(b0(1, DevAddr, FCnt, byte_size(Msg)))/binary, Msg/binary>>, 4),
    {ok, <<Msg/binary, MIC/binary>>}.

bool_to_pending(true) -> 1;
bool_to_pending(false) -> 0;
bool_to_pending(undefined) -> 0.


cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I+1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) -> Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0,0,0,0, Dir, (reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

binxor(<<>>, <<>>, Acc) -> Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).

reverse(Bin) -> reverse(Bin, <<>>).
reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) ->
    reverse(Rest, <<H/binary, Acc/binary>>).

padded(Bytes, Msg) ->
    case bit_size(Msg) rem (8*Bytes) of
        0 -> Msg;
        N -> <<Msg/bitstring, 0:(8*Bytes-N)>>
    end.

% stackoverflow.com/questions/3768197/erlang-ioformatting-a-binary-to-hex
% a little magic from http://stackoverflow.com/users/2760050/himangshuj
binary_to_hex(undefined) ->
    undefined;
binary_to_hex(Id) ->
    << <<Y>> || <<X:4>> <= Id, Y <- integer_to_list(X,16)>>.

hex_to_binary(undefined) ->
    undefined;
hex_to_binary(Id) ->
    <<<<Z>> || <<X:8,Y:8>> <= Id,Z <- [binary_to_integer(<<X,Y>>,16)]>>.

% end of file
