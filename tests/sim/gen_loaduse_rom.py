#!/usr/bin/env python3
"""Load-use repro ROMs for tests/sim/tb_cpu_loaduse.vhd (8 KiB, LE words at 0xBFC00000).

Replays F_E4B0's 8802E508..8802E528 sequence in a loop, with sp % 32 == 8 so
sp+28 (index) and sp+36 (the sw) share a 32-byte line, as on the board.
Ends in `done` (0x9FC00800) or `fail` (0x9FC00900) self-loops.

usage: gen.py OUT NOPS STORES EVICT ITERS
"""
import struct, sys

R = dict(zero=0, at=1, v0=2, v1=3, a0=4, t0=8, t4=12, t5=13, t6=14, t7=15,
         s0=16, s1=17, t8=24, t9=25, sp=29, ra=31)
def rt(f, rs=0, rt_=0, rd=0, sa=0): return (rs << 21) | (rt_ << 16) | (rd << 11) | (sa << 6) | f
def it(op, rs, rt_, imm): return (op << 26) | (rs << 21) | (rt_ << 16) | (imm & 0xFFFF)
def sll(d, t, s): return rt(0x00, 0, R[t], R[d], s)
def addu(d, s, t): return rt(0x21, R[s], R[t], R[d])
def jr(s): return rt(0x08, R[s])
def addiu(t, s, i): return it(0x09, R[s], R[t], i)
def ori(t, s, i): return it(0x0D, R[s], R[t], i)
def lui(t, i): return it(0x0F, 0, R[t], i)
def lw(t, o, s): return it(0x23, R[s], R[t], o)
def sw(t, o, s): return it(0x2B, R[s], R[t], o)
NOP = 0

out, nops, stores, evict, iters = sys.argv[1], *map(int, sys.argv[2:6])
words = {}
def emit(base, seq):
    for i, w in enumerate(seq):
        words[base + 4 * i] = w

# 0xBFC00000 (uncached): jump to the cached alias of 0x40.
emit(0x000, [lui('t0', int(__import__('os').environ.get('SEG','0x9FC0'),16)), ori('t0', 't0', 0x0040), jr('t0'), NOP])

body = [lui('sp', 0x8800), ori('sp', 'sp', 0xF108),   # sp = 0x8800F108, %32 == 8
        addiu('v1', 'zero', 1),                         # index = 1
        addiu('v0', 'zero', 0),                         # iteration
        addiu('s0', 'zero', iters),
        addiu('s1', 'zero', 4)]                         # expected t8
loop = 0x040 + 4 * len(body)
lb = []
lb += [NOP] * nops
for k in range(stores):                                 # other lines: fill the write FIFO
    lb.append(sw('v0', -64 - 32 * k, 'sp'))
lb += [addiu('t7', 'sp', 44),                           # 8802E4C4: sentinel t7
       sw('v1', 28, 'sp'),                              # index slot
       sw('v1', 48, 'sp')]                              # 8802E4CC-like setup store
if evict:                                               # same index, other tags
    lb += [lw('t9', 28 - 0x2000, 'sp'), lw('t9', 28 - 0x4000, 'sp')]
lb += [lw('t4', 28, 'sp'),                              # E508
       sll('t5', 't4', 2),                              # E50C
       addu('t6', 'sp', 't5'),                          # E510
       sw('v0', 32, 't6'),                              # E514  sp+36, same line
       lw('t7', 28, 'sp'),                              # E518
       sll('t8', 't7', 2),                              # E51C  <- the bad one
       addu('a0', 'sp', 't8'),                          # E520
       None,                                            # E524  jal callee
       lw('a0', 44, 'a0'),                              # E528  delay slot
       None,                                            # bne t8,s1,fail
       NOP,
       addiu('v0', 'v0', 1),
       None,                                            # bne v0,s0,loop
       NOP,
       None, NOP]                                       # j done
emit(0x040, body)
pc = loop
seq = []
for w in lb:
    seq.append(w)
DONE, FAIL, CALLEE = 0x800, 0x900, 0xA00
def jal_(t): return (0x03 << 26) | (((0x9FC00000 + t) >> 2) & 0x03FFFFFF)
def j_(t): return (0x02 << 26) | (((0x9FC00000 + t) >> 2) & 0x03FFFFFF)
def bne(s, t, frm, to): return it(0x05, R[s], R[t], (to - (frm + 4)) // 4)
holes = [i for i, w in enumerate(seq) if w is None]
seq[holes[0]] = jal_(CALLEE)
seq[holes[1]] = bne('t8', 's1', loop + 4 * holes[1], FAIL)
seq[holes[2]] = bne('v0', 's0', loop + 4 * holes[2], loop)
seq[holes[3]] = j_(DONE)
emit(loop, seq)
emit(DONE, [j_(DONE), NOP])
emit(FAIL, [j_(FAIL), NOP])
emit(CALLEE, [addiu('sp', 'sp', -48), sw('ra', 28, 'sp'), sw('a0', 48, 'sp'),
              sw('zero', 44, 'sp'), lw('t9', 48, 'sp'), lw('ra', 28, 'sp'),
              jr('ra'), addiu('sp', 'sp', 48)])
img = bytearray(8192)
for a, w in words.items():
    img[a:a + 4] = struct.pack('<I', w)
open(out, 'wb').write(img)
