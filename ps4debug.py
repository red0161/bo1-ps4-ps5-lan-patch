"""Minimal read-only-by-default ps4debug client (golden's ps4debug protocol, TCP 744)."""
import socket
import struct

MAGIC = 0xFFAABBCC
CMD_PROC_LIST = 0xBDAA0001
CMD_PROC_READ = 0xBDAA0002
CMD_PROC_WRITE = 0xBDAA0003
CMD_PROC_MAPS = 0xBDAA0004
CMD_PROC_ALLOC = 0xBDAA000B
STATUS_SUCCESS = 0x80000000
MAX_CHUNK = 0x10000


class PS4DebugError(Exception):
    pass


class PS4Debug:
    def __init__(self, ip, port=744, timeout=10):
        self.sock = socket.create_connection((ip, port), timeout=timeout)

    def close(self):
        self.sock.close()

    def _recv(self, n):
        buf = bytearray()
        while len(buf) < n:
            part = self.sock.recv(n - len(buf))
            if not part:
                raise PS4DebugError("connection closed by console")
            buf += part
        return bytes(buf)

    def _status(self, what):
        status = struct.unpack("<I", self._recv(4))[0]
        if status != STATUS_SUCCESS:
            raise PS4DebugError(f"{what} failed: status 0x{status:08X}")

    def _command(self, cmd, data=b""):
        self.sock.sendall(struct.pack("<III", MAGIC, cmd, len(data)))
        if data:
            self.sock.sendall(data)
        self._status(f"command 0x{cmd:08X}")

    def processes(self):
        self._command(CMD_PROC_LIST)
        count = struct.unpack("<I", self._recv(4))[0]
        procs = []
        for _ in range(count):
            raw = self._recv(36)
            name = raw[:32].split(b"\0", 1)[0].decode(errors="replace")
            procs.append((name, struct.unpack("<i", raw[32:])[0]))
        return procs

    def maps(self, pid):
        self._command(CMD_PROC_MAPS, struct.pack("<i", pid))
        count = struct.unpack("<I", self._recv(4))[0]
        entries = []
        for _ in range(count):
            raw = self._recv(58)
            name = raw[:32].split(b"\0", 1)[0].decode(errors="replace")
            start, end, offset, prot = struct.unpack("<QQQH", raw[32:])
            entries.append({"name": name, "start": start, "end": end,
                            "offset": offset, "prot": prot})
        return entries

    def read(self, pid, address, length):
        out = bytearray()
        while length > 0:
            n = min(length, MAX_CHUNK)
            self._command(CMD_PROC_READ, struct.pack("<iQI", pid, address, n))
            out += self._recv(n)
            address += n
            length -= n
        return bytes(out)

    def alloc(self, pid, length):
        self._command(CMD_PROC_ALLOC, struct.pack("<iI", pid, length))
        return struct.unpack("<Q", self._recv(8))[0]

    def write(self, pid, address, data):
        self._command(CMD_PROC_WRITE, struct.pack("<iQI", pid, address, len(data)))
        self.sock.sendall(data)
        self._status("write data")
