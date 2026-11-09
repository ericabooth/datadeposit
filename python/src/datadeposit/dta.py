"""Read and write Stata .dta files (formats 117, 118, 119) with full metadata.

pandas and pyreadstat read the values of a .dta file but drop part of what
survey files carry: characteristics (where item text usually lives), notes,
the names of shared value label sets, label languages, and which extended
missing code (.a to .z) each missing value had. This module reads and writes
all of it, following Stata's published description of the format
(help dta). Writing always produces format 118, which Stata 14 and later read.
"""

import struct

import numpy as np

STR_L = 32768
T_DOUBLE, T_FLOAT, T_LONG, T_INT, T_BYTE = 65526, 65527, 65528, 65529, 65530
TYPE_NAMES = {T_DOUBLE: "double", T_FLOAT: "float", T_LONG: "long", T_INT: "int", T_BYTE: "byte", STR_L: "strL"}
NAME_CODES = {v: k for k, v in TYPE_NAMES.items()}

# smallest code of system missing, by type; .a to .z follow
MISS_INT = {T_BYTE: 101, T_INT: 32741, T_LONG: 2147483621}
MAX_INT = {T_BYTE: 100, T_INT: 32740, T_LONG: 2147483620}
FLOAT_MISS = 0x7F000000
DOUBLE_MISS = 0x7FE0000000000000


def type_code(name):
    if name in NAME_CODES:
        return NAME_CODES[name]
    if name.startswith("str"):
        return int(name[3:])
    raise ValueError("unknown Stata type %r" % name)


def type_width(code):
    if code <= 2045:
        return code
    return {STR_L: 8, T_DOUBLE: 8, T_FLOAT: 4, T_LONG: 4, T_INT: 2, T_BYTE: 1}[code]


class _Buf:
    """bytes-like view of an mmap with index() and startswith()."""

    def __init__(self, m):
        self.m = m

    def __getitem__(self, k):
        return self.m[k]

    def index(self, sub, start=0):
        i = self.m.find(sub, start)
        if i < 0:
            raise ValueError("%r not found in the .dta header" % sub)
        return i

    def startswith(self, sub):
        return self.m[:len(sub)] == sub

    def row_width(self, types):
        return sum(type_width(t) for t in types)


def _cstr(b):
    i = b.find(b"\0")
    return (b if i < 0 else b[:i]).decode("utf-8", errors="replace")


