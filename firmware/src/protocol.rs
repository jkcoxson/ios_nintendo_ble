//! Version 1 wire protocol. Kept free of ESP-IDF so it can be tested on the host.
pub const MAX_REPORT: usize = 64;

/// Credits are the *entire* remaining per-link quota, not spare buffer capacity.
/// In dual mode a newly connected Classic link can shrink BLE's quota to two.
pub fn can_submit_input(available: usize, frames: usize) -> bool {
    frames != 0 && available >= frames
}

/// Short per-player queues absorb BLE event bursts without replaying old input.
/// Keep individual reports (including alternating gyro/extension samples).
#[derive(Default)]
pub struct Samples {
    queues: [std::collections::VecDeque<Sample>; 4],
    next_slot: usize,
}
struct Sample {
    sequence: u16,
    timestamp: u32,
    data: Vec<u8>,
}
pub struct SampleTransmission {
    pub frames: Vec<Vec<u8>>,
    pub slots: Vec<u8>,
}
impl Samples {
    pub fn push(&mut self, slot: u8, sequence: u16, timestamp: u32, data: &[u8]) -> bool {
        let queue = &mut self.queues[slot as usize];
        let dropped = queue.len() == 8;
        if dropped {
            queue.pop_front();
        }
        queue.push_back(Sample {
            sequence,
            timestamp,
            data: data.to_vec(),
        });
        dropped
    }
    pub fn clear_slot(&mut self, slot: u8) {
        self.queues[slot as usize].clear();
    }
    pub fn expire(&mut self, now: u32) -> [u32; 4] {
        let mut dropped = [0; 4];
        for (slot, queue) in self.queues.iter_mut().enumerate() {
            while queue
                .front()
                .is_some_and(|s| now.wrapping_sub(s.timestamp) > 60_000)
            {
                queue.pop_front();
                dropped[slot] += 1;
            }
        }
        dropped
    }
    /// Snapshot only; consume after successful submission, so backpressure retries.
    pub fn prepare(&self, mode: u8, mtu: u16) -> Option<SampleTransmission> {
        let first = (0..4)
            .map(|n| (self.next_slot + n) % 4)
            .find(|s| !self.queues[*s].is_empty())?;
        let sample = self.queues[first].front()?;
        if mode != 3 || sample.data.len() + 15 > usize::from(mtu) {
            return Some(SampleTransmission {
                frames: timed_input_frames(
                    first as u8,
                    sample.sequence,
                    &sample.data,
                    mode.min(2),
                    mtu,
                    sample.timestamp,
                ),
                slots: vec![first as u8],
            });
        }
        // Batch: FF 01 count, then length-prefixed complete timestamped frames.
        let mut frame = vec![0xff, 1, 0];
        let mut slots = Vec::new();
        let mut used = [0; 4];
        loop {
            let mut added = false;
            for n in 0..4 {
                let slot = (first + n) % 4;
                let Some(sample) = self.queues[slot].get(used[slot]) else {
                    continue;
                };
                let length = sample.data.len() + 8;
                if frame.len() + 1 + length > usize::from(mtu.saturating_sub(3)) {
                    continue;
                }
                frame.push(length as u8);
                frame.extend_from_slice(&[
                    slot as u8,
                    sample.sequence as u8,
                    (sample.sequence >> 8) as u8,
                    0xc0,
                ]);
                frame.extend_from_slice(&sample.timestamp.to_le_bytes());
                frame.extend_from_slice(&sample.data);
                slots.push(slot as u8);
                used[slot] += 1;
                added = true;
            }
            if !added {
                break;
            }
        }
        frame[2] = slots.len() as u8;
        Some(SampleTransmission {
            frames: vec![frame],
            slots,
        })
    }
    pub fn sent(&mut self, tx: &SampleTransmission) {
        for slot in &tx.slots {
            self.queues[*slot as usize].pop_front();
            self.next_slot = (*slot as usize + 1) % 4;
        }
    }
}

/// Normal wake is remote-initiated. Only explicit Connect may page a missing
/// slot; suspension and existing links always win.
pub fn should_page(connected: u8, suspended: u8, slot: u8, explicitly_requested: bool) -> bool {
    slot < 4 && (connected | suspended) & (1 << slot) == 0 && explicitly_requested
}

