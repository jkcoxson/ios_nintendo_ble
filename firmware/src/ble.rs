use crate::{
    protocol::{self, InputReplies, Reassembler, Samples},
    Event,
};
use enumset::enum_set;
use esp_idf_svc::{
    bt::ble::{
        gap::{AdvConfiguration, BleGapEvent, EspBleGap},
        gatt::{
            server::{EspGatts, GattsEvent},
            set_local_mtu, AutoResponse, GattCharacteristic, GattDescriptor, GattId, GattResponse,
            GattServiceId, GattStatus, Permission, Property,
        },
    },
    bt::{BtDriver, BtDual, BtStatus, BtUuid},
    sys::{esp_ble_get_cur_sendable_packets_num, EspError, ESP_FAIL},
};
use std::collections::VecDeque;
use std::sync::{
    atomic::{AtomicBool, AtomicU8, Ordering},
    mpsc::SyncSender,
    Arc, Mutex,
};

const SERVICE: u128 = 0x7b9c00019c2a4b3da91f8f4e62d4c001;
const INPUT: u128 = 0x7b9c00029c2a4b3da91f8f4e62d4c001;
const OUTPUT: u128 = 0x7b9c00039c2a4b3da91f8f4e62d4c001;
const CAPABILITIES: u128 = 0x7b9c00069c2a4b3da91f8f4e62d4c001;
const CONTROL: u128 = 0x7b9c00059c2a4b3da91f8f4e62d4c001;
const STATUS: u128 = 0x7b9c00049c2a4b3da91f8f4e62d4c001;
type Driver = Arc<BtDriver<'static, BtDual>>;
type Gap = Arc<EspBleGap<'static, BtDual, Driver>>;
type Gatts = Arc<EspGatts<'static, BtDual, Driver>>;

#[derive(Debug, Default, Clone, Copy)]
struct InputStats {
    received: u32,
    sent: u32,
    notify_failed: u32,
    expired: u32,
    overflow: u32,
}

#[derive(Default)]
struct State {
    interface: u8,
    service: u16,
    input: u16,
    output: u16,
    status: u16,
    control: u16,
    capabilities: u16,
    control_cccd: u16,
    control_subscribed: bool,
    control_rx: Reassembler,
    control_tx: VecDeque<Vec<u8>>,
    control_inflight: bool,
    input_replies: InputReplies,
    generation: u32,
    input_cccd: u16,
    status_cccd: u16,
    connection: Option<u16>,
    input_subscribed: bool,
    status_subscribed: bool,
    congested: bool,
    mtu: u16,
    input_mode: u8,
    extended_status: bool,
    rx: Reassembler,
    stats: [InputStats; 4],
    samples: Samples,
}

#[derive(Clone)]
pub struct Server {
    gap: Gap,
    gatt: Gatts,
    state: Arc<Mutex<State>>,
    pairing: Arc<AtomicBool>,
    connected: Arc<AtomicU8>,
    players: Arc<AtomicU8>,
    events: SyncSender<Event>,
    name: Arc<Mutex<String>>,
}

