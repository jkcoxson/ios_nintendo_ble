#![allow(non_upper_case_globals)] // Bindgen preserves ESP-IDF's C enum names.
mod ble;
mod protocol;

use esp_idf_svc::{
    bt::{BtDriver, BtDual},
    hal::peripherals::Peripherals,
    nvs::{EspDefaultNvsPartition, EspNvs},
    sys::*,
};
use std::{
    collections::HashSet,
    sync::{
        atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering},
        mpsc::{self, Sender, SyncSender},
        Arc, OnceLock,
    },
    time::{Duration, Instant},
};

pub type Address = [u8; 6];
pub enum Event {
    HostReady(u32),
    HostStopped(u32),
    Acl(Address, bool, u32),
    Discovered(Address, String, bool),
    RemoteNameFailed(Address, u32),
    DiscoveryStopped,
    Pin(Address, bool),
    Auth(Address, u32),
    LinkMode(Address, u8, u16),
    Open(Address, u8, u32, u32),
    Close(u8, u32, u32),
    Input(u8, Vec<u8>, u32),
    Output(u8, Vec<u8>),
    BleDisconnected,
    Control(u32, Vec<u8>),
}
static EVENTS: OnceLock<SyncSender<Event>> = OnceLock::new();
static LIFECYCLE: OnceLock<Sender<Event>> = OnceLock::new();
static DROPPED: AtomicU32 = AtomicU32::new(0);

fn emit(event: Event) {
    // Connection state must not be lost behind a burst of input samples.
    if !matches!(event, Event::Input(..)) {
        if let Some(sender) = LIFECYCLE.get() {
            let _ = sender.send(event);
        }
        return;
    }
    if let Some(sender) = EVENTS.get() {
        if sender.try_send(event).is_err() {
            DROPPED.fetch_add(1, Ordering::Relaxed);
        }
    }
}
fn name(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}
fn is_wii(name: &str) -> bool {
    name == "Nintendo RVL-CNT-01" || name == "Nintendo RVL-CNT-01-TR"
}

// ESP-IDF owns callback pointers and buffer lifetimes. Copy data before returning; all
// state changes and NVS writes happen on the main task, never on Bluetooth callbacks.
unsafe extern "C" fn gap_callback(event: esp_bt_gap_cb_event_t, param: *mut esp_bt_gap_cb_param_t) {
    let Some(p) = param.as_ref() else {
        return;
    };
    match event {
        esp_bt_gap_cb_event_t_ESP_BT_GAP_DISC_RES_EVT => {
            let d = p.disc_res;
            let mut device_name = String::new();
            let mut hid = false;
            if !d.prop.is_null() && (1..=16).contains(&d.num_prop) {
                for prop in std::slice::from_raw_parts(d.prop, d.num_prop as usize) {
                    if prop.val.is_null() || prop.len <= 0 || prop.len > 512 {
                        continue;
                    }
                    let bytes =
                        std::slice::from_raw_parts(prop.val as *const u8, prop.len as usize);
                    match prop.type_ {
                        esp_bt_gap_dev_prop_type_t_ESP_BT_GAP_DEV_PROP_BDNAME => {
                            device_name = name(bytes)
                        }
                        esp_bt_gap_dev_prop_type_t_ESP_BT_GAP_DEV_PROP_COD if bytes.len() >= 4 => {
                            let cod = u32::from_le_bytes(bytes[..4].try_into().unwrap());
                            hid = (cod >> 8) & 0x1f == 5;
                        }
                        esp_bt_gap_dev_prop_type_t_ESP_BT_GAP_DEV_PROP_EIR => {
                            let mut offset = 0;
                            while offset < bytes.len() {
                                let len = bytes[offset] as usize;
                                if len == 0 || offset + 1 + len > bytes.len() {
                                    break;
                                }
                                if bytes[offset + 1] == 9 || bytes[offset + 1] == 8 {
                                    device_name = name(&bytes[offset + 2..offset + 1 + len]);
                                }
                                offset += 1 + len;
                            }
                        }
                        _ => {}
                    }
                }
            }
            emit(Event::Discovered(d.bda, device_name, hid));
        }
        esp_bt_gap_cb_event_t_ESP_BT_GAP_READ_REMOTE_NAME_EVT => {
            let d = p.read_rmt_name;
            if d.stat == esp_bt_status_t_ESP_BT_STATUS_SUCCESS {
                emit(Event::Discovered(d.bda, name(&d.rmt_name), true));
            } else {
                emit(Event::RemoteNameFailed(d.bda, d.stat));
            }
        }
        esp_bt_gap_cb_event_t_ESP_BT_GAP_DISC_STATE_CHANGED_EVT => {
            if p.disc_st_chg.state == esp_bt_gap_discovery_state_t_ESP_BT_GAP_DISCOVERY_STOPPED {
                emit(Event::DiscoveryStopped);
            }
        }
        esp_bt_gap_cb_event_t_ESP_BT_GAP_ACL_CONN_CMPL_STAT_EVT => {
            let d = p.acl_conn_cmpl_stat;
            emit(Event::Acl(d.bda, true, d.stat));
        }
        esp_bt_gap_cb_event_t_ESP_BT_GAP_ACL_DISCONN_CMPL_STAT_EVT => {
            let d = p.acl_disconn_cmpl_stat;
            emit(Event::Acl(d.bda, false, d.reason));
        }
        esp_bt_gap_cb_event_t_ESP_BT_GAP_PIN_REQ_EVT => {
            emit(Event::Pin(p.pin_req.bda, p.pin_req.min_16_digit))
        }
        esp_bt_gap_cb_event_t_ESP_BT_GAP_AUTH_CMPL_EVT => {
            emit(Event::Auth(p.auth_cmpl.bda, p.auth_cmpl.stat))
        }
        esp_bt_gap_cb_event_t_ESP_BT_GAP_MODE_CHG_EVT => emit(Event::LinkMode(
            p.mode_chg.bda,
            p.mode_chg.mode,
            p.mode_chg.interval,
        )),
        _ => {}
    }
}