pub fn fragments(slot: u8, sequence: u16, report: &[u8]) -> Vec<Vec<u8>> {
    if slot >= 4 || report.is_empty() || report.len() > MAX_REPORT {
        return vec![];
    }
    let count = report.len().div_ceil(16);
    report
        .chunks(16)
        .enumerate()
        .map(|(index, chunk)| {
            let mut frame = vec![
                slot,
                sequence as u8,
                (sequence >> 8) as u8,
                index as u8 | if index + 1 == count { 0x80 } else { 0 },
            ];
            frame.extend_from_slice(chunk);
            frame
        })
        .collect()
}

/// Opted-in peers can receive a complete input report in one ATT value.
/// Fall back to v1 fragments whenever the negotiated MTU cannot fit it.
pub fn input_frames(slot: u8, sequence: u16, report: &[u8], wide: bool, mtu: u16) -> Vec<Vec<u8>> {
    if wide
        && slot < 4
        && !report.is_empty()
        && report.len() <= MAX_REPORT
        && report.len() + 7 <= usize::from(mtu)
    {
        let mut frame = vec![slot, sequence as u8, (sequence >> 8) as u8, 0x80];
        frame.extend_from_slice(report);
        vec![frame]
    } else {
        fragments(slot, sequence, report)
    }
}

/// Mode 2 adds the HID callback's monotonic microsecond timestamp (wrapping u32).
/// Bit 6 is reserved for this single-frame format, never a fragment index.
pub fn timed_input_frames(
    slot: u8,
    sequence: u16,
    report: &[u8],
    mode: u8,
    mtu: u16,
    timestamp: u32,
) -> Vec<Vec<u8>> {
    if mode == 2
        && slot < 4
        && !report.is_empty()
        && report.len() <= MAX_REPORT
        && report.len() + 11 <= usize::from(mtu)
    {
        let mut frame = vec![slot, sequence as u8, (sequence >> 8) as u8, 0xc0];
        frame.extend_from_slice(&timestamp.to_le_bytes());
        frame.extend_from_slice(report);
        vec![frame]
    } else {
        input_frames(slot, sequence, report, mode != 0, mtu)
    }
}

/// One-time HID status, memory replies and ACKs must survive BLE congestion.
/// Motion samples are sent separately and never interleave with these fragments.
#[derive(Default)]
pub struct InputReplies {
    frames: std::collections::VecDeque<Vec<u8>>,
}
impl InputReplies {
    pub fn is_reply(report: &[u8]) -> bool {
        matches!(report.first(), Some(0x20..=0x22))
    }
    pub fn enqueue(&mut self, slot: u8, sequence: u16, report: &[u8]) -> bool {
        let frames = fragments(slot, sequence, report);
        if frames.is_empty() || self.frames.len() + frames.len() > 128 {
            return false;
        }
        self.frames.extend(frames);
        true
    }
    pub fn front(&self) -> Option<&[u8]> {
        self.frames.front().map(Vec::as_slice)
    }
    pub fn sent(&mut self) {
        self.frames.pop_front();
    }
    pub fn clear_slot(&mut self, slot: u8) {
        self.frames.retain(|frame| frame[0] != slot);
    }
}

#[derive(Default)]
pub struct Reassembler {
    partial: [Option<(u16, u8, Vec<u8>)>; 4],
}

impl Reassembler {
    pub fn receive(&mut self, frame: &[u8]) -> Option<(u8, Vec<u8>)> {
        if !(5..=20).contains(&frame.len()) || frame[0] >= 4 {
            return None;
        }
        let slot = frame[0] as usize;
        let sequence = u16::from_le_bytes([frame[1], frame[2]]);
        let index = frame[3] & 0x7f;
        let last = frame[3] & 0x80 != 0;
        if index >= 4 || (!last && frame.len() != 20) {
            self.partial[slot] = None;
            return None;
        }
        if index == 0 {
            self.partial[slot] = Some((sequence, 0, Vec::new()));
        }
        let (seq, next, mut data) = self.partial[slot].take()?;
        if seq != sequence || next != index {
            return None;
        }
        data.extend_from_slice(&frame[4..]);
        if last {
            Some((slot as u8, data))
        } else {
            self.partial[slot] = Some((seq, next + 1, data));
            None
        }
    }
}