impl Server {
    pub fn new(
        driver: Driver,
        pairing: Arc<AtomicBool>,
        connected: Arc<AtomicU8>,
        events: SyncSender<Event>,
        name: String,
    ) -> Result<Self, EspError> {
        let server = Self {
            gap: Arc::new(EspBleGap::new(driver.clone())?),
            gatt: Arc::new(EspGatts::new(driver)?),
            state: Arc::new(Mutex::new(State::default())),
            pairing,
            connected,
            players: Arc::new(AtomicU8::new(protocol::pack_players(&[0, 1, 2, 3]))),
            events,
            name: Arc::new(Mutex::new(name)),
        };
        let s = server.clone();
        server.gap.subscribe(move |event| match event {
            BleGapEvent::AdvertisingConfigured(BtStatus::Success) => {
                s.check(s.gap.set_adv_conf(&AdvConfiguration {
                    set_scan_rsp: true,
                    include_name: true,
                    include_txpower: false,
                    ..Default::default()
                }));
            }
            BleGapEvent::ScanResponseConfigured(BtStatus::Success) => {
                if s.state.lock().unwrap().connection.is_none() {
                    s.check(s.gap.start_advertising());
                }
            }
            BleGapEvent::ConnectionParamsConfigured {
                status, conn_int, ..
            } => {
                log::info!(
                    "BLE interval: {} us, status={status:?}",
                    u32::from(conn_int) * 1250
                );
            }
            BleGapEvent::PacketLengthConfigured { tx_len, rx_len, .. } => {
                log::info!("BLE data length: tx={tx_len}, rx={rx_len}");
            }
            _ => {}
        })?;
        let s = server.clone();
        server
            .gatt
            .subscribe(move |(interface, event)| s.check(s.event(interface, event)))?;
        set_local_mtu(185)?;
        server.gatt.register_app(0)?;
        Ok(server)
    }

    fn check(&self, result: Result<(), EspError>) {
        if let Err(error) = result {
            log::error!("BLE: {error}");
        }
    }
    fn ok(status: GattStatus) -> Result<(), EspError> {
        if status == GattStatus::Ok {
            Ok(())
        } else {
            log::error!("GATT status: {status:?}");
            Err(EspError::from_infallible::<ESP_FAIL>())
        }
    }
    pub fn set_player_order(&self, order: &[u8; 4]) {
        self.players
            .store(protocol::pack_players(order), Ordering::Relaxed);
    }
    fn status_value(&self, extended: bool) -> Vec<u8> {
        let mut value = vec![
            1,
            self.pairing.load(Ordering::Relaxed) as u8,
            self.connected.load(Ordering::Relaxed),
        ];
        if extended {
            value.extend(protocol::unpack_players(
                self.players.load(Ordering::Relaxed),
            ));
        }
        value
    }
    fn advertise(&self) -> Result<(), EspError> {
        self.gap.set_device_name(&self.name.lock().unwrap())?;
        self.gap.set_adv_conf(&AdvConfiguration {
            include_name: false,
            include_txpower: false,
            flag: 2,
            service_uuid: Some(BtUuid::uuid128(SERVICE)),
            ..Default::default()
        })
    }
    fn add_char(&self, service: u16, uuid: u128) -> Result<(), EspError> {
        let (permissions, properties, max_len) = match uuid {
            CAPABILITIES => (
                enum_set!(Permission::Read | Permission::Write),
                enum_set!(Property::Read | Property::Write),
                1,
            ),
            INPUT => (
                enum_set!(Permission::Read),
                enum_set!(Property::Notify),
                182,
            ),
            CONTROL => (
                enum_set!(Permission::Write),
                enum_set!(Property::Write | Property::Indicate),
                20,
            ),
            OUTPUT => (enum_set!(Permission::Write), enum_set!(Property::Write), 20),
            _ => (
                enum_set!(Permission::Read),
                enum_set!(Property::Read | Property::Notify),
                7,
            ),
        };
        self.gatt.add_characteristic(
            service,
            &GattCharacteristic {
                uuid: BtUuid::uuid128(uuid),
                permissions,
                properties,
                max_len,
                auto_rsp: AutoResponse::ByApp,
            },
            &[],
        )
    }
    fn add_cccd(&self, service: u16) -> Result<(), EspError> {
        self.gatt.add_descriptor(
            service,
            &GattDescriptor {
                uuid: BtUuid::uuid16(0x2902),
                permissions: enum_set!(Permission::Read | Permission::Write),
            },
        )
    }

