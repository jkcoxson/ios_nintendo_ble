# WiiBLE protocol v1

A bridge supports one BLE consumer, up to seven remembered Wii Remotes, and four
simultaneous Wii Remote slots (0...3). Remembered remotes without a live slot can
take an available slot when they reconnect. All UUIDs share
suffix `-9C2A-4B3D-A91F-8F4E62D4C001`:

| Prefix | Role | Properties |
| --- | --- | --- |
| `7B9C0001` | Service | Primary |
| `7B9C0002` | Wii input reports | Notify + CCCD |
| `7B9C0003` | Wii output reports | Write with response |
| `7B9C0004` | Bridge status | Read, notify + CCCD |
| `7B9C0005` | Optional bridge management | Write with response, indicate + CCCD |
| `7B9C0006` | Optional capabilities | Read; optionally Write with response |

Legacy status is exactly three bytes: `[version=1, pairingOpen=0/1, connectedSlotBitmap]`.
Read it and subscribe before considering the bridge ready. A connected bridge is
not itself a connected Wii Remote. Status is repeated once a second to recover from
lost notifications; it also changes on pairing-window and remote-link transitions.

Capability bit 4 (`0x10`) advertises stable player ports. A supporting consumer
sets bit 7 (`0x80`) in its capabilities write, ORed with input mode 0...3. Status
then appends four bytes: `[slotAtPlayer1, slotAtPlayer2, slotAtPlayer3, slotAtPlayer4]`.
These are a permutation of live slot numbers 0...3. A port is vacant if its slot is absent
from the connected bitmap. Do not compact the permutation when a slot disconnects.
Example: `[1,0,0b0101,0,1,2,3]` means players 1 and 3 are connected, player 2 is vacant.
The opt-in resets on BLE reconnect; existing clients continue receiving three bytes.
Consumers should read the negotiated status before exposing player assignments.

By default, each input notification or output write is 5...20 bytes:

| Byte | Meaning |
| --- | --- |
| 0 | Wii slot 0...3 |
| 1...2 | Unsigned sequence number, little endian |
| 3 | Fragment index 0...3 in low 7 bits; bit 7 marks final fragment |
| 4...19 | Up to 16 bytes of report data |

Non-final fragments must contain 16 payload bytes. The first fragment has index 0;
indices increase by one. A different sequence, missing index, malformed frame, or
out-of-order fragment invalidates the partial report. Assemblers maintain separate
partial reports per slot and reset on BLE disconnection. Maximum assembled size is
64 bytes; actual Wii reports are normally 2...22 bytes. Sequence numbers wrap modulo
65536. Streaming samples have no delivery guarantee under radio congestion.
One-time Wii status/memory/ACK replies are queued ahead of samples as described below.

New firmware exposes capability bit 1 and a writable capabilities characteristic.
A client that supports wide input can write `[1]` there to opt in for this BLE
connection (`[0]` disables it). Old firmware has a read-only characteristic; old
clients never opt in and continue receiving the original fragments. With opt-in,
a complete report fitting the negotiated ATT MTU is sent as a single 5...68-byte
value using the same header and flags `0x80`. Values longer than 20 bytes are valid
only as index-zero final frames. Multipart, output, and management frames retain
their original 20-byte limit. A 22-byte motion report requires ATT MTU >=29; below
that, firmware falls back to the original two fragments. Opt-in resets on reconnect.

Capability bit 2 additionally advertises timestamped input. After reading this bit,
a client can write `[2]` instead of `[1]`. These complete frames use flags `0xC0`,
bytes 4...7 contain an unsigned little-endian microsecond timestamp, and bytes
8 onward contain the HID report (1...64 bytes). Thus the value is 9...72 bytes;
a normal 22-byte report requires ATT MTU >=33. If it does not fit, firmware falls
back to untimed wide frames or the original fragments. No other flag combinations
use timestamps. Priority status/memory/ACK replies retain their original framing.

