%% mob_bluetooth_nif — Erlang NIF module for the mob_bluetooth tier-1 plugin.
%%
%% The zig side (priv/native/jni/mob_bluetooth_nif.zig) registers the 16 bt_*
%% NIFs under this module name via its `mob_bluetooth_nif_nif_init` export. On
%% device the NIF is statically linked into the host binary; on a host dev
%% build it isn't linked, so on_load tolerates the load failure and the stubs
%% fall back to nif_error until the native merge links the .zig in.
-module(mob_bluetooth_nif).
-export([
    bt_list_paired/0,
    bt_start_discovery/0,
    bt_cancel_discovery/0,
    bt_pair/1,
    bt_unpair/1,
    bt_disconnect/1,
    bt_hfp_connect/1,
    bt_hfp_subscribe_vendor_at/2,
    bt_hfp_send_vendor_at/3,
    bt_hfp_start_sco/1,
    bt_hfp_stop_sco/1,
    bt_spp_connect/1,
    bt_spp_write/2,
    ble_start_advertising/1,
    ble_stop_advertising/0,
    ble_notify/2
]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_bluetooth_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

bt_list_paired() ->
    erlang:nif_error(nif_not_loaded).

bt_start_discovery() ->
    erlang:nif_error(nif_not_loaded).

bt_cancel_discovery() ->
    erlang:nif_error(nif_not_loaded).

bt_pair(_Json) ->
    erlang:nif_error(nif_not_loaded).

bt_unpair(_Json) ->
    erlang:nif_error(nif_not_loaded).

bt_disconnect(_Session) ->
    erlang:nif_error(nif_not_loaded).

bt_hfp_connect(_Json) ->
    erlang:nif_error(nif_not_loaded).

bt_hfp_subscribe_vendor_at(_Session, _Json) ->
    erlang:nif_error(nif_not_loaded).

bt_hfp_send_vendor_at(_Session, _Cmd, _Args) ->
    erlang:nif_error(nif_not_loaded).

bt_hfp_start_sco(_Session) ->
    erlang:nif_error(nif_not_loaded).

bt_hfp_stop_sco(_Session) ->
    erlang:nif_error(nif_not_loaded).

bt_spp_connect(_Json) ->
    erlang:nif_error(nif_not_loaded).

bt_spp_write(_Session, _Bytes) ->
    erlang:nif_error(nif_not_loaded).

%% BLE (Low Energy) — GATT peripheral. Cross-platform (zig on Android, objc on
%% iOS); both register these three under this module.
ble_start_advertising(_Json) ->
    erlang:nif_error(nif_not_loaded).

ble_stop_advertising() ->
    erlang:nif_error(nif_not_loaded).

ble_notify(_CharUuid, _Bytes) ->
    erlang:nif_error(nif_not_loaded).