/// Enforce actual Wii output report sizes before calling into the Bluetooth stack.
pub fn valid_output(data: &[u8]) -> bool {
    let Some(id) = data.first() else {
        return false;
    };
    let length = match id {
        0x10 | 0x11 | 0x13 | 0x14 | 0x15 | 0x19 | 0x1a => 2,
        0x12 => 3,
        0x16 | 0x18 => 22,
        0x17 => 7,
        _ => return false,
    };
    data.len() == length
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shrinking_ble_quota_does_not_permanently_stop_input() {
        // Regression: the old two-credit reservation rejected all of these
        // useful send opportunities after another Classic controller connected.
        assert!(can_submit_input(1, 1)); // a priority reply or timestamped batch
        assert!(can_submit_input(2, 1));
        assert!(can_submit_input(2, 2)); // a legacy 22-byte Wii report
        assert!(!can_submit_input(0, 1));
        assert!(!can_submit_input(1, 2)); // do not start an incomplete sample
        assert!(!can_submit_input(2, 0));
    }
    #[test]
    fn sample_batches_preserve_each_report_and_rotate_players() {
        let mut samples = Samples::default();
        for seq in 0..8 {
            for slot in 0..3 {
                assert!(!samples.push(slot, seq, 1000 + u32::from(seq), &[0x37; 22]));
            }
        }
        let batch = samples.prepare(3, 185).unwrap();
        assert_eq!(batch.slots, [0, 1, 2, 0, 1]);
        assert_eq!(batch.frames[0].len(), 158);
        assert_eq!(&batch.frames[0][..8], &[0xff, 1, 5, 30, 0, 0, 0, 0xc0]);
        assert_eq!(&batch.frames[0][8..12], &1000u32.to_le_bytes());
        assert_eq!(samples.prepare(3, 185).unwrap().frames, batch.frames); // No credits: retain.
        samples.sent(&batch);
        assert_eq!(samples.prepare(3, 185).unwrap().slots[0], 2);
        let legacy = samples.prepare(0, 23).unwrap();
        assert_eq!(legacy.frames.len(), 2);
        assert_eq!(legacy.slots, [2]);
        let small = samples.prepare(3, 33).unwrap();
        assert_eq!(small.frames[0][3], 0xc0); // Batch doesn't fit; timestamped fallback.
        let minimum = samples.prepare(3, 23).unwrap();
        assert_eq!(minimum.frames.len(), 2);
    }
    #[test]
    fn sample_queues_bound_age_capacity_and_clear_connections() {
        let mut samples = Samples::default();
        for seq in 0..9 {
            assert_eq!(samples.push(0, seq, u32::MAX - 100, &[0x30]), seq == 8);
        }
        assert_eq!(samples.prepare(2, 185).unwrap().frames[0][1], 1);
        assert_eq!(samples.expire(59_899), [0; 4]); // exactly 60 ms, including rollover
        assert_eq!(samples.expire(59_900), [8, 0, 0, 0]);
        assert!(samples.prepare(3, 185).is_none());
        samples.push(1, 1, 70_000, &[0x37]);
        samples.push(2, 1, 70_000, &[0x37]);
        samples.clear_slot(1);
        assert_eq!(samples.prepare(3, 185).unwrap().slots, [2]);
    }
    #[test]
    fn timestamps_require_negotiation_and_fit_the_mtu() {
        let report = [0x37; 22];
        let timed = timed_input_frames(1, 0x1234, &report, 2, 33, 0x78563412);
        assert_eq!(
            &timed[0][..8],
            &[1, 0x34, 0x12, 0xc0, 0x12, 0x34, 0x56, 0x78]
        );
        assert_eq!(&timed[0][8..], &report);
        assert_eq!(
            timed_input_frames(1, 2, &report, 2, 32, 0),
            input_frames(1, 2, &report, true, 32)
        );
        assert_eq!(
            timed_input_frames(1, 2, &report, 1, 185, 0),
            input_frames(1, 2, &report, true, 185)
        );
        assert_eq!(
            timed_input_frames(1, 2, &report, 0, 185, 0),
            fragments(1, 2, &report)
        );
        assert!(timed_input_frames(4, 0, &report, 2, 185, 0).is_empty());
        assert!(timed_input_frames(0, 0, &[0; 65], 2, 185, 0).is_empty());
        assert_eq!(timed_input_frames(0, 0, &[1; 64], 2, 75, 0)[0].len(), 72);
    }
    #[test]
    fn wide_input_requires_opt_in_and_sufficient_mtu() {
        let report = [0x37; 22];
        assert_eq!(
            input_frames(1, 7, &report, false, 185),
            fragments(1, 7, &report)
        );
        assert_eq!(
            input_frames(1, 7, &report, true, 28),
            fragments(1, 7, &report)
        );
        let wide = input_frames(1, 7, &report, true, 29);
        assert_eq!(wide.len(), 1);
        assert_eq!(wide[0].len(), 26);
        assert_eq!(&wide[0][..4], &[1, 7, 0, 0x80]);
        assert_eq!(&wide[0][4..], &report);
        assert!(input_frames(4, 0, &report, true, 185).is_empty());
        assert!(input_frames(0, 0, &[0; 65], true, 185).is_empty());
    }
    #[test]
    fn one_time_replies_survive_backpressure_and_keep_fragment_order() {
        let mut replies = InputReplies::default();
        let mut rx = Reassembler::default();
        let memory = [0x21; 22];
        assert!(InputReplies::is_reply(&memory));
        assert!(InputReplies::is_reply(&[0x20]));
        assert!(InputReplies::is_reply(&[0x22]));
        assert!(!InputReplies::is_reply(&[0x37]));
        assert!(!InputReplies::is_reply(&[]));
        assert!(replies.enqueue(1, 4, &memory));
        assert!(replies.enqueue(1, 5, &[0x22, 0, 0, 0x16, 0]));
        let first = replies.front().unwrap().to_vec();
        // A failed send does not consume the frame; a partial send resumes exactly.
        assert_eq!(replies.front().unwrap(), first);
        assert!(rx.receive(replies.front().unwrap()).is_none());
        replies.sent();
        assert_eq!(
            rx.receive(replies.front().unwrap()),
            Some((1, memory.to_vec()))
        );
        replies.sent();
        assert_eq!(
            rx.receive(replies.front().unwrap()),
            Some((1, vec![0x22, 0, 0, 0x16, 0]))
        );
        replies.sent();
        assert!(replies.front().is_none());
        for sequence in 0..64 {
            assert!(replies.enqueue(0, sequence, &memory));
        }
        assert!(!replies.enqueue(0, 64, &memory));
        replies.clear_slot(0);
        assert!(replies.front().is_none());
    }
    #[test]
    fn sleeping_remotes_do_not_interrupt_active_players() {
        assert!(!should_page(0, 0, 0, false));
        assert!(!should_page(2, 0, 0, false));
        assert!(should_page(2, 0, 0, true));
        assert!(!should_page(2, 1, 0, true));
        assert!(!should_page(2, 0, 1, true));
        assert!(!should_page(0, 0, 4, true));
        // Expiring the explicit connection window returns to passive reconnect.
        assert!(!should_page(2, 0, 0, false));
    }
    #[test]
    fn wire_fixture_and_roundtrip() {
        assert_eq!(
            fragments(2, 0x1234, &[0x30, 0, 8]),
            vec![vec![2, 0x34, 0x12, 0x80, 0x30, 0, 8]]
        );
        for size in 1..=64 {
            let data: Vec<u8> = (0..size).collect();
            let mut rx = Reassembler::default();
            let frames = fragments(3, 65535, &data);
            for frame in &frames[..frames.len() - 1] {
                assert!(rx.receive(frame).is_none());
            }
            assert_eq!(rx.receive(frames.last().unwrap()), Some((3, data)));
        }
    }
    #[test]
    fn missing_and_mixed_fragments_never_produce_a_report() {
        let mut rx = Reassembler::default();
        let a = fragments(0, 1, &[0; 48]);
        let b = fragments(0, 2, &[1; 48]);
        assert!(rx.receive(&a[0]).is_none());
        assert!(rx.receive(&a[2]).is_none());
        assert!(rx.receive(&b[0]).is_none());
        assert!(rx.receive(&a[1]).is_none());
        assert!(rx.receive(&b[2]).is_none());
    }
    #[test]
    fn rejects_malformed_and_unknown_commands() {
        let mut rx = Reassembler::default();
        for size in 0..=128 {
            assert!(rx.receive(&vec![255; size]).is_none());
        }
        assert!(valid_output(&[0x11, 0x10]));
        assert!(!valid_output(&[0x16, 0]));
        assert!(!valid_output(&[0xff, 0]));
    }
}