class Reader:
    def __init__(self, path):
        import mmap
        self._fh = open(path, "rb")
        self.buf = mmap.mmap(self._fh.fileno(), 0, access=mmap.ACCESS_READ)
        b = _Buf(self.buf)
        self.b = b
        if not b.startswith(b"<stata_dta>"):
            raise ValueError("%s is not a Stata 13+ (format 117+) .dta file" % path)
        rel = int(b[b.index(b"<release>") + 9:b.index(b"</release>")])
        if rel not in (117, 118, 119):
            raise ValueError("dta format %d is not supported (117, 118, 119 are)" % rel)
        self.release = rel
        bo = b[b.index(b"<byteorder>") + 11:b.index(b"</byteorder>")]
        self.e = "<" if bo == b"LSF" else ">"
        p = b.index(b"<K>") + 3
        self.K = struct.unpack(self.e + ("I" if rel == 119 else "H"), b[p:p + (4 if rel == 119 else 2)])[0]
        p = b.index(b"<N>") + 3
        self.N = struct.unpack(self.e + ("I" if rel == 117 else "Q"), b[p:p + (4 if rel == 117 else 8)])[0]
        p = b.index(b"<label>") + 7
        if rel == 117:
            ln = b[p]
            p += 1
        else:
            ln = struct.unpack(self.e + "H", b[p:p + 2])[0]
            p += 2
        self.label = b[p:p + ln].decode("utf-8", errors="replace")
        p = b.index(b"<map>") + 5
        self.map = struct.unpack(self.e + "14Q", b[p:p + 112])
        nlen = 33 if rel == 117 else 129
        self.nlen = nlen
        K = self.K
        p = self.map[2] + len(b"<variable_types>")
        self.types = list(struct.unpack(self.e + "%dH" % K, b[p:p + 2 * K]))
        p = self.map[3] + len(b"<varnames>")
        self.names = [_cstr(b[p + i * nlen:p + (i + 1) * nlen]) for i in range(K)]
        p = self.map[4] + len(b"<sortlist>")
        w = 4 if rel == 119 else 2
        sl = struct.unpack(self.e + "%d%s" % (K + 1, "I" if w == 4 else "H"), b[p:p + w * (K + 1)])
        self.sortlist = []
        for s in sl:
            if s == 0:
                break
            self.sortlist.append(self.names[s - 1])
        flen = 49 if rel == 117 else 57
        p = self.map[5] + len(b"<formats>")
        self.formats = [_cstr(b[p + i * flen:p + (i + 1) * flen]) for i in range(K)]
        p = self.map[6] + len(b"<value_label_names>")
        self.vlnames = [_cstr(b[p + i * nlen:p + (i + 1) * nlen]) for i in range(K)]
        llen = 81 if rel == 117 else 321
        p = self.map[7] + len(b"<variable_labels>")
        self.varlabels = [_cstr(b[p + i * llen:p + (i + 1) * llen]) for i in range(K)]
        self.chars = self._chars()
        self.value_labels = self._value_labels()

    def _chars(self):
        b, e = self.b, self.e
        p = self.map[8] + len(b"<characteristics>")
        end = self.map[9]
        out = []
        while p < end and b[p:p + 4] == b"<ch>":
            ln = struct.unpack(e + "I", b[p + 4:p + 8])[0]
            body = b[p + 8:p + 8 + ln]
            nl = self.nlen
            out.append((_cstr(body[:nl]), _cstr(body[nl:2 * nl]), _cstr(body[2 * nl:])))
            p += 8 + ln + 5
        return out

    def _value_labels(self):
        b, e = self.b, self.e
        p = self.map[11] + len(b"<value_labels>")
        end = self.map[12]
        out = {}
        while p < end and b[p:p + 5] == b"<lbl>":
            ln = struct.unpack(e + "I", b[p + 5:p + 9])[0]
            q = p + 9
            name = _cstr(b[q:q + self.nlen])
            q += self.nlen + 3
            n, txtlen = struct.unpack(e + "II", b[q:q + 8])
            q += 8
            offs = struct.unpack(e + "%dI" % n, b[q:q + 4 * n])
            q += 4 * n
            vals = struct.unpack(e + "%di" % n, b[q:q + 4 * n])
            q += 4 * n
            txt = b[q:q + txtlen]
            entries = []
            for o, v in zip(offs, vals):
                code = _int_code(v, T_LONG)
                entries.append((code, _cstr(txt[o:])))
            out[name] = entries
            p += 9 + self.nlen + 3 + ln + 6
        return out

    def close(self):
        self.buf.close()
        self._fh.close()

    def row_width(self):
        return sum(type_width(t) for t in self.types)

    def data(self):
        """Return {name: values} plus {name: extended letters} for every variable."""
        b, e, N, K = self.buf, self.e, self.N, self.K
        widths = [type_width(t) for t in self.types]
        fields = []
        for i, t in enumerate(self.types):
            if t <= 2045:
                fields.append(("v%d" % i, "S%d" % t))
            elif t == STR_L:
                fields.append(("v%d" % i, "V8"))
            else:
                fields.append(("v%d" % i, e + {T_DOUBLE: "u8", T_FLOAT: "u4", T_LONG: "i4",
                                                 T_INT: "i2", T_BYTE: "i1"}[t]))
        dt = np.dtype(fields)
        assert dt.itemsize == sum(widths)
        p = self.map[9] + len(b"<data>")
        rows = np.frombuffer(b, dtype=dt, count=N, offset=p) if N else np.zeros(0, dtype=dt)
        strls = self._strls() if STR_L in self.types else {}
        values, ext = {}, {}
        for i, t in enumerate(self.types):
            name = self.names[i]
            col = rows["v%d" % i]
            if t <= 2045:
                values[name] = np.array([_cstr(x) for x in col], dtype=object)
            elif t == STR_L:
                raw = col.tobytes()
                out = np.empty(N, dtype=object)
                for r in range(N):
                    v, o = self._vo(raw[8 * r:8 * r + 8])
                    out[r] = strls.get((v, o), "") if (v or o) else ""
                values[name] = out
            elif t in (T_BYTE, T_INT, T_LONG):
                x = col.astype(np.int64)
                miss = x > MAX_INT[t]
                vals = x.astype(np.float64)
                vals[miss] = np.nan
                values[name] = vals
                letters = np.where(miss, x - MISS_INT[t], 0)
                if (letters > 0).any():
                    ext[name] = letters.astype(np.int8)
            elif t == T_FLOAT:
                u = col.astype(np.uint32)
                f = u.view(np.float32).astype(np.float64)
                miss = (u >= FLOAT_MISS) & (u < 0x80000000)
                f[miss] = np.nan
                values[name] = f
                letters = np.where(miss, (u.astype(np.int64) - FLOAT_MISS) >> 11, 0)
                if (letters > 0).any():
                    ext[name] = letters.astype(np.int8)
            else:
                u = col.astype(np.uint64)
                f = u.view(np.float64).copy()
                miss = (u >= np.uint64(DOUBLE_MISS)) & (u < np.uint64(0x8000000000000000))
                f[miss] = np.nan
                values[name] = f
                letters = np.where(miss, ((u - np.uint64(DOUBLE_MISS)) >> np.uint64(40)).astype(np.int64), 0)
                if (letters > 0).any():
                    ext[name] = letters.astype(np.int8)
        return values, ext

    def _vo(self, raw8):
        e = self.e
        if self.release == 117:
            return struct.unpack(e + "II", raw8)
        if self.release == 118:
            if e == "<":
                v = int.from_bytes(raw8[:2], "little")
                o = int.from_bytes(raw8[2:], "little")
            else:
                v = int.from_bytes(raw8[:2], "big")
                o = int.from_bytes(raw8[2:], "big")
            return v, o
        if e == "<":
            return int.from_bytes(raw8[:3], "little"), int.from_bytes(raw8[3:], "little")
        return int.from_bytes(raw8[:3], "big"), int.from_bytes(raw8[3:], "big")

    def _strls(self):
        b, e = self.b, self.e
        p = self.map[10] + len(b"<strls>")
        end = self.map[11]
        out = {}
        olen = 4 if self.release == 117 else 8
        while p < end and b[p:p + 3] == b"GSO":
            v = struct.unpack(e + "I", b[p + 3:p + 7])[0]
            o = struct.unpack(e + ("I" if olen == 4 else "Q"), b[p + 7:p + 7 + olen])[0]
            q = p + 7 + olen
            t = b[q]
            ln = struct.unpack(e + "I", b[q + 1:q + 5])[0]
            body = b[q + 5:q + 5 + ln]
            if t == 130 and body.endswith(b"\0"):
                body = body[:-1]
            out[(v, o)] = body.decode("utf-8", errors="replace")
            p = q + 5 + ln
        return out