unsafe extern "C" fn hid_callback(event: esp_hidh_cb_event_t, param: *mut esp_hidh_cb_param_t) {
    let Some(p) = param.as_ref() else {
        return;
    };
    match event {
        esp_hidh_cb_event_t_ESP_HIDH_INIT_EVT => emit(Event::HostReady(p.init.status)),
        esp_hidh_cb_event_t_ESP_HIDH_DEINIT_EVT => emit(Event::HostStopped(p.deinit.status)),
        esp_hidh_cb_event_t_ESP_HIDH_OPEN_EVT => emit(Event::Open(
            p.open.bd_addr,
            p.open.handle,
            p.open.status,
            p.open.conn_status,
        )),
        esp_hidh_cb_event_t_ESP_HIDH_CLOSE_EVT => emit(Event::Close(
            p.close.handle,
            p.close.status,
            p.close.conn_status,
        )),
        esp_hidh_cb_event_t_ESP_HIDH_DATA_IND_EVT => {
            let d = p.data_ind;
            if d.status == esp_hidh_status_t_ESP_HIDH_OK
                && !d.data.is_null()
                && (1..=64).contains(&d.len)
            {
                emit(Event::Input(
                    d.handle,
                    std::slice::from_raw_parts(d.data, d.len as usize).to_vec(),
                    esp_timer_get_time() as u32,
                ));
            }
        }
        _ => {}
    }
}

fn check(result: i32, operation: &str) -> bool {
    if result == ESP_OK {
        true
    } else {
        log::warn!("{operation}: ESP error {result:#x}");
        false
    }
}
fn output(mut address: Address, mut data: Vec<u8>) {
    if !protocol::valid_output(&data) {
        return;
    }
    // send_data adds HID DATA/OUTPUT (0xA2) on the interrupt channel itself.
    check(
        unsafe { esp_bt_hid_host_send_data(address.as_mut_ptr(), data.as_mut_ptr(), data.len()) },
        "Wii output",
    );
}
fn disconnect(mut address: Address) -> bool {
    check(
        unsafe { esp_bt_hid_host_disconnect(address.as_mut_ptr()) },
        "Wii disconnect",
    )
}

