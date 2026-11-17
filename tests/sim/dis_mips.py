import struct,sys
import os
_p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                  '..', '..', 'decompressed_ram.bin')
d = open(_p, 'rb').read()
BASE=0x88000000
def w(a):
    o=a-BASE
    return struct.unpack('<I',d[o:o+4])[0]
R={0:'zero',1:'at',2:'v0',3:'v1',4:'a0',5:'a1',6:'a2',7:'a3',8:'t0',9:'t1',10:'t2',11:'t3',12:'t4',13:'t5',14:'t6',15:'t7',16:'s0',17:'s1',18:'s2',19:'s3',20:'s4',21:'s5',22:'s6',23:'s7',24:'t8',25:'t9',26:'k0',27:'k1',28:'gp',29:'sp',30:'fp',31:'ra'}
def r(x): return '$'+R[x]
def dis(a):
    i=w(a); op=i>>26; rs=(i>>21)&31; rt=(i>>16)&31; rd=(i>>11)&31; sa=(i>>6)&31; fn=i&63
    imm=i&0xffff; simm=imm-0x10000 if imm&0x8000 else imm
    tgt=(a+4)&0xf0000000 | ((i&0x3ffffff)<<2)
    if i==0: return 'nop'
    if op==0:
        if fn==0: return f'sll {r(rd)},{r(rt)},{sa}'
        if fn==2: return f'srl {r(rd)},{r(rt)},{sa}'
        if fn==3: return f'sra {r(rd)},{r(rt)},{sa}'
        if fn==4: return f'sllv {r(rd)},{r(rt)},{r(rs)}'
        if fn==6: return f'srlv {r(rd)},{r(rt)},{r(rs)}'
        if fn==7: return f'srav {r(rd)},{r(rt)},{r(rs)}'
        if fn==8: return f'jr {r(rs)}'
        if fn==9: return f'jalr {r(rd)},{r(rs)}'
        if fn==0x10: return f'mfhi {r(rd)}'
        if fn==0x11: return f'mthi {r(rs)}'
        if fn==0x12: return f'mflo {r(rd)}'
        if fn==0x13: return f'mtlo {r(rs)}'
        if fn==0x18: return f'mult {r(rs)},{r(rt)}'
        if fn==0x19: return f'multu {r(rs)},{r(rt)}'
        if fn==0x1a: return f'div {r(rs)},{r(rt)}'
        if fn==0x1b: return f'divu {r(rs)},{r(rt)}'
        if fn==0x2a: return f'slt {r(rd)},{r(rs)},{r(rt)}'
        if fn==0x2b: return f'sltu {r(rd)},{r(rs)},{r(rt)}'
        return f'spec fn={fn:#x} {i:#010x}'
    if op==1: return f'regimm(rt={rt}) {r(rs)},{a+4+simm*4:#x}'
    if op==2: return f'j {tgt:#x}'
    if op==3: return f'jal {tgt:#x}'
    if op==4: return f'beq {r(rs)},{r(rt)},{a+4+simm*4:#x}'
    if op==5: return f'bne {r(rs)},{r(rt)},{a+4+simm*4:#x}'
    if op==6: return f'blez {r(rs)},{a+4+simm*4:#x}'
    if op==7: return f'bgtz {r(rs)},{a+4+simm*4:#x}'
    if op==8: return f'addi {r(rt)},{r(rs)},{simm}'
    if op==9: return f'addiu {r(rt)},{r(rs)},{simm}'
    if op==0xa: return f'slti {r(rt)},{r(rs)},{simm}'
    if op==0xb: return f'sltiu {r(rt)},{r(rs)},{simm}'
    if op==0xc: return f'andi {r(rt)},{r(rs)},{imm:#x}'
    if op==0xd: return f'ori {r(rt)},{r(rs)},{imm:#x}'
    if op==0xe: return f'xori {r(rt)},{r(rs)},{imm:#x}'
    if op==0xf: return f'lui {r(rt)},{imm:#x}'
    if op==0x10:
        m={0:'mfc0',4:'mtc0',0x10:'tlb'}.get(rs,str(rs))
        return f'cop0 {m} {r(rt)},{rd}'
    if op==0x11: return f'cop1 {i:#010x}'
    if op==0x12: return f'cop2 op={rs} {r(rt)},{rd}'
    L={0x20:('lb',1),0x21:('lh',2),0x23:('lw',4),0x24:('lbu',1),0x25:('lhu',2),0x26:('lwr',4),0x27:('lwu',4),
       0x1a:('ldl',8),0x1b:('ldr',8),0x37:('ld',8),
       0x28:('sb',1),0x29:('sh',2),0x2b:('sw',4),0x2e:('swr',4),0x2a:('swl',4),
       0x3c:('sdl',8),0x3d:('sdr',8),0x3f:('sd',8),0x30:('ll',4),0x38:('sc',4)}
    if op in L:
        n=L[op][0]; return f'{n} {r(rt)},{simm}({r(rs)})'
    if op==0x2f: return f'cache {rt:#x},{simm}({r(rs)})'
    return f'op{op:#x} {i:#010x}'
if __name__=='__main__':
    s=int(sys.argv[1],16); e=int(sys.argv[2],16)
    a=s
    while a<e:
        print(f'{a:08x} {w(a):08x}  {dis(a)}')
        a+=4