pub const MAX_NAME_BYTES: usize = 24;
pub const BRIDGE_TARGET: u8 = 0xff;
// ESP-IDF's HID_HOST_MAX_DEVICES is 7; BLE still exposes only four live slots.
pub const MAX_REMEMBERED_REMOTES: usize = 7;

pub type RemoteAddress = [u8; 6];

pub fn remembered_index(
    remembered: &[Option<RemoteAddress>; MAX_REMEMBERED_REMOTES],
    address: RemoteAddress,
) -> Option<usize> {
    remembered.iter().position(|entry| *entry == Some(address))
}

pub fn available_remote_slot(
    slots: &[Option<RemoteAddress>; 4],
    address: RemoteAddress,
    connected: u8,
    suspended: u8,
) -> Option<usize> {
    if let Some(slot) = slots.iter().position(|entry| *entry == Some(address)) {
        return ((connected | suspended) & (1 << slot) == 0).then_some(slot);
    }
    (0..4)
        .find(|&slot| slots[slot].is_none() && (connected | suspended) & (1 << slot) == 0)
        .or_else(|| (0..4).find(|&slot| (connected | suspended) & (1 << slot) == 0))
}

#[cfg(test)]
mod remote_roster_tests {
    use super::*;

    #[test]
    fn fifth_remembered_remote_uses_idle_slot_and_four_live_remotes_block_it() {
        let slots = [Some([1; 6]), Some([2; 6]), Some([3; 6]), Some([4; 6])];
        assert_eq!(available_remote_slot(&slots, [5; 6], 0b0111, 0), Some(3));
        assert_eq!(available_remote_slot(&slots, [5; 6], 0b1111, 0), None);
        assert_eq!(available_remote_slot(&slots, [4; 6], 0b0111, 0), Some(3));
        assert_eq!(available_remote_slot(&slots, [5; 6], 0b0111, 0b1000), None);
    }