The timestamp is sampled in the ESP32 Classic HID receive callback, before its
application queue or BLE delivery. It is not the remote's internal sensor clock.
It wraps modulo 2^32 (~71.6 minutes); use unsigned differences between consecutive
gyro reports from the same remote. Never subtract it from a host clock. Consumers
must reset timing on format/connection changes and reject stale or long-gap input.
This avoids treating BLE bursts or application queue delays as physical rotation.
Older clients still receive untimed reports; older firmware is never sent mode 2.

Capability bit 3 advertises batched timestamped input. Clients can opt in with
`[3]` on the capabilities characteristic. A batch is at most 182 bytes and begins
`[0xff, 1, count]`, followed by `count` records. Each record is one length byte
followed by a complete mode-2 frame (9...72 bytes, including its slot, sequence,
`0xc0` flags, timestamp, and HID report). Count is 1...32. Reject the whole batch
if any record is invalid, truncated, or leaves trailing bytes. Each record retains
its own HID-receive timestamp; batch arrival time is not sensor sampling time.
When the negotiated MTU is too small, mode 3 falls back to individual mode-2,
wide, or legacy frames. Status/memory/ACK replies keep their existing framing.

Streaming input uses per-slot queues of at most eight reports, served round-robin.
Only already-pending reports are combined; there is no timer to fill a batch.
Samples older than 60 ms at the firmware sender are discarded, and a full slot
queue drops its oldest sample. This is a bound on application buffering, not a
guarantee of end-to-end latency. Alternating gyro and extension reports retain
their individual order within each slot. New BLE connections clear all queues.

Firmware offers ATT MTU 185 and requests a 15–30 ms connection interval with zero
peripheral latency. The central may choose a longer interval. No extra smoothing
or deliberate input buffering is added by this extension.

Example: slot 2, sequence 0x1234, Wii report `30 00 08` (A pressed) is one GATT value:
`02 34 12 80 30 00 08`.

Reports include the HID report ID as their first byte. They exclude Bluetooth HID
headers (`A1` input / `A2` output). Firmware forwards all received input report IDs.
It validates known Wii output IDs and lengths before submitting to the Classic stack.
Prepared/offset GATT writes are rejected; use the fragment protocol instead.

A BLE write response acknowledges fragment acceptance by the bridge, not completion
of the Wii command. Wii report `22` acknowledges commands when requested; report `21`
carries memory read results. Observe these replies to sequence initialization, and
set the acknowledgement-request bit where required. Raw-output clients are responsible
for sequencing commands, timeouts, rumble bits, and device-specific setup.

When no BLE consumer is connected, the Wii link may stay active. The bridge's initial
Wii report mode is 0x31 (buttons + accelerometer); consumers can select another mode.
On BLE disconnect the bridge sends rumble-off to each connected remote.


## Management extension (version 1)

The optional `0005` characteristic leaves the existing v1 report/status protocol intact.
Subscribe before issuing commands. Both directions use the same 20-byte fragmentation
layout as Wii reports, with outer slot always zero, an independent reassembler, and the
request ID as the sequence number. Management payloads never enter the Wii HID channel.

Request: `[1, requestID LE16, opcode, payload...]`.
Response: `[1, requestID LE16, opcode, result, payload...]`.
Result 0 confirms completion; 2 means no matching remembered remote; 3 means persistence
failed. Malformed requests receive a GATT error. Clients must correlate request ID/opcode
and time out missing replies; GATT acceptance alone does not confirm completion. Swift
starts a five-second reply timeout after the final GATT write is acknowledged, with
a separate twelve-second limit on waiting for transmission. Management writes take
priority between complete Wii reports. Wii output rotates slots while preserving
command and fragment order within each slot.

| Opcode | Request payload | Successful response payload |
| --- | --- | --- |
| 1: info | target | target, 6-byte address, UTF-8 name |
| 2: open pairing | empty | empty |
| 3: rename | target, 6-byte expected address, UTF-8 name | empty |
| 4: player state | empty | 4 slot priorities, suspended-slot bitmap |
| 5: player order | permutation of slots 0...3 | 4 slot priorities, suspended-slot bitmap |
| 6: disconnect remote | slot, 6-byte expected address | empty |
| 7: connect remote | slot, 6-byte expected address | empty |
| 8: remembered remote | roster index 0...6 | index, assigned slot or `ff`, 6-byte address, UTF-8 name |
| 9: forget remote | roster index, 6-byte expected address | empty; bridge restarts after reply |
| 10: rename remembered remote | roster index, 6-byte expected address, UTF-8 name | empty |
| 11: power off remote | slot, 6-byte expected address | empty |