def _int_code(v, t):
    """Value label values are long; codes past the valid range are .a to .z."""
    if v > MAX_INT[t]:
        k = v - MISS_INT[t]
        return "." + chr(96 + k) if k > 0 else "."
    return v


# ----------------------------------------------------------------------------
# writing (format 118, little-endian)
# ----------------------------------------------------------------------------

def _fixed(s, n):
    b = s.encode("utf-8")[:n - 1]
    return b + b"\0" * (n - len(b))


def write(path, table):
    """Write a datadeposit Table (see table.py) to a format-118 .dta file."""
    e = "<"
    cols = table.columns
    K, N = len(cols), table.nobs
    types = [type_code(c.stata_type) for c in cols]
    out = bytearray()
    out += b"<stata_dta><header><release>118</release><byteorder>LSF</byteorder>"
    out += b"<K>" + struct.pack(e + "H", K) + b"</K>"
    out += b"<N>" + struct.pack(e + "Q", N) + b"</N>"
    lab = table.label.encode("utf-8")[:320]
    out += b"<label>" + struct.pack(e + "H", len(lab)) + lab + b"</label>"
    out += b"<timestamp>" + b"\0" + b"</timestamp></header>"
    offs = [0] * 14
    offs[1] = len(out)
    out += b"<map>" + b"\0" * 112 + b"</map>"
    sections = []

    def section(idx, payload):
        offs[idx] = len(out)
        out.extend(payload)

    section(2, b"<variable_types>" + struct.pack(e + "%dH" % K, *types) + b"</variable_types>")
    section(3, b"<varnames>" + b"".join(_fixed(c.stata_name, 129) for c in cols) + b"</varnames>")
    names = [c.stata_name for c in cols]
    sl = [names.index(s) + 1 for s in table.sortedby if s in names] + [0]
    sl += [0] * (K + 1 - len(sl))
    section(4, b"<sortlist>" + struct.pack(e + "%dH" % (K + 1), *sl[:K + 1]) + b"</sortlist>")
    section(5, b"<formats>" + b"".join(_fixed(c.format, 57) for c in cols) + b"</formats>")
    section(6, b"<value_label_names>" + b"".join(_fixed(c.value_labels, 129) for c in cols) + b"</value_label_names>")
    section(7, b"<variable_labels>" + b"".join(_fixed(_lab80(c.label), 321) for c in cols) + b"</variable_labels>")
    ch = bytearray(b"<characteristics>")
    for var, name, text in table.stata_chars():
        body = _fixed(var, 129) + _fixed(name, 129) + text.encode("utf-8") + b"\0"
        ch += b"<ch>" + struct.pack(e + "I", len(body)) + body + b"</ch>"
    ch += b"</characteristics>"
    section(8, bytes(ch))

    # data
    fields = []
    for i, t in enumerate(types):
        if t <= 2045:
            fields.append(("v%d" % i, "S%d" % t))
        elif t == STR_L:
            fields.append(("v%d" % i, "V8"))
        else:
            fields.append(("v%d" % i, {T_DOUBLE: "<u8", T_FLOAT: "<u4", T_LONG: "<i4", T_INT: "<i2", T_BYTE: "<i1"}[t]))
    rows = np.zeros(N, dtype=np.dtype(fields))
    gso = bytearray()
    for i, (c, t) in enumerate(zip(cols, types)):
        f = "v%d" % i
        if t <= 2045:
            rows[f] = [s.encode("utf-8")[:t] for s in c.values]
        elif t == STR_L:
            vo = np.zeros((N, 8), dtype=np.uint8)
            for r, s in enumerate(c.values):
                if s == "":
                    continue
                v, o = i + 1, r + 1
                vo[r, :2] = np.frombuffer(struct.pack("<H", v), dtype=np.uint8)
                vo[r, 2:] = np.frombuffer(struct.pack("<Q", o)[:6], dtype=np.uint8)
                body = s.encode("utf-8") + b"\0"
                gso += b"GSO" + struct.pack("<IQ", v, o) + bytes([130]) + struct.pack("<I", len(body)) + body
            rows[f] = vo.view("V8").reshape(N)
        else:
            x = np.asarray(c.values, dtype=np.float64)
            letters = c.ext if c.ext is not None else np.zeros(N, dtype=np.int8)
            miss = np.isnan(x)
            if t in (T_BYTE, T_INT, T_LONG):
                code = np.where(miss, MISS_INT[t] + letters.astype(np.int64), np.nan_to_num(x).astype(np.int64))
                rows[f] = code
            elif t == T_FLOAT:
                u = x.astype(np.float32).view(np.uint32).astype(np.uint64)
                u = np.where(miss, FLOAT_MISS + (letters.astype(np.uint64) << np.uint64(11)), u)
                rows[f] = u.astype(np.uint32)
            else:
                u = x.view(np.uint64)
                u = np.where(miss, np.uint64(DOUBLE_MISS) + (letters.astype(np.uint64) << np.uint64(40)), u)
                rows[f] = u
    section(9, b"<data>" + rows.tobytes() + b"</data>")
    section(10, b"<strls>" + bytes(gso) + b"</strls>")
    vl = bytearray(b"<value_labels>")
    for name, entries in table.value_label_sets.items():
        txt = bytearray()
        offsets, vals = [], []
        for val, label in entries:
            offsets.append(len(txt))
            vals.append(_long_code(val))
            txt += label.encode("utf-8") + b"\0"
        n = len(entries)
        body = struct.pack("<II", n, len(txt)) + struct.pack("<%dI" % n, *offsets) + \
            struct.pack("<%di" % n, *vals) + bytes(txt)
        vl += b"<lbl>" + struct.pack("<I", len(body)) + _fixed(name, 129) + b"\0\0\0" + body + b"</lbl>"
    vl += b"</value_labels>"
    section(11, bytes(vl))
    offs[12] = len(out)
    out += b"</stata_dta>"
    offs[13] = len(out)
    out[offs[1] + 5:offs[1] + 5 + 112] = struct.pack("<14Q", *offs)
    with open(path, "wb") as fh:
        fh.write(out)


def _long_code(val):
    if isinstance(val, str):
        k = ord(val[1]) - 96 if len(val) == 2 else 0
        return MISS_INT[T_LONG] + k
    return int(val)


def _lab80(s):
    """Stata stores at most 80 characters of a variable label."""
    return s[:80]