    #[test]
    fn remembered_address_keeps_its_index_when_slots_rotate() {
        let remembered = [
            Some([1; 6]),
            Some([2; 6]),
            Some([3; 6]),
            Some([4; 6]),
            Some([5; 6]),
            None,
            None,
        ];
        assert_eq!(remembered_index(&remembered, [5; 6]), Some(4));
        assert_eq!(remembered_index(&remembered, [6; 6]), None);
        let slots = [Some([1; 6]), Some([2; 6]), Some([3; 6]), Some([5; 6])];
        assert_eq!(available_remote_slot(&slots, [4; 6], 0b0111, 0), Some(3));
        assert_eq!(remembered_index(&remembered, [4; 6]), Some(3));
    }
}
#[derive(Debug, PartialEq)]
pub enum ControlCommand {
    Info(u8),
    Pair,
    PlayerState,
    PlayerOrder([u8; 4]),
    Disconnect(u8, [u8; 6]),
    Connect(u8, [u8; 6]),
    Rename(u8, [u8; 6], String),
    Remembered(u8),
    Forget(u8, [u8; 6]),
    RenameRemembered(u8, [u8; 6], String),
    PowerOff(u8, [u8; 6]),
}
pub fn valid_name(name: &str) -> bool {
    !name.trim().is_empty() && name.len() <= MAX_NAME_BYTES && !name.chars().any(char::is_control)
}
pub fn control_command(data: &[u8]) -> Option<(u16, ControlCommand)> {
    if data.len() < 4 || data[0] != 1 {
        return None;
    }
    let id = u16::from_le_bytes([data[1], data[2]]);
    let target_ok = |target| target < 4 || target == BRIDGE_TARGET;
    let command = match data[3] {
        1 if data.len() == 5 && target_ok(data[4]) => ControlCommand::Info(data[4]),
        2 if data.len() == 4 => ControlCommand::Pair,
        3 if data.len() >= 12 && target_ok(data[4]) => {
            let name = std::str::from_utf8(&data[11..]).ok()?;
            if !valid_name(name) {
                return None;
            }
            ControlCommand::Rename(data[4], data[5..11].try_into().ok()?, name.to_owned())
        }
        4 if data.len() == 4 => ControlCommand::PlayerState,
        5 if data.len() == 8 && valid_order(&data[4..]) => {
            ControlCommand::PlayerOrder(data[4..8].try_into().ok()?)
        }
        6 | 7 if data.len() == 11 && data[4] < 4 => {
            let address = data[5..11].try_into().ok()?;
            if data[3] == 6 {
                ControlCommand::Disconnect(data[4], address)
            } else {
                ControlCommand::Connect(data[4], address)
            }
        }
        8 if data.len() == 5 && data[4] < MAX_REMEMBERED_REMOTES as u8 => {
            ControlCommand::Remembered(data[4])
        }
        9 if data.len() == 11 && data[4] < MAX_REMEMBERED_REMOTES as u8 => {
            ControlCommand::Forget(data[4], data[5..11].try_into().ok()?)
        }
        10 if data.len() >= 12 && data[4] < MAX_REMEMBERED_REMOTES as u8 => {
            let name = std::str::from_utf8(&data[11..]).ok()?;
            if !valid_name(name) {
                return None;
            }
            ControlCommand::RenameRemembered(data[4], data[5..11].try_into().ok()?, name.to_owned())
        }
        11 if data.len() == 11 && data[4] < 4 => {
            ControlCommand::PowerOff(data[4], data[5..11].try_into().ok()?)
        }
        _ => return None,
    };
    Some((id, command))
}
pub fn control_reply(request: &[u8], result: u8, payload: &[u8]) -> Vec<u8> {
    let mut reply = vec![1, request[1], request[2], request[3], result];
    reply.extend_from_slice(payload);
    reply
}