    fn event(&self, interface: u8, event: GattsEvent) -> Result<(), EspError> {
        match event {
            GattsEvent::ServiceRegistered { status, .. } => {
                Self::ok(status)?;
                self.state.lock().unwrap().interface = interface;
                self.gatt.create_service(
                    interface,
                    &GattServiceId {
                        id: GattId {
                            uuid: BtUuid::uuid128(SERVICE),
                            inst_id: 0,
                        },
                        is_primary: true,
                    },
                    16,
                )?;
            }
            GattsEvent::ServiceCreated {
                status,
                service_handle,
                ..
            } => {
                Self::ok(status)?;
                self.state.lock().unwrap().service = service_handle;
                self.add_char(service_handle, INPUT)?;
            }
            GattsEvent::CharacteristicAdded {
                status,
                attr_handle,
                service_handle,
                char_uuid,
            } => {
                Self::ok(status)?;
                if char_uuid == BtUuid::uuid128(CAPABILITIES) {
                    self.state.lock().unwrap().capabilities = attr_handle;
                    self.gatt.start_service(service_handle)?;
                    self.advertise()?;
                    log::info!("WiiBLE GATT service ready (player control supported)");
                } else if char_uuid == BtUuid::uuid128(INPUT) {
                    self.state.lock().unwrap().input = attr_handle;
                    self.add_cccd(service_handle)?;
                } else if char_uuid == BtUuid::uuid128(OUTPUT) {
                    self.state.lock().unwrap().output = attr_handle;
                    self.add_char(service_handle, STATUS)?;
                } else if char_uuid == BtUuid::uuid128(CONTROL) {
                    self.state.lock().unwrap().control = attr_handle;
                    self.add_cccd(service_handle)?;
                } else if char_uuid == BtUuid::uuid128(STATUS) {
                    self.state.lock().unwrap().status = attr_handle;
                    self.add_cccd(service_handle)?;
                }
            }
            GattsEvent::DescriptorAdded {
                status,
                attr_handle,
                service_handle,
                ..
            } => {
                Self::ok(status)?;
                let next = {
                    let mut state = self.state.lock().unwrap();
                    if state.input_cccd == 0 {
                        state.input_cccd = attr_handle;
                        Some(OUTPUT)
                    } else if state.status_cccd == 0 {
                        state.status_cccd = attr_handle;
                        Some(CONTROL)
                    } else {
                        state.control_cccd = attr_handle;
                        None
                    }
                };
                if let Some(uuid) = next {
                    self.add_char(service_handle, uuid)?;
                } else {
                    self.add_char(service_handle, CAPABILITIES)?;
                }
            }
            GattsEvent::PeerConnected { conn_id, addr, .. } => {
                let mut s = self.state.lock().unwrap();
                s.connection = Some(conn_id);
                s.generation = s.generation.wrapping_add(1);
                s.input_subscribed = false;
                s.status_subscribed = false;
                s.control_subscribed = false;
                s.control_rx = Reassembler::default();
                s.control_tx.clear();
                s.input_replies = InputReplies::default();
                s.samples = Samples::default();
                s.control_inflight = false;
                s.congested = false;
                s.mtu = 23;
                s.input_mode = 0;
                s.extended_status = false;
                s.rx = Reassembler::default();
                drop(s);
                log::info!("BLE consumer connected");
                // Apple's accessory guideline-compatible minimum interval: 15 ms.
                self.gap.set_conn_params_conf(addr, 15, 30, 0, 4000)?;
            }
            GattsEvent::PeerDisconnected { reason, .. } => {
                let mut s = self.state.lock().unwrap();
                s.connection = None;
                s.input_subscribed = false;
                s.status_subscribed = false;
                s.control_subscribed = false;
                s.control_rx = Reassembler::default();
                s.control_tx.clear();
                s.input_replies = InputReplies::default();
                s.samples = Samples::default();
                s.control_inflight = false;
                s.rx = Reassembler::default();
                drop(s);
                let _ = self.events.try_send(Event::BleDisconnected);
                log::info!("BLE consumer disconnected: {reason:?}");
                self.advertise()?;
            }
            GattsEvent::Confirm {
                conn_id,
                handle,
                status,
                ..
            } => {
                let mut s = self.state.lock().unwrap();
                if s.connection == Some(conn_id) && handle == s.control && s.control_inflight {
                    s.control_inflight = false;
                    if status == GattStatus::Ok {
                        s.control_tx.pop_front();
                    } else {
                        log::warn!("Management indication failed: {status:?}");
                    }
                }
            }
            GattsEvent::Mtu { conn_id, mtu } => {
                let mut s = self.state.lock().unwrap();
                if s.connection == Some(conn_id) {
                    s.mtu = mtu;
                }
                log::info!("BLE MTU: {mtu}");
            }
            GattsEvent::Congest { congested, .. } => {
                self.state.lock().unwrap().congested = congested
            }
            GattsEvent::Read {
                conn_id,
                trans_id,
                handle,
                offset,
                need_rsp,
                ..
            } => {
                if need_rsp {
                    let s = self.state.lock().unwrap();
                    let value = if handle == s.status {
                        self.status_value(s.extended_status)
                    } else if handle == s.capabilities {
                        vec![31] // Player controls, wide, timestamps, batching, stable player status.
                    } else if handle == s.control_cccd {
                        vec![if s.control_subscribed { 2 } else { 0 }, 0]
                    } else if handle == s.input_cccd {
                        vec![s.input_subscribed as u8, 0]
                    } else if handle == s.status_cccd {
                        vec![s.status_subscribed as u8, 0]
                    } else {
                        vec![]
                    };
                    let status = if value.is_empty() {
                        GattStatus::ReadNotPermitted
                    } else if offset as usize > value.len() {
                        GattStatus::InvalidOffset
                    } else {
                        GattStatus::Ok
                    };
                    let mut response = GattResponse::new();
                    if status == GattStatus::Ok {
                        response
                            .attr_handle(handle)
                            .offset(offset)
                            .value(&value[offset as usize..])
                            .unwrap();
                    }
                    self.gatt.send_response(
                        interface,
                        conn_id,
                        trans_id,
                        status,
                        if status == GattStatus::Ok {
                            Some(&response)
                        } else {
                            None
                        },
                    )?;
                }
            }
            GattsEvent::Write {
                conn_id,
                trans_id,
                handle,
                offset,
                need_rsp,
                is_prep,
                value,
                ..
            } => {
                let status = self.write(conn_id, handle, offset, is_prep, value);
                if need_rsp {
                    self.gatt
                        .send_response(interface, conn_id, trans_id, status, None)?;
                }
            }
            GattsEvent::ExecWrite {
                conn_id, trans_id, ..
            } => {
                self.gatt.send_response(
                    interface,
                    conn_id,
                    trans_id,
                    GattStatus::ReqNotSupported,
                    None,
                )?;
            }
            _ => {}
        }
        Ok(())
    }