Target `ff` identifies the bridge (six zero address bytes); 0...3 identifies a
currently assigned Wii Remote, including sleeping remotes. Other remembered
remotes receive a slot when they reconnect. Addresses are opaque bytes in ESP-IDF order.
The remembered-remote command lists every saved identity, including those without an
assigned slot. An empty roster index returns result 2. Forget removes the roster entry,
slot assignment, saved name, and Bluetooth bond, then restarts the bridge to release
the HID host's device entry. It disconnects active remotes during the restart. Rename
and forget check the expected address so a stale UI cannot change another remote.
Rename checks the expected address so stale slots cannot rename another remote. Names
are nonblank, valid UTF-8, at most 24 bytes, without control characters. Names persist in
NVS alongside bonds/slots. The bridge name is in the scan response; the service UUID is
in the advertisement. Renaming does not interrupt the current connection.

Open pairing starts/extends a 30-second deadline without resetting or disconnecting BLE
or existing remotes. Status exposes the transition. Queued management requests/replies
are scoped to the originating BLE connection generation.


The optional `0006` characteristic reads a capability bitfield (currently `[0x7f]`).
Bit 0 identifies runtime player control (opcodes 4...7). Its presence lets clients
hide those actions for older firmware without submitting unsupported commands.
Result 4 reports a failed disconnect.
Bit 6 identifies opcode 11. Power off ends the physical HID link after the
emulated Wii disconnects. It keeps the Bluetooth bond and does not suspend the
slot, so a normal button press can wake and reconnect the remote later.

Player order maps player ports to the four current slot IDs. On each new
connection, firmware swaps that slot into the lowest vacant port; established
players do not move. Disconnecting player 2 leaves player 3 at port 3. A different
remote may take port 2, and the old remote must then use another free port. When
all remotes leave, the next arrival takes port 1 regardless of its saved identity.
Input reports use the current slot ID. Bonds and names follow Bluetooth addresses,
including when a different remembered remote takes an idle slot. Explicit
SetPlayerOrder can rearrange ports; consumers apply the returned mapping including
holes. This runtime mapping is not stored in NVS and survives BLE disconnects.

Disconnect stops rumble, closes the selected Classic link, clears its connected status,
and blocks automatic/incoming reconnects for that slot until Connect or ESP32 reboot.
Connect clears suspension and requests up to 30 seconds of active reconnect attempts;
an asleep remote may need to be woken with A. Otherwise remembered remotes reconnect
passively, including when all players are asleep. There is no background paging.
Boot opens pairing only when no remotes are remembered; opcode 2 opens it otherwise.
This keeps inquiry/page traffic out of the ordinary wake path.
Other remotes and the BLE bridge remain connected. Disconnect/connect validate the
expected Bluetooth address, just like Rename.


Current firmware uses acknowledged GATT indications for management responses, with one
fragment outstanding until ATT confirmation. The library also accepts the original
notification-based management characteristic. Management polling runs independently
of streaming input: pending management replies never suppress Wii motion/button
reports. The bridge checks transmit credits before admitting a complete input report.
It does not reserve a fixed number of credits: Classic connection allocation can
reduce the entire BLE quota to two, making a two-credit reservation a permanent
stall. Management and priority input are serviced before bounded sample-send turns.
The sample queues bound motion backlog; fragmented samples start only when their
frames fit the available credits. Ordinary BLE
congestion can still drop streaming samples. Wii status (`0x20`), memory replies
(`0x21`) and ACKs (`0x22`) use a bounded priority queue (128 fragments). These replies
wait for transmit credits and resume from an unsent fragment on a notification error;
samples cannot interrupt a partially sent reply. Queues are cleared on BLE disconnect
and per-slot remote disconnect. This prevents IR/gyro traffic from discarding extension
identification or calibration replies; it is not an end-to-end acknowledgment protocol.