#[cfg(test)]
mod control_tests {
    use super::*;
    #[test]
    fn management_commands_validate_identity_and_utf8() {
        assert_eq!(
            control_command(&[1, 42, 0, 2]),
            Some((42, ControlCommand::Pair))
        );
        assert_eq!(
            control_command(&[1, 42, 0, 1, 255]),
            Some((42, ControlCommand::Info(255)))
        );
        assert_eq!(
            control_command(&[1, 42, 0, 8, 6]),
            Some((42, ControlCommand::Remembered(6)))
        );
        assert!(control_command(&[1, 42, 0, 8, 7]).is_none());
        assert_eq!(
            control_command(&[1, 42, 0, 9, 4, 1, 2, 3, 4, 5, 6]),
            Some((42, ControlCommand::Forget(4, [1, 2, 3, 4, 5, 6])))
        );
        assert_eq!(
            control_command(&[1, 42, 0, 11, 2, 1, 2, 3, 4, 5, 6]),
            Some((42, ControlCommand::PowerOff(2, [1, 2, 3, 4, 5, 6])))
        );
        let mut rename = vec![1, 4, 0, 3, 1, 1, 2, 3, 4, 5, 6];
        rename.extend_from_slice("Living Room".as_bytes());
        assert_eq!(
            control_command(&rename),
            Some((
                4,
                ControlCommand::Rename(1, [1, 2, 3, 4, 5, 6], "Living Room".into())
            ))
        );
        let mut rename_remembered = vec![1, 4, 0, 10, 6, 1, 2, 3, 4, 5, 6];
        rename_remembered.extend_from_slice("White".as_bytes());
        assert_eq!(
            control_command(&rename_remembered),
            Some((
                4,
                ControlCommand::RenameRemembered(6, [1, 2, 3, 4, 5, 6], "White".into())
            ))
        );
        for name in [
            "",
            "  ",
            "bad\0name",
            "bad\nname",
            "1234567890123456789012345",
        ] {
            assert!(!valid_name(name));
        }
        assert!(valid_name("リモコン"));
        assert!(control_command(&[1, 1, 0, 1, 4]).is_none());
        assert!(control_command(&[2, 1, 0, 2]).is_none());
        let reply = control_reply(&rename, 0, &rename[4..]);
        let mut rx = Reassembler::default();
        let mut decoded = None;
        for fragment in fragments(0, 4, &reply) {
            decoded = rx.receive(&fragment);
        }
        assert_eq!(decoded, Some((0, reply)));
    }
}