    fn write(
        &self,
        conn_id: u16,
        handle: u16,
        offset: u16,
        prep: bool,
        value: &[u8],
    ) -> GattStatus {
        if prep {
            return GattStatus::ReqNotSupported;
        }
        if offset != 0 {
            return GattStatus::InvalidOffset;
        }
        let mut s = self.state.lock().unwrap();
        if s.connection != Some(conn_id) {
            return GattStatus::InsufficientAuthorization;
        }
        if handle == s.capabilities {
            if value.len() != 1 || value[0] & !0x83 != 0 {
                return GattStatus::InvalidPdu;
            }
            s.input_mode = value[0] & 3;
            s.extended_status = value[0] & 0x80 != 0;
            log::info!("BLE input mode: {}, MTU={}", s.input_mode, s.mtu);
        } else if handle == s.input_cccd || handle == s.status_cccd || handle == s.control_cccd {
            let enabled = if handle == s.control_cccd {
                [2, 0]
            } else {
                [1, 0]
            };
            if value != [0, 0] && value != enabled {
                return GattStatus::InvalidPdu;
            }
            if handle == s.input_cccd {
                s.input_subscribed = value[0] == 1;
            } else if handle == s.status_cccd {
                s.status_subscribed = value[0] == 1;
            } else {
                s.control_subscribed = value[0] == 2;
            }
        } else if handle == s.control {
            if !s.control_subscribed || value.first() != Some(&0) {
                return GattStatus::InvalidPdu;
            }
            if let Some((_, data)) = s.control_rx.receive(value) {
                if protocol::control_command(&data).is_none() {
                    return GattStatus::InvalidPdu;
                }
                if self
                    .events
                    .try_send(Event::Control(s.generation, data))
                    .is_err()
                {
                    return GattStatus::InsufficientResource;
                }
            } else if value.get(3).is_some_and(|v| v & 0x80 != 0) {
                return GattStatus::InvalidPdu;
            }
        } else if handle == s.output {
            if !(5..=20).contains(&value.len())
                || value[0] >= 4
                || value[3] & 0x7f >= 4
                || (value[3] & 0x80 == 0 && value.len() != 20)
            {
                s.rx = Reassembler::default();
                return GattStatus::InvalidPdu;
            }
            if self.connected.load(Ordering::Relaxed) & (1 << value[0]) == 0 {
                return GattStatus::WrongState;
            }
            if let Some((slot, data)) = s.rx.receive(value) {
                if !protocol::valid_output(&data) {
                    return GattStatus::InvalidPdu;
                }
                if self.events.try_send(Event::Output(slot, data)).is_err() {
                    return GattStatus::InsufficientResource;
                }
            } else if value[3] & 0x80 != 0 {
                return GattStatus::InvalidPdu;
            }
        } else {
            return GattStatus::WriteNotPermitted;
        }
        GattStatus::Ok
    }

