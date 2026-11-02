"""Build-local fixes for the pinned ESP-IDF 5.5.4 HID host. Never edit the SDK.

Fail closed if upstream source changes. The generated sources replace two bt
translation units and use the same target, configuration and include paths.
"""
from pathlib import Path
import sys

sdk, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)

def replace(source, old, new):
    if source.count(old) != 1:
        raise SystemExit(f"ESP-IDF HID patch no longer matches exactly once: {old[:100]!r}")
    return source.replace(old, new)

act = (sdk / 'host/bluedroid/bta/hh/bta_hh_act.c').read_text()
# Only the owner of the single discovery database may change its callback target.
act = replace(act, '    bta_hh_cb.p_cur = p_cb;\n\n#if (BTA_HH_LE_INCLUDED == TRUE)',
              '    /* Keep the active SDP owner until its callback completes. */\n\n#if (BTA_HH_LE_INCLUDED == TRUE)')
# Tag descriptor callbacks on the BTA thread, before they cross to the BTC thread.
act = replace(act, 'void bta_hh_get_dscp_act(', '''UINT8 wii_hh_descriptor_handle(const tBTA_HH_DEV_DSCP_INFO *info)
{
    for (unsigned i = 0; i < BTA_HH_MAX_DEVICE; ++i) {
        if (&bta_hh_cb.kdev[i].dscp_info == info) return bta_hh_cb.kdev[i].hid_handle;
    }
    return BTA_HH_INVALID_HANDLE;
}

void bta_hh_get_dscp_act(''')
(out / 'bta_hh_act.c').write_text(act)

btc = (sdk / 'host/bluedroid/btc/profile/std/hid/btc_hh.c').read_text()
btc = replace(btc, '// btc_storage_load_bonded_hid_info();', 'btc_storage_load_bonded_hid_info();')
btc = replace(btc, 'static void bte_hh_evt(',
              'extern UINT8 wii_hh_descriptor_handle(const tBTA_HH_DEV_DSCP_INFO *info);\n\nstatic void bte_hh_evt(')
btc = replace(btc, '    msg.act = event;\n', '''    msg.act = event;
    msg.aid = event == BTA_HH_GET_DSCP_EVT ? wii_hh_descriptor_handle(&p_data->dscp_info) : BTA_HH_INVALID_HANDLE;
''')
btc = replace(btc, '            p_dev = btc_hh_cb.p_curr_dev;',
              '            p_dev = btc_hh_find_connected_dev_by_handle(msg->aid);')
# An unrelated incoming OPEN must not release an outgoing connection's busy gate.
btc = replace(btc, '        if (btc_hh_cb.status == BTC_HH_DEV_CONNECTING) {',
              '        if (memcmp(btc_hh_cb.pending_conn_address, bd_addr_null, BD_ADDR_LEN) != 0) {')
btc = replace(btc, '''        memset(btc_hh_cb.pending_conn_address, 0, BD_ADDR_LEN);
        if (p_data->conn.status == BTA_HH_OK) {''', '''        if (memcmp(btc_hh_cb.pending_conn_address, p_data->conn.bda, BD_ADDR_LEN) == 0) {
            memset(btc_hh_cb.pending_conn_address, 0, BD_ADDR_LEN);
        }
        if (p_data->conn.status == BTA_HH_OK) {''')
# The SDK helper otherwise reads an uninitialized pointer for an empty descriptor.
btc = replace(btc, '    dest->descriptor.dl_len = 0;\n',
              '    dest->descriptor.dl_len = 0;\n    dest->descriptor.dsc_list = NULL;\n')
(out / 'btc_hh.c').write_text(btc)