/// Stable bond identities never move. Index in this runtime permutation is the
/// player port; disconnected entries are vacant, not removed.
pub fn valid_order(order: &[u8]) -> bool {
    order.len() == 4 && (0..4).all(|slot| order.iter().filter(|&&v| v == slot).count() == 1)
}
pub fn player_index(order: &[u8; 4], connected: u8, slot: u8) -> Option<usize> {
    if slot >= 4 || connected & (1 << slot) == 0 {
        return None;
    }
    order.iter().position(|&s| s == slot)
}

/// Assign a new connection to the first vacant port without moving live players.
/// Swapping only disconnected entries keeps the wire representation a permutation.
pub fn assign_player(order: &mut [u8; 4], connected: u8, slot: u8) {
    if slot >= 4 || connected & (1 << slot) != 0 {
        return;
    }
    if let (Some(vacant), Some(previous)) = (
        order.iter().position(|&s| connected & (1 << s) == 0),
        order.iter().position(|&s| s == slot),
    ) {
        order.swap(vacant, previous);
    }
}

pub fn pack_players(order: &[u8; 4]) -> u8 {
    order
        .iter()
        .enumerate()
        .fold(0, |packed, (player, slot)| packed | (slot << (2 * player)))
}
pub fn unpack_players(packed: u8) -> [u8; 4] {
    std::array::from_fn(|player| (packed >> (2 * player)) & 3)
}
#[cfg(test)]
mod player_tests {
    use super::*;
    #[test]
    fn order_is_a_permutation_and_player_numbers_preserve_vacancies() {
        assert!(valid_order(&[1, 0, 3, 2]));
        for order in [vec![0, 0, 2, 3], vec![0, 1, 2], vec![0, 1, 2, 4]] {
            assert!(!valid_order(&order));
            let mut request = vec![1, 1, 0, 5];
            request.extend(order);
            assert!(control_command(&request).is_none());
        }
        assert_eq!(player_index(&[1, 0, 3, 2], 0b1010, 1), Some(0));
        assert_eq!(player_index(&[1, 0, 3, 2], 0b1010, 3), Some(2));
        assert_eq!(player_index(&[1, 0, 3, 2], 0b1010, 0), None);
        assert_eq!(
            control_command(&[1, 1, 0, 5, 1, 0, 3, 2]),
            Some((1, ControlCommand::PlayerOrder([1, 0, 3, 2])))
        );
        assert_eq!(
            control_command(&[1, 1, 0, 6, 2, 1, 2, 3, 4, 5, 6]),
            Some((1, ControlCommand::Disconnect(2, [1, 2, 3, 4, 5, 6])))
        );
        assert_eq!(
            control_command(&[1, 1, 0, 7, 2, 1, 2, 3, 4, 5, 6]),
            Some((1, ControlCommand::Connect(2, [1, 2, 3, 4, 5, 6])))
        );
    }
}

#[cfg(test)]
mod assignment_tests {
    use super::*;
    #[test]
    fn middle_disconnect_replacement_and_fresh_session() {
        let mut order = [0, 1, 2, 3];
        let mut connected = 0;
        for slot in [2, 0, 1] {
            assign_player(&mut order, connected, slot);
            connected |= 1 << slot;
        }
        assert_eq!(order, [2, 0, 1, 3]);
        connected &= !(1 << 0); // Player 2 goes away.
        assert_eq!(player_index(&order, connected, 1), Some(2)); // Player 3 stays 3.
        assign_player(&mut order, connected, 3); // A different remote replaces its battery-dead peer.
        connected |= 1 << 3;
        assert_eq!(order, [2, 3, 1, 0]);
        assign_player(&mut order, connected, 0); // Original peer can only take the remaining port.
        connected |= 1 << 0;
        assert_eq!(player_index(&order, connected, 0), Some(3));
        connected = 0;
        assign_player(&mut order, connected, 1); // A new session starts with a different remote.
        assert_eq!(order[0], 1);
        assert_eq!(unpack_players(pack_players(&order)), order);
    }
    #[test]
    fn joining_never_moves_an_existing_player() {
        for mask in 0u8..16 {
            for slot in 0..4 {
                let mut order = [3, 1, 0, 2];
                let previous = order;
                assign_player(&mut order, mask, slot);
                assert!(valid_order(&order));
                for live in 0..4 {
                    if mask & (1 << live) != 0 {
                        assert_eq!(
                            player_index(&order, mask, live),
                            player_index(&previous, mask, live)
                        );
                    }
                }
            }
        }
    }
}