    pub fn set_name(&self, name: &str) {
        *self.name.lock().unwrap() = name.to_owned();
        // Advertisements are rebuilt on the next disconnect; don't interrupt this link.
        self.check(self.gap.set_device_name(name));
    }
    pub fn control_connected(&self, generation: u32) -> bool {
        let s = self.state.lock().unwrap();
        s.connection.is_some() && s.generation == generation
    }
    pub fn control_reply(&self, generation: u32, data: &[u8]) {
        let mut s = self.state.lock().unwrap();
        if s.generation != generation || !s.control_subscribed || s.connection.is_none() {
            return;
        }
        let sequence = u16::from_le_bytes([data[1], data[2]]);
        let frames = protocol::fragments(0, sequence, data);
        if s.control_tx.len() + frames.len() <= 16 {
            s.control_tx.extend(frames);
        } else {
            log::warn!("Management response queue full");
        }
    }
    pub fn poll_control(&self) {
        let (conn, interface, control, generation, frame) = {
            let mut s = self.state.lock().unwrap();
            if s.control_inflight || s.congested || !s.control_subscribed {
                return;
            }
            let (Some(conn), Some(frame)) = (s.connection, s.control_tx.front().cloned()) else {
                return;
            };
            s.control_inflight = true;
            (conn, s.interface, s.control, s.generation, frame)
        };
        if self
            .gatt
            .indicate(interface, conn, control, &frame)
            .is_err()
        {
            let mut s = self.state.lock().unwrap();
            if s.generation == generation {
                s.control_inflight = false;
            }
        }
    }
    pub fn clear_remote_reports(&self, slot: u8) {
        let mut s = self.state.lock().unwrap();
        s.input_replies.clear_slot(slot);
        s.samples.clear_slot(slot);
    }
    pub fn poll_input_replies(&self) {
        for _ in 0..4 {
            let (conn, interface, input, generation, frame) = {
                let s = self.state.lock().unwrap();
                let Some(conn) = s.connection else {
                    return;
                };
                if !s.input_subscribed || s.congested {
                    return;
                }
                let Some(frame) = s.input_replies.front() else {
                    return;
                };
                (conn, s.interface, s.input, s.generation, frame.to_vec())
            };
            // Classic link allocation can reduce BLE's entire quota to two.
            // Reserving two here permanently stalls even priority replies.
            if !protocol::can_submit_input(
                unsafe { esp_ble_get_cur_sendable_packets_num(conn) } as usize,
                1,
            ) || self.gatt.notify(interface, conn, input, &frame).is_err()
            {
                return;
            }
            let mut s = self.state.lock().unwrap();
            if s.generation != generation || s.connection != Some(conn) {
                return;
            }
            s.input_replies.sent();
        }
    }
    pub fn send_report(&self, slot: u8, sequence: u16, report: &[u8], timestamp: u32) {
        let mut s = self.state.lock().unwrap();
        if s.connection.is_none() || !s.input_subscribed {
            return;
        }
        if InputReplies::is_reply(report) {
            if !s.input_replies.enqueue(slot, sequence, report) {
                log::warn!("Wii reply queue full for slot {slot}");
            }
            return;
        }
        s.stats[slot as usize].received += 1;
        if s.samples.push(slot, sequence, timestamp, report) {
            s.stats[slot as usize].overflow += 1;
        }
    }
    pub fn poll_samples(&self) {
        // Bound each turn so input cannot monopolize the main event loop.
        for _ in 0..4 {
            let (conn, interface, input, generation, tx) = {
                let mut s = self.state.lock().unwrap();
                let expired = s
                    .samples
                    .expire(unsafe { esp_idf_svc::sys::esp_timer_get_time() } as u32);
                for (slot, count) in expired.iter().enumerate() {
                    s.stats[slot].expired += count;
                }
                let Some(conn) = s.connection else {
                    return;
                };
                if !s.input_subscribed || s.congested || s.input_replies.front().is_some() {
                    return;
                }
                let Some(tx) = s.samples.prepare(s.input_mode, s.mtu) else {
                    return;
                };
                (conn, s.interface, s.input, s.generation, tx)
            };
            // ESP-IDF may wait for its BTC task here. Never hold the mutex needed
            // by that task's GATT callbacks while calling into the stack.
            let available = unsafe { esp_ble_get_cur_sendable_packets_num(conn) } as usize;
            if !protocol::can_submit_input(available, tx.frames.len()) {
                return;
            }
            let mut sent = true;
            for frame in &tx.frames {
                if self.gatt.notify(interface, conn, input, frame).is_err() {
                    sent = false;
                    break;
                }
            }
            let mut s = self.state.lock().unwrap();
            if s.generation != generation || s.connection != Some(conn) {
                return;
            }
            // A failed multipart sample is discarded; retrying only its suffix
            // could never reconstruct it. The next sequence starts cleanly.
            s.samples.sent(&tx);
            for slot in tx.slots {
                if sent {
                    s.stats[slot as usize].sent += 1;
                } else {
                    s.stats[slot as usize].notify_failed += 1;
                }
            }
            if !sent {
                return;
            }
        }
    }
    pub fn log_input_stats(&self) {
        let (stats, conn) = {
            let mut s = self.state.lock().unwrap();
            (std::mem::take(&mut s.stats), s.connection)
        };
        if let Some(conn) = conn {
            log::info!("BLE available send slots={}", unsafe {
                esp_ble_get_cur_sendable_packets_num(conn)
            });
        }
        for (slot, stats) in stats.iter().enumerate() {
            if stats.received != 0 {
                log::info!("Transport slot {slot}: {stats:?}");
            }
        }
    }
    pub fn update_status(&self) {
        let target = {
            let s = self.state.lock().unwrap();
            if s.status_subscribed && !s.congested {
                s.connection
                    .map(|conn| (s.interface, conn, s.status, s.extended_status))
            } else {
                None
            }
        };
        if let Some((interface, conn, status, extended)) = target {
            self.check(
                self.gatt
                    .notify(interface, conn, status, &self.status_value(extended)),
            );
        }
    }
}
