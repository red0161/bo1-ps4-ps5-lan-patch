"""Make the modified PS4 host (BO1 CUSA57547, app 01.08) use another network protocol number.

Usage:
  python protocol_patch.py <ps4_ip> status
  python protocol_patch.py <ps4_ip> apply <protocol>     e.g. apply 0x849
  python protocol_patch.py <ps4_ip> restore

Every site is checked against the original 01.08 bytes before writing and read
back afterwards. The original bytes are already known, so restore always writes 0x848.
"""
import json
import pathlib
import struct
import sys

from ps4debug import PS4Debug

HERE = pathlib.Path(__file__).resolve().parent
ORIGINAL = 0x848

# (description, instruction address, opcode bytes before the imm32)
SITES = [
    ("host advertises protocol in lobby info", 0x54FB5D, b"\xbe"),
    ("host connect check (SV_DirectConnect)", 0x5572F7, b"\xb8"),
    ("host joinParty argument check", 0x585F2D, b"\x3d"),
    ("lobby message protocol written by host", 0x8F3F40, b"\xbe"),
    ("lobby message protocol check on read", 0x8F4174, b"\x81\x3b"),
    ("protocol getter function", 0x64A510, b"\xb8"),
    # The host's own local player connects to its own server, so its client side must match too.
    ("local client connect userinfo protocol", 0x7274B4, b"\xbe"),
    ("local client connect string protocol", 0x7228E5, b"\x41\xb9"),
    ("local client joinParty protocol", 0x56E3C6, b"\xba"),
    ("server browser protocol filter", 0x71FDB8, b"\x3d"),
]
DVAR_PROTOCOL = 0x2BE3000  # dvar_t for "protocol" in the image's .bss
DVAR_NAME_STRING = 0xB5A1FD  # "protocol" string the dvar's name pointer must hold
DVAR_FIELDS = (0x28, 0x38, 0x48)  # current, latched, reset (type 5 = int)


def game_pid(dbg):
    for name, pid in dbg.processes():
        if name == "codmp.elf":
            return pid
    raise SystemExit("codmp.elf is not running on the console.")


def imm_address(addr, opcode):
    return addr + len(opcode)


def read_sites(dbg, pid):
    rows = []
    for desc, addr, opcode in SITES:
        raw = dbg.read(pid, addr, len(opcode) + 4)
        ok_opcode = raw[: len(opcode)] == opcode
        value = struct.unpack("<I", raw[len(opcode):])[0]
        rows.append((desc, addr, opcode, ok_opcode, value))
    return rows


def find_protocol_dvar(dbg, pid):
    """The dvar pool slot differs per launch; find the struct whose name points at "protocol"."""
    raw = dbg.read(pid, DVAR_PROTOCOL, 8)
    if struct.unpack("<Q", raw)[0] == DVAR_NAME_STRING:
        return DVAR_PROTOCOL
    needle = struct.pack("<Q", DVAR_NAME_STRING)
    start, end, step = 0x1000000, 0x3C9C000, 0x100000
    for base in range(start, end, step):
        blob = dbg.read(pid, base, min(step, end - base))
        pos = blob.find(needle)
        while pos != -1:
            if pos % 8 == 0:
                body = dbg.read(pid, base + pos, 0x20)
                if struct.unpack_from("<I", body, 0x1C)[0] == 5:  # dvar type int
                    return base + pos
            pos = blob.find(needle, pos + 1)
    raise SystemExit("Could not find the 'protocol' dvar; is BO1 fully loaded?")


def dvar_offsets(dbg, pid, value):
    global DVAR_PROTOCOL
    DVAR_PROTOCOL = find_protocol_dvar(dbg, pid)
    raw = dbg.read(pid, DVAR_PROTOCOL, 0x50)
    name_ptr = struct.unpack_from("<Q", raw, 0)[0]
    name = "protocol" if name_ptr == DVAR_NAME_STRING else f"<name ptr {name_ptr:#x}>"
    offs = [o for o in DVAR_FIELDS if struct.unpack_from("<I", raw, o)[0] == value]
    return DVAR_PROTOCOL, name, offs


def status(dbg, pid):
    for desc, addr, _, ok_opcode, value in read_sites(dbg, pid):
        state = "UNEXPECTED BYTES" if not ok_opcode else f"{value:#x}"
        print(f"  {addr:#x}  {state:>16}  {desc}")
    _, name, _ = dvar_offsets(dbg, pid, ORIGINAL)
    raw = dbg.read(pid, DVAR_PROTOCOL, 0x50)
    vals = [hex(struct.unpack_from("<I", raw, o)[0]) for o in DVAR_FIELDS]
    print(f"  dvar at {DVAR_PROTOCOL:#x} name='{name}' current/latched/reset = {vals}")


def write_all(dbg, pid, old, new):
    rows = read_sites(dbg, pid)
    bad = [r for r in rows if not r[3] or r[4] not in (old, new)]
    if bad:
        for desc, addr, _, _, value in bad:
            print(f"  refusing: {addr:#x} ({desc}) holds {value:#x}, expected {old:#x}")
        raise SystemExit("Nothing written: this is not the expected 01.08 build/state.")
    ptr, name, offs = dvar_offsets(dbg, pid, old)
    if name != "protocol":
        raise SystemExit(f"Nothing written: dvar pointer names '{name}', not 'protocol'.")
    for desc, addr, opcode, _, _ in rows:
        target = imm_address(addr, opcode)
        dbg.write(pid, target, struct.pack("<I", new))
        got = struct.unpack("<I", dbg.read(pid, target, 4))[0]
        print(f"  {addr:#x} -> {got:#x}  {'ok' if got == new else 'READBACK MISMATCH'}  {desc}")
    for off in offs:
        dbg.write(pid, ptr + off, struct.pack("<I", new))
    print(f"  dvar 'protocol' fields {offs} -> {new:#x}")
    (HERE / "protocol_patch_state.json").write_text(json.dumps({"active": new != ORIGINAL, "value": new}))


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    ip, action = sys.argv[1], sys.argv[2]
    try:
        dbg = PS4Debug(ip)
    except OSError as exc:
        raise SystemExit(f"Can't reach ps4debug on {ip}:744 ({exc}).\n"
                         "Check the PS4 is on, the IP is right, and the ps4debug payload is loaded.")
    try:
        pid = game_pid(dbg)
        if action == "status":
            status(dbg, pid)
        elif action == "apply":
            new = int(sys.argv[3], 0)
            current = read_sites(dbg, pid)[0][4]
            write_all(dbg, pid, current, new)
        elif action == "restore":
            current = read_sites(dbg, pid)[0][4]
            write_all(dbg, pid, current, ORIGINAL)
        else:
            raise SystemExit(__doc__)
    finally:
        dbg.close()


if __name__ == "__main__":
    main()