fn update_player_leds(
    known: &[Option<Address>; 4],
    mask: u8,
    order: &[u8; 4],
    rumbling: &[bool; 4],
) {
    for (slot, address) in known.iter().enumerate() {
        if let (Some(address), Some(player)) =
            (*address, protocol::player_index(order, mask, slot as u8))
        {
            output(address, vec![0x11, (0x10 << player) | rumbling[slot] as u8]);
        }
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let peripherals = Peripherals::take()?;
    let nvs = EspDefaultNvsPartition::take()?;
    let storage = EspNvs::new(nvs.clone(), "wiibridge", true)?;
    // `known` is the four live BLE slot identities. `remembered` contains the
    // larger persistent HID roster, including remotes without a current slot.
    let mut known: [Option<Address>; 4] = [None; 4];
    let mut saved = [0u8; 24];
    if let Some(bytes) = storage.get_blob("remotes", &mut saved)? {
        if bytes.len() == 24 {
            for (slot, address) in bytes.chunks_exact(6).enumerate() {
                if address.iter().any(|b| *b != 0) {
                    known[slot] = Some(address.try_into()?);
                }
            }
        }
    }
    let mut remembered: [Option<Address>; protocol::MAX_REMEMBERED_REMOTES] =
        [None; protocol::MAX_REMEMBERED_REMOTES];
    let mut roster_bytes = [0u8; protocol::MAX_REMEMBERED_REMOTES * 6];
    if let Some(bytes) = storage.get_blob("roster", &mut roster_bytes)? {
        if bytes.len() == protocol::MAX_REMEMBERED_REMOTES * 6 {
            for (index, address) in bytes.chunks_exact(6).enumerate() {
                if address.iter().any(|b| *b != 0) {
                    remembered[index] = Some(address.try_into()?);
                }
            }
        }
    }
    // Existing installations stored only four slots. Keep their indices so
    // rname0...rname3 continue to refer to the same Bluetooth addresses.
    for (slot, address) in known.iter().enumerate() {
        if let Some(address) = address {
            if protocol::remembered_index(&remembered, *address).is_none() {
                let index = if remembered[slot].is_none() {
                    Some(slot)
                } else {
                    remembered.iter().position(Option::is_none)
                };
                if let Some(index) = index {
                    remembered[index] = Some(*address);
                }
            }
        }
    }
    let mut name_buffer = [0u8; 25];
    let mut bridge_name = storage
        .get_str("name", &mut name_buffer)?
        .unwrap_or("WiiBLE")
        .to_owned();
    let mut remote_names: [String; protocol::MAX_REMEMBERED_REMOTES] =
        std::array::from_fn(|_| String::new());
    for (slot, name) in remote_names.iter_mut().enumerate() {
        *name = storage
            .get_str(&format!("rname{slot}"), &mut name_buffer)?
            .unwrap_or("")
            .to_owned();
    }
    // Remembered remotes initiate their own reconnect on a normal button press.
    // Boot inquiry/paging competes with that brief wake window on the same radio.
    let first_pairing = remembered.iter().all(Option::is_none);
    let mut pairing_deadline =
        Instant::now() + Duration::from_secs(if first_pairing { 30 } else { 0 });
    let pairing = Arc::new(AtomicBool::new(first_pairing));
    let connected = Arc::new(AtomicU8::new(0));
    let (sender, receiver) = mpsc::sync_channel(256);
    let (lifecycle_sender, lifecycle_receiver) = mpsc::channel();
    LIFECYCLE
        .set(lifecycle_sender)
        .map_err(|_| "Lifecycle queue already initialized")?;
    EVENTS
        .set(sender.clone())
        .map_err(|_| "Event queue already initialized")?;
    let driver: Arc<BtDriver<'static, BtDual>> =
        Arc::new(BtDriver::new(peripherals.modem, Some(nvs))?);
    let server = ble::Server::new(
        driver.clone(),
        pairing.clone(),
        connected.clone(),
        sender,
        bridge_name.clone(),
    )?;
    esp!(unsafe { esp_bt_gap_register_callback(Some(gap_callback)) })?;
    esp!(unsafe { esp_bt_gap_set_device_name(c"WiiBLE".as_ptr()) })?;
    esp!(unsafe {
        esp_bt_gap_set_scan_mode(
            esp_bt_connection_mode_t_ESP_BT_CONNECTABLE,
            esp_bt_discovery_mode_t_ESP_BT_NON_DISCOVERABLE,
        )
    })?;
    esp!(unsafe {
        esp_bt_gap_set_pin(
            esp_bt_pin_type_t_ESP_BT_PIN_TYPE_VARIABLE,
            0,
            std::ptr::null_mut(),
        )
    })?;
    esp!(unsafe { esp_bt_hid_host_register_callback(Some(hid_callback)) })?;
    esp!(unsafe { esp_bt_hid_host_init() })?;
    let local = unsafe { std::slice::from_raw_parts(esp_bt_dev_get_address(), 6) };
    let mut pin = [0u8; 16];
    for i in 0..6 {
        pin[i] = local[5 - i];
    }
    log::info!(
        "Classic + BLE ready; {} remembered remotes",
        remembered.iter().flatten().count()
    );
    if first_pairing {
        log::info!("First pairing: press red SYNC within 30 seconds");
    } else {
        log::info!("Wake remembered remotes with A; open pairing from the app for new remotes");
    }

    let mut handles: [Option<u8>; 4] = [None; 4];
    // Player order and suspension last until reboot; roster, slot assignments,
    // and names stay in NVS.
    let mut player_order = [0u8, 1, 2, 3];
    let mut suspended = 0u8;
    let mut connect_until: [Option<Instant>; 4] = [None; 4];
    let mut rumbling = [false; 4];
    let mut authenticated = HashSet::<Address>::new();
    let mut candidates = HashSet::<Address>::new();
    let mut asked_names = HashSet::<Address>::new();
    let mut seen_discovery = HashSet::<Address>::new();
    let mut pending_name: Option<Address> = None;
    let mut reading_name = false;
    let mut pending: Option<(Address, Instant)> = None;
    let mut queued_connect: Option<Address> = None;
    let mut incoming = HashSet::<Address>::new();
    let mut pending_warned = false;
    let mut host_ready = false;
    let mut discovering = false;
    let mut last_inquiry = Instant::now() - Duration::from_secs(2);
    let mut last_reconnect = Instant::now();
    let mut reconnect_slot = 0;
    let mut sequence = 0u16;
    let mut last_status = Instant::now();
    let mut last_input = [Instant::now(); 4];
    let mut input_count = [0u32; 4];
    let mut max_input_gap = [0u128; 4];
    let mut max_queue_age = [0u32; 4];
    let mut buttons = [0u16; 4];
    let mut last_input_log = Instant::now();
    let mut restart_at: Option<Instant> = None;

    loop {
        if restart_at.is_some_and(|when| Instant::now() >= when) {
            log::info!("Restarting bridge after forgetting a remote");
            unsafe { esp_restart() };
        }
        server.poll_control();
        server.poll_input_replies();
        server.poll_samples();
        let open = Instant::now() < pairing_deadline;
        if pairing.swap(open, Ordering::Relaxed) && !open {
            if discovering {
                check(unsafe { esp_bt_gap_cancel_discovery() }, "Stop discovery");
            }
            log::info!("Pairing window closed; remembered remotes may reconnect at any time");
            server.update_status();
        }
        if let Ok(event) = lifecycle_receiver
            .try_recv()
            .or_else(|_| receiver.recv_timeout(Duration::from_millis(5)))
        {
            match event {
                Event::HostReady(status) => {
                    if status != esp_hidh_status_t_ESP_HIDH_OK {
                        return Err(format!("HID host init failed: {status}").into());
                    }
                    host_ready = true;
                    pending = None;
                    incoming.clear();
                    pending_warned = false;
                }
                Event::HostStopped(status) => {
                    if status != esp_hidh_status_t_ESP_HIDH_OK {
                        return Err(format!("HID host recovery failed: {status}").into());
                    }
                    esp!(unsafe { esp_bt_hid_host_init() })?;
                }
                Event::Acl(addr, up, status) => {
                    log::info!("Classic ACL {addr:02x?}: up={up} status={status}");
                    if up && status == esp_bt_status_t_ESP_BT_STATUS_SUCCESS {
                        let ready = known
                            .iter()
                            .position(|a| *a == Some(addr))
                            .is_some_and(|slot| handles[slot].is_some());
                        if !ready {
                            incoming.insert(addr);
                        }
                        if discovering {
                            check(
                                unsafe { esp_bt_gap_cancel_discovery() },
                                "Pause inquiry for incoming remote",
                            );
                        }
                    } else {
                        incoming.remove(&addr);
                    }
                }
                Event::Discovered(addr, device_name, hid) if open => {
                    if pending_name == Some(addr) && !device_name.is_empty() {
                        pending_name = None;
                        reading_name = false;
                    }
                    if seen_discovery.insert(addr) {
                        log::info!(
                            "Pairing discovery {addr:02x?}: name={device_name:?}, hid={hid}"
                        );
                    }
                    if device_name.is_empty()
                        && hid
                        && pending_name.is_none()
                        && asked_names.len() < 16
                        && asked_names.insert(addr)
                    {
                        pending_name = Some(addr);
                        if discovering {
                            check(
                                unsafe { esp_bt_gap_cancel_discovery() },
                                "Pause inquiry for Wii name",
                            );
                        }
                    } else if is_wii(&device_name) {
                        if candidates.len() < 8 {
                            candidates.insert(addr);
                        }
                        let already_remembered =
                            protocol::remembered_index(&remembered, addr).is_some();
                        let room_to_pair = remembered.iter().any(Option::is_none);
                        if (already_remembered || room_to_pair)
                            && protocol::available_remote_slot(
                                &known,
                                addr,
                                connected.load(Ordering::Relaxed),
                                suspended,
                            )
                            .is_some()
                            && pending.is_none()
                            && host_ready
                            && queued_connect.is_none()
                        {
                            log::info!("Queue discovered Wii {addr:02x?} for HID connect");
                            queued_connect = Some(addr);
                            if discovering {
                                check(unsafe { esp_bt_gap_cancel_discovery() }, "Pause inquiry");
                            }
                        }
                    }
                }
                Event::RemoteNameFailed(addr, status) => {
                    log::warn!("Pairing remote-name read failed for {addr:02x?}: status={status}");
                    if pending_name == Some(addr) {
                        pending_name = None;
                        reading_name = false;
                    }
                }
                Event::DiscoveryStopped => {
                    discovering = false;
                    if open {
                        log::info!("Pairing inquiry stopped");
                    }
                }
                Event::Pin(mut addr, min16) => {
                    let remembered_remote = protocol::remembered_index(&remembered, addr).is_some();
                    let candidate = candidates.contains(&addr);
                    let roster_room = remembered.iter().any(Option::is_none);
                    let slot = protocol::available_remote_slot(
                        &known,
                        addr,
                        connected.load(Ordering::Relaxed),
                        suspended,
                    );
                    let allowed = !min16
                        && (remembered_remote || (open && candidate && roster_room))
                        && slot.is_some();
                    log::info!(
                        "Wii PIN {addr:02x?}: allowed={allowed}, pairing={open}, candidate={candidate}, remembered={remembered_remote}, roster_room={roster_room}, slot={slot:?}, min16={min16}"
                    );
                    check(
                        unsafe {
                            esp_bt_gap_pin_reply(
                                addr.as_mut_ptr(),
                                allowed,
                                if allowed { 6 } else { 0 },
                                pin.as_mut_ptr(),
                            )
                        },
                        "Wii PIN reply",
                    );
                }
                Event::Auth(addr, status) => {
                    if status == esp_bt_status_t_ESP_BT_STATUS_SUCCESS {
                        authenticated.insert(addr);
                        log::info!("Wii authentication succeeded for {addr:02x?}");
                    } else {
                        log::warn!("Wii authentication failed: {status}; use red SYNC, not 1+2");
                    }
                }
                Event::LinkMode(addr, mode, interval) => {
                    log::info!(
                        "Classic link {addr:02x?}: mode={mode}, interval={} us",
                        u32::from(interval) * 625
                    );
                }
                Event::Open(addr, handle, status, connection_state) => {
                    log::info!("HID open addr={addr:02x?} handle={handle} status={status} state={connection_state}");
                    // ESP-IDF emits OPEN both when a request is queued (handle 0xff)
                    // and when HID is actually connected. Never publish the first as ready.
                    if connection_state
                        == esp_hidh_connection_state_t_ESP_HIDH_CONN_STATE_CONNECTING
                    {
                        continue;
                    }
                    incoming.remove(&addr);
                    if queued_connect == Some(addr) {
                        queued_connect = None;
                    }
                    // BUSY is rejection of this request, not completion of the
                    // stack's other in-flight request. Never invent cancellation.
                    if pending.map(|p| p.0) == Some(addr) {
                        pending = None;
                        pending_warned = false;
                        last_reconnect = Instant::now();
                    }
                    if status != esp_hidh_status_t_ESP_HIDH_OK
                        || connection_state
                            != esp_hidh_connection_state_t_ESP_HIDH_CONN_STATE_CONNECTED
                    {
                        log::warn!("Wii HID open failed: {status}");
                        continue;
                    }
                    // The SDK also returns CONNECTED with handle 0xff for an
                    // already-connected connect request. This is not a new link.
                    if handle == u8::MAX {
                        log::warn!("Ignoring HID open without a valid handle for {addr:02x?}");
                        continue;
                    }
                    if handles
                        .iter()
                        .position(|h| *h == Some(handle))
                        .is_some_and(|slot| known[slot] == Some(addr))
                    {
                        continue; // Do not reset report mode/IR on a duplicate OPEN.
                    }
                    let remembered_index = protocol::remembered_index(&remembered, addr);
                    let allowed = remembered_index.is_some()
                        || (open
                            && candidates.contains(&addr)
                            && authenticated.contains(&addr)
                            && remembered.iter().any(Option::is_none));
                    let slot = protocol::available_remote_slot(
                        &known,
                        addr,
                        connected.load(Ordering::Relaxed),
                        suspended,
                    );
                    if !allowed || slot.is_none() {
                        log::warn!(
                            "Reject Wii HID {addr:02x?}: allowed={allowed}, slot={slot:?}, pairing={open}, candidate={}, authenticated={}",
                            candidates.contains(&addr),
                            authenticated.contains(&addr)
                        );
                        disconnect(addr);
                        continue;
                    }
                    let slot = slot.unwrap();
                    if remembered_index.is_none() {
                        let index = remembered.iter().position(Option::is_none).unwrap();
                        remembered[index] = Some(addr);
                        let bytes: Vec<u8> = remembered
                            .iter()
                            .flat_map(|a| a.unwrap_or([0; 6]))
                            .collect();
                        storage.set_blob("roster", &bytes)?;
                    }
                    if known[slot] != Some(addr) {
                        known[slot] = Some(addr);
                        let bytes: Vec<u8> =
                            known.iter().flat_map(|a| a.unwrap_or([0; 6])).collect();
                        storage.set_blob("remotes", &bytes)?;
                    }
                    server.clear_remote_reports(slot as u8);
                    handles[slot] = Some(handle);
                    connect_until[slot] = None;
                    last_input[slot] = Instant::now();
                    input_count[slot] = 0;
                    max_input_gap[slot] = 0;
                    buttons[slot] = 0;
                    rumbling[slot] = false;
                    protocol::assign_player(
                        &mut player_order,
                        connected.load(Ordering::Relaxed),
                        slot as u8,
                    );
                    server.set_player_order(&player_order);
                    connected.fetch_or(1 << slot, Ordering::Relaxed);
                    update_player_leds(
                        &known,
                        connected.load(Ordering::Relaxed),
                        &player_order,
                        &rumbling,
                    );
                    output(addr, vec![0x12, 4, 0x31]); // Buttons + accelerometer until app selects another mode.
                    output(addr, vec![0x15, 0]);
                    server.update_status();
                    log::info!("Wii Remote ready in slot {slot}");
                }
                Event::Close(handle, status, state) => {
                    log::info!("HID close handle={handle} status={status} state={state}");
                    if status != esp_hidh_status_t_ESP_HIDH_OK
                        || state != esp_hidh_connection_state_t_ESP_HIDH_CONN_STATE_DISCONNECTED
                    {
                        continue;
                    }
                    if let Some(slot) = handles.iter().position(|h| *h == Some(handle)) {
                        handles[slot] = None;
                        server.clear_remote_reports(slot as u8);
                        connected.fetch_and(!(1 << slot), Ordering::Relaxed);
                        update_player_leds(
                            &known,
                            connected.load(Ordering::Relaxed),
                            &player_order,
                            &rumbling,
                        );
                        server.update_status();
                        log::info!("Wii Remote disconnected from slot {slot}");
                    }
                }
                Event::Input(handle, data, timestamp) => {
                    if let Some(slot) = handles.iter().position(|h| *h == Some(handle)) {
                        let age = (unsafe { esp_timer_get_time() } as u32).wrapping_sub(timestamp);
                        max_queue_age[slot] = max_queue_age[slot].max(age);
                        let gap = last_input[slot].elapsed().as_millis();
                        last_input[slot] = Instant::now();
                        max_input_gap[slot] = max_input_gap[slot].max(gap);
                        input_count[slot] += 1;
                        if data.len() >= 3 {
                            let pressed = u16::from_le_bytes([data[1], data[2]]) & !0x60e0;
                            if pressed != buttons[slot] {
                                log::info!(
                                    "Input slot {slot}: buttons={pressed:04x}, report gap={gap} ms"
                                );
                                buttons[slot] = pressed;
                            }
                        }
                        server.send_report(slot as u8, sequence, &data, timestamp);
                        sequence = sequence.wrapping_add(1);
                    }
                }
                Event::Output(slot, data) if slot < 4 && handles[slot as usize].is_some() => {
                    if let Some(addr) = known[slot as usize] {
                        rumbling[slot as usize] = data[1] & 1 != 0;
                        output(addr, data);
                    }
                }
                Event::Control(generation, data) if server.control_connected(generation) => {
                    use protocol::ControlCommand;
                    if let Some((request, command)) = protocol::control_command(&data) {
                        log::info!("Management request {request}, opcode {}", data[3]);
                        let mut result = 0;
                        let mut payload = Vec::new();
                        match command {
                            ControlCommand::Pair => {
                                pairing_deadline = Instant::now() + Duration::from_secs(30);
                                pairing.store(true, Ordering::Relaxed);
                                asked_names.clear();
                                candidates.clear();
                                seen_discovery.clear();
                                pending_name = None;
                                reading_name = false;
                                server.update_status();
                                log::info!("Pairing window opened by BLE consumer for 30 seconds");
                            }
                            ControlCommand::PlayerState => {
                                payload.extend_from_slice(&player_order);
                                payload.push(suspended);
                            }
                            ControlCommand::PlayerOrder(order) => {
                                player_order = order;
                                server.set_player_order(&player_order);
                                update_player_leds(
                                    &known,
                                    connected.load(Ordering::Relaxed),
                                    &player_order,
                                    &rumbling,
                                );
                                payload.extend_from_slice(&player_order);
                                payload.push(suspended);
                                log::info!("Player order changed: {player_order:?}");
                            }
                            ControlCommand::Disconnect(target, address) => {
                                if known[target as usize] != Some(address) {
                                    result = 2;
                                } else {
                                    suspended |= 1 << target;
                                    connect_until[target as usize] = None;
                                    if handles[target as usize].is_some() {
                                        output(address, vec![0x10, 0]);
                                        if !disconnect(address) {
                                            suspended &= !(1 << target);
                                            server.control_reply(
                                                generation,
                                                &protocol::control_reply(&data, 4, &[]),
                                            );
                                            continue;
                                        }
                                        rumbling[target as usize] = false;
                                        server.clear_remote_reports(target);
                                        handles[target as usize] = None;
                                        connected.fetch_and(!(1 << target), Ordering::Relaxed);
                                        update_player_leds(
                                            &known,
                                            connected.load(Ordering::Relaxed),
                                            &player_order,
                                            &rumbling,
                                        );
                                    }
                                    // Reject any in-flight or remote-initiated reopen until Connect.
                                    server.update_status();
                                    log::info!("Remote slot {target} disconnected by app");
                                }
                            }
                            ControlCommand::Connect(target, address) => {
                                if known[target as usize] != Some(address) {
                                    result = 2;
                                } else {
                                    suspended &= !(1 << target);
                                    connect_until[target as usize] =
                                        Some(Instant::now() + Duration::from_secs(30));
                                    reconnect_slot = target as usize;
                                    last_reconnect = Instant::now() - Duration::from_secs(4);
                                }
                            }
                            ControlCommand::PowerOff(target, address) => {
                                let slot = target as usize;
                                if known[slot] != Some(address) || handles[slot].is_none() {
                                    result = 2;
                                } else if !disconnect(address) {
                                    result = 4;
                                } else {
                                    // The emulated Wii ended its link. Release the physical
                                    // HID link too, but keep the bond and allow button wake.
                                    connect_until[slot] = None;
                                    rumbling[slot] = false;
                                    server.clear_remote_reports(target);
                                    handles[slot] = None;
                                    connected.fetch_and(!(1 << target), Ordering::Relaxed);
                                    server.update_status();
                                    log::info!("Wii Remote in slot {target} powered off by emulated software");
                                }
                            }
                            ControlCommand::Info(target) => {
                                if target == protocol::BRIDGE_TARGET {
                                    payload.push(target);
                                    payload.extend_from_slice(&[0; 6]);
                                    payload.extend_from_slice(bridge_name.as_bytes());
                                } else if let Some(address) = known[target as usize] {
                                    payload.push(target);
                                    payload.extend_from_slice(&address);
                                    let index = protocol::remembered_index(&remembered, address)
                                        .expect("assigned remote must be remembered");
                                    let name = &remote_names[index];
                                    let fallback = format!("Wii Remote {}", index + 1);
                                    payload.extend_from_slice(if name.is_empty() {
                                        fallback.as_bytes()
                                    } else {
                                        name.as_bytes()
                                    });
                                } else {
                                    result = 2;
                                }
                            }
                            ControlCommand::Remembered(index) => {
                                if let Some(address) = remembered[index as usize] {
                                    payload.push(index);
                                    payload.push(
                                        known
                                            .iter()
                                            .position(|slot| *slot == Some(address))
                                            .map(|slot| slot as u8)
                                            .unwrap_or(u8::MAX),
                                    );
                                    payload.extend_from_slice(&address);
                                    let name = &remote_names[index as usize];
                                    let fallback = format!("Wii Remote {}", index + 1);
                                    payload.extend_from_slice(if name.is_empty() {
                                        fallback.as_bytes()
                                    } else {
                                        name.as_bytes()
                                    });
                                } else {
                                    result = 2;
                                }
                            }
                            ControlCommand::Forget(index, address) => {
                                if remembered[index as usize] != Some(address) {
                                    result = 2;
                                } else {
                                    let mut removed = remembered;
                                    removed[index as usize] = None;
                                    let roster_bytes: Vec<u8> = removed
                                        .iter()
                                        .flat_map(|entry| entry.unwrap_or([0; 6]))
                                        .collect();
                                    let mut assigned = known;
                                    for slot in &mut assigned {
                                        if *slot == Some(address) {
                                            *slot = None;
                                        }
                                    }
                                    let slot_bytes: Vec<u8> = assigned
                                        .iter()
                                        .flat_map(|entry| entry.unwrap_or([0; 6]))
                                        .collect();
                                    let mut bond_address = address;
                                    if !check(
                                        unsafe {
                                            esp_bt_gap_remove_bond_device(bond_address.as_mut_ptr())
                                        },
                                        "Forget Wii bond",
                                    ) || storage.set_blob("roster", &roster_bytes).is_err()
                                        || storage.set_blob("remotes", &slot_bytes).is_err()
                                        || storage.remove(&format!("rname{index}")).is_err()
                                    {
                                        result = 3;
                                    } else {
                                        log::info!(
                                            "Forgot Wii Remote {address:02x?}; bridge will restart"
                                        );
                                        restart_at = Some(Instant::now() + Duration::from_secs(3));
                                    }
                                }
                            }
                            ControlCommand::RenameRemembered(index, address, name) => {
                                if remembered[index as usize] != Some(address) {
                                    result = 2;
                                } else if storage.set_str(&format!("rname{index}"), &name).is_ok() {
                                    remote_names[index as usize] = name;
                                } else {
                                    result = 3;
                                }
                            }
                            ControlCommand::Rename(target, address, name) => {
                                if target == protocol::BRIDGE_TARGET && address == [0; 6] {
                                    if storage.set_str("name", &name).is_ok() {
                                        server.set_name(&name);
                                        bridge_name = name;
                                    } else {
                                        result = 3;
                                    }
                                } else if target < 4 && known[target as usize] == Some(address) {
                                    let index = protocol::remembered_index(&remembered, address)
                                        .expect("assigned remote must be remembered");
                                    if storage.set_str(&format!("rname{index}"), &name).is_ok() {
                                        remote_names[index] = name;
                                    } else {
                                        result = 3;
                                    }
                                } else {
                                    result = 2;
                                }
                            }
                        }
                        server.control_reply(
                            generation,
                            &protocol::control_reply(&data, result, &payload),
                        );
                    }
                }
                Event::BleDisconnected => {
                    for slot in 0..4 {
                        if handles[slot].is_some() {
                            if let Some(addr) = known[slot] {
                                output(addr, vec![0x10, 0]);
                                rumbling[slot] = false;
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        server.poll_control();
        server.poll_input_replies();
        server.poll_samples();
        if open && !discovering && !reading_name {
            if let Some(mut addr) = pending_name {
                if check(
                    unsafe { esp_bt_gap_read_remote_name(addr.as_mut_ptr()) },
                    "Read Wii name after inquiry",
                ) {
                    log::info!("Reading Wii name after inquiry for {addr:02x?}");
                    reading_name = true;
                } else {
                    pending_name = None;
                }
            }
        }
        if last_input_log.elapsed() >= Duration::from_secs(5) {
            for slot in 0..4 {
                if handles[slot].is_some() {
                    log::info!(
                        "Input slot {slot}: {} reports/5s, max gap={} ms, max queue age={} us",
                        input_count[slot],
                        max_input_gap[slot],
                        max_queue_age[slot]
                    );
                }
            }
            input_count = [0; 4];
            max_input_gap = [0; 4];
            max_queue_age = [0; 4];
            server.log_input_stats();
            log::info!(
                "Free heap={} minimum={}",
                unsafe { esp_get_free_heap_size() },
                unsafe { esp_get_minimum_free_heap_size() }
            );
            last_input_log = Instant::now();
        }
        if pending.is_some_and(|(_, when)| when.elapsed() > Duration::from_secs(12))
            && !pending_warned
        {
            log::warn!("HID connect is slow; waiting for stack completion (disconnect cannot cancel an open)");
            pending_warned = true;
        }
        // A stuck host can be restarted without rebooting BLE or erasing bonds.
        // Never do this with a healthy HID connection: other players keep playing.
        if host_ready
            && connected.load(Ordering::Relaxed) == 0
            && pending.is_some_and(|(_, when)| when.elapsed() > Duration::from_secs(45))
            && check(unsafe { esp_bt_hid_host_deinit() }, "Recover idle HID host")
        {
            host_ready = false;
            queued_connect = None;
            log::warn!("Recovering stalled HID host; keeping BLE and saved bonds");
        }
        if host_ready && !discovering && pending.is_none() && incoming.is_empty() {
            if let Some(mut addr) = queued_connect.take() {
                if (open || protocol::remembered_index(&remembered, addr).is_some())
                    && check(
                        unsafe { esp_bt_hid_host_connect(addr.as_mut_ptr()) },
                        "Connect discovered Wii",
                    )
                {
                    pending = Some((addr, Instant::now()));
                    pending_warned = false;
                }
            }
        }
        if open
            && host_ready
            && !discovering
            && pending.is_none()
            && queued_connect.is_none()
            && pending_name.is_none()
            && incoming.is_empty()
            && last_inquiry.elapsed() > Duration::from_secs(1)
        {
            discovering = check(
                unsafe {
                    esp_bt_gap_start_discovery(
                        esp_bt_inq_mode_t_ESP_BT_INQ_MODE_GENERAL_INQUIRY,
                        4,
                        0,
                    )
                },
                "Start inquiry",
            );
            if discovering {
                log::info!("Pairing inquiry started");
            }
            last_inquiry = Instant::now();
        }
        if !open
            && host_ready
            && pending.is_none()
            && !discovering
            && incoming.is_empty()
            && last_reconnect.elapsed() > Duration::from_secs(3)
        {
            let slot = reconnect_slot;
            reconnect_slot = (reconnect_slot + 1) % 4;
            // Normal wake is remote-initiated. Page only on explicit app request;
            // background paging an asleep peer competes with other wake attempts.
            let active_connect = connect_until[slot].is_some_and(|until| Instant::now() < until);
            if protocol::should_page(
                connected.load(Ordering::Relaxed),
                suspended,
                slot as u8,
                active_connect,
            ) {
                if let Some(mut addr) = known[slot] {
                    if check(
                        unsafe { esp_bt_hid_host_connect(addr.as_mut_ptr()) },
                        "Reconnect Wii",
                    ) {
                        pending = Some((addr, Instant::now()));
                    }
                }
            }
            last_reconnect = Instant::now();
        }
        if last_status.elapsed() > Duration::from_secs(1) {
            // Repeat the current status so a congested/lost notification cannot leave stale slot state.
            server.update_status();
            let dropped = DROPPED.swap(0, Ordering::Relaxed);
            if dropped > 0 {
                log::warn!("Dropped {dropped} Bluetooth events (queue full)");
            }
            last_status = Instant::now();
        }
    }
}

fn main() {
    esp_idf_svc::sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();
    if let Err(error) = run() {
        log::error!("Bridge stopped: {error}");
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    }
}
