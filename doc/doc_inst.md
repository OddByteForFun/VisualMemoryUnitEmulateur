# Instructions LC86K

Le LC86K possède 70 instructions (p561 du manuel).

## Tableau des instructions

### Arithmetic instructions

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| ADD | `0x81` | #i8 | CY AC OV P | ACC ← ACC + i8 |
| ADD | `0x82-0x83` | d9 | CY AC OV P | ACC ← ACC + (d9) |
| ADD | `0x84-0x87` | @Ri | CY AC OV P | ACC ← ACC + ((Ri)) |
| ADDC | `0x91` | #i8 | CY AC OV P | ACC ← ACC + i8 + CY |
| ADDC | `0x92-0x93` | d9 | CY AC OV P | ACC ← ACC + (d9) + CY |
| ADDC | `0x94-0x97` | @Ri | CY AC OV P | ACC ← ACC + ((Ri)) + CY |
| SUB | `0xA1` | #i8 | CY AC OV P | ACC ← ACC − i8 |
| SUB | `0xA2-0xA3` | d9 | CY AC OV P | ACC ← ACC − (d9) |
| SUB | `0xA4-0xA7` | @Ri | CY AC OV P | ACC ← ACC − ((Ri)) |
| SUBC | `0xB1` | #i8 | CY AC OV P | ACC ← ACC − i8 − CY |
| SUBC | `0xB2-0xB3` | d9 | CY AC OV P | ACC ← ACC − (d9) − CY |
| SUBC | `0xB4-0xB7` | @Ri | CY AC OV P | ACC ← ACC − ((Ri)) − CY |
| INC | `0x62-0x63` | d9 | P | (d9) ← (d9) + 1 |
| INC | `0x64-0x67` | @Ri | P | ((Ri)) ← ((Ri)) + 1 |
| DEC | `0x72-0x73` | d9 | P | (d9) ← (d9) − 1 |
| DEC | `0x74-0x77` | @Ri | P | ((Ri)) ← ((Ri)) − 1 |
| MUL | `0x30` | impl | CY=0, OV | B:ACC:C ← (ACC:C) × B |
| DIV | `0x40` | impl | CY=0, OV | ACC:C, mod(B) ← (ACC:C) ÷ B |

### Logical instructions

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| AND | `0xE1` | #i8 | P | ACC ← ACC & i8 |
| AND | `0xE2-0xE3` | d9 | P | ACC ← ACC & (d9) |
| AND | `0xE4-0xE7` | @Ri | P | ACC ← ACC & ((Ri)) |
| OR | `0xD1` | #i8 | P | ACC ← ACC \| i8 |
| OR | `0xD2-0xD3` | d9 | P | ACC ← ACC \| (d9) |
| OR | `0xD4-0xD7` | @Ri | P | ACC ← ACC \| ((Ri)) |
| XOR | `0xF1` | #i8 | P | ACC ← ACC ^ i8 |
| XOR | `0xF2-0xF3` | d9 | P | ACC ← ACC ^ (d9) |
| XOR | `0xF4-0xF7` | @Ri | P | ACC ← ACC ^ ((Ri)) |
| ROL | `0xE0` | impl | CY | rotate left through ACC, LSB ← MSB |
| ROLC | `0xF0` | impl | CY | rotate left through ACC via CY |
| ROR | `0xC0` | impl | CY | rotate right through ACC, MSB ← LSB |
| RORC | `0xD0` | impl | CY | rotate right through ACC via CY |

### Data transfer instructions

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| LD | `0x02-0x03` | d9 | — | ACC ← (d9) |
| LD | `0x04-0x07` | @Ri | — | ACC ← ((Ri)) |
| ST | `0x12-0x13` | d9 | — | (d9) ← ACC |
| ST | `0x14-0x17` | @Ri | — | ((Ri)) ← ACC |
| MOV | `0x22-0x23` | d9, #i8 | — | (d9) ← i8 |
| MOV | `0x24-0x27` | @Ri, #i8 | — | ((Ri)) ← i8 |
| LDC | `0xC1` | impl | — | ACC ← (BNK)(TRR + ACC) |
| PUSH | `0x60-0x61` | d9 | — | SP++ ; (SP) ← (d9) |
| POP | `0x70-0x71` | d9 | — | (d9) ← (SP) ; SP−− |
| XCH | `0xC2-0xC3` | d9 | — | swap ACC ↔ (d9) |
| XCH | `0xC4-0xC7` | @Ri | — | swap ACC ↔ ((Ri)) |

### Jump instructions

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| BR | `0x01` | r8 | — | PC ← PC + r8 (sign-extended) |
| BRF | `0x11` | r16 | — | PC ← PC + r16 − 1 |
| JMP | `0x28-0x2F, 0x38-0x3F` | a12 | — | PC ← (PC & 0xF000) \| a12 |
| JMPF | `0x21` | a16 | — | PC ← a16, commit bank switch |

### Conditional branch instructions

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| BZ | `0x80` | r8 | — | if ACC == 0 → PC ← PC + r8 |
| BNZ | `0x90` | r8 | — | if ACC ≠ 0 → PC ← PC + r8 |
| BP | `0x68-0x6F, 0x78-0x7F` | d9, b3, r8 | — | if bit(d9,b3)=1 → PC ← PC + r8 |
| BN | `0x88-0x8F, 0x98-0x9F` | d9, b3, r8 | — | if bit(d9,b3)=0 → PC ← PC + r8 |
| BPC | `0x48-0x4F, 0x58-0x5F` | d9, b3, r8 | — | if bit(d9,b3)=1 → PC ← PC + r8; clear bit |
| BE | `0x31` | #i8, r8 | CY | if ACC == i8 → PC ← PC + r8 ; CY ← ACC < i8 |
| BE | `0x32-0x33` | d9, r8 | CY | if ACC == (d9) → PC ← PC + r8 ; CY ← ACC < (d9) |
| BE | `0x34-0x37` | @Ri, r8 | CY | if ACC == ((Ri)) → PC ← PC + r8 ; CY ← ACC < ((Ri)) |
| BNE | `0x41` | #i8, r8 | CY | if ACC ≠ i8 → PC ← PC + r8 ; CY ← ACC < i8 |
| BNE | `0x42-0x43` | d9, r8 | CY | if ACC ≠ (d9) → PC ← PC + r8 ; CY ← ACC < (d9) |
| BNE | `0x44-0x47` | @Ri, r8 | CY | if ACC ≠ ((Ri)) → PC ← PC + r8 ; CY ← ACC < ((Ri)) |
| DBNZ | `0x52-0x53` | d9, r8 | — | (d9) ← (d9) − 1 ; if (d9) ≠ 0 → PC ← PC + r8 |
| DBNZ | `0x54-0x57` | @Ri, r8 | — | ((Ri)) ← ((Ri)) − 1 ; if ((Ri)) ≠ 0 → PC ← PC + r8 |

### Subroutine instructions

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| CALL | `0x08-0x0F, 0x18-0x1F` | a12 | — | push PC ; PC ← (PC & 0xF000) \| a12 |
| CALLR | `0x10` | r16 | — | push PC ; PC ← PC + r16 − 1 |
| CALLF | `0x20` | a16 | — | push PC ; PC ← a16 ; commit bank switch |
| RET | `0xA0` | impl | — | PC ← pop() |
| RETI | `0xB0` | impl | — | PC ← pop() ; enable interrupts |

### Bit manipulation instructions

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| CLR1 | `0xC8-0xCF, 0xD8-0xDF` | d9, b3 | — | (d9,b3) ← 0 |
| SET1 | `0xE8-0xEF, 0xF8-0xFF` | d9, b3 | — | (d9,b3) ← 1 |
| NOT1 | `0xA8-0xAF, 0xB8-0xBF` | d9, b3 | — | (d9,b3) ← ¬(d9,b3) |

### Miscellaneous

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| NOP | `0x00` | impl | — | no operation |

### Macro instruction

| Inst | Opcodes | Mode | Flags | Description |
|------|---------|------|-------|-------------|
| CHANGE | `0xE1` + `0xF1` | #i8, #i8 | P | AND mask1, XOR mask2 (2-word macro) |

## Etat d'avancement

| Instruction | Opcode(s) | Impl. | VMC |
|-------------|-----------|:-----:|-----|
| nop | 0x00 | 🟢 | À faire |
| br | 0x01 | 🟢 | À faire |
| ld | 0x02–0x03 | 🟢 | VMC-185, VMC-186 |
| ld_ri | 0x04–0x07 | 🟢 | VMC-186 |
| call_a12 | 0x08–0x0F, 0x18–0x1F | 🟢 | VMC-213 |
| callr | 0x10 | 🟢 | À faire |
| brf | 0x11 | 🟢 | À faire |
| st | 0x12–0x13 | 🟢 | VMC-187, VMC-188 |
| st_ri | 0x14–0x17 | 🟢 | VMC-188 |
| callf | 0x20 | 🟢 | VMC-214 |
| jmpf | 0x21 | 🟢 | VMC-197 |
| mov | 0x22–0x23 | 🟢 | VMC-189 |
| mov_ri | 0x24–0x27 | 🟢 | VMC-190 |
| jmp_a12 | 0x28–0x2F, 0x38–0x3F | 🟢 | VMC-196 |
| mul | 0x30 | 🟢 | À faire |
| be_imm | 0x31 | 🟢 | VMC-207 |
| be_d9 | 0x32–0x33 | 🟢 | À faire |
| be_ri | 0x34–0x37 | 🟢 | À faire |
| div | 0x40 | 🟢 | À faire |
| bne_imm | 0x41 | 🟢 | VMC-210 |
| bne_d9 | 0x42–0x43 | 🟢 | À faire |
| bne_ri | 0x44–0x47 | 🟢 | À faire |
| bpc | 0x48–0x4F, 0x58–0x5F | 🟢 | VMC-203 |
| dbnz_d9 | 0x52–0x53 | 🟢 | VMC-205 |
| dbnz_ri | 0x54–0x57 | 🟢 | À faire |
| push | 0x60–0x61 | 🟢 | VMC-192 |
| inc_d9 | 0x62–0x63 | 🟢 | VMC-166 |
| inc_ri | 0x64–0x67 | 🟢 | VMC-167 |
| bp | 0x68–0x6F, 0x78–0x7F | 🟢 | À faire |
| pop | 0x70–0x71 | 🟢 | VMC-192 |
| dec_d9 | 0x72–0x73 | 🟢 | VMC-168 |
| dec_ri | 0x74–0x77 | 🟢 | À faire |
| bz | 0x80 | 🟢 | VMC-200 |
| add_imm | 0x81 | 🟢 | VMC-156 |
| add_d9 | 0x82–0x83 | 🟢 | VMC-156 |
| add_ri | 0x84–0x87 | 🟢 | VMC-157 |
| bn | 0x88–0x8F, 0x98–0x9F | 🟢 | À faire |
| bnz | 0x90 | 🟢 | À faire |
| addc_imm | 0x91 | 🟢 | VMC-158, VMC-159 |
| addc_d9 | 0x92–0x93 | 🟢 | VMC-159 |
| addc_ri | 0x94–0x97 | 🟢 | À faire |
| ret | 0xA0 | 🟢 | VMC-213, VMC-214 |
| sub_imm | 0xA1 | 🟢 | VMC-160 |
| sub_d9 | 0xA2–0xA3 | 🟢 | VMC-161 |
| sub_ri | 0xA4–0xA7 | 🟢 | VMC-162 |
| not1 | 0xA8–0xAF, 0xB8–0xBF | 🟢 | À faire |
| reti | 0xB0 | 🟢 | À faire |
| subc_imm | 0xB1 | 🟢 | VMC-163 |
| subc_d9 | 0xB2–0xB3 | 🟢 | VMC-164 |
| subc_ri | 0xB4–0xB7 | 🟢 | VMC-165, VMC-166 |
| ror | 0xC0 | 🟢 | VMC-183 |
| ldc | 0xC1 | 🟢 | À faire |
| xch_d9 | 0xC2–0xC3 | 🟢 | VMC-194 |
| xch_ri | 0xC4–0xC7 | 🟢 | VMC-195 |
| clr1 | 0xC8–0xCF, 0xD8–0xDF | 🟢 | VMC-218 |
| rorc | 0xD0 | 🟢 | VMC-184 |
| or_imm | 0xD1 | 🟢 | VMC-175 |
| or_d9 | 0xD2–0xD3 | 🟢 | VMC-176 |
| or_ri | 0xD4–0xD7 | 🟢 | VMC-177 |
| rol | 0xE0 | 🟢 | VMC-181 |
| and_imm | 0xE1 | 🟢 | VMC-173 |
| and_d9 | 0xE2–0xE3 | 🟢 | VMC-173 |
| and_ri | 0xE4–0xE7 | 🟢 | VMC-174 |
| set1 | 0xE8–0xEF, 0xF8–0xFF | 🟢 | À faire |
| rolc | 0xF0 | 🟢 | VMC-182 |
| xor_imm | 0xF1 | 🟢 | VMC-178 |
| xor_d9 | 0xF2–0xF3 | 🟢 | VMC-179 |
| xor_ri | 0xF4–0xF7 | 🟢 | VMC-180 |

## Résumé

| Status | Nb instructions |
|--------|:--------------:|
| 🟢 implémenté | 68 |
| 🟢 VMC testé | 53 |
| 🔴 À faire | 15 |

**Tests :** 53/53 passent ✅ (`zig build test`).  
Les tests sont les exemples VMC-XXX du **Sanyo LC86K Series Programming Manual** (doc/VMU.txt, section VMC-151 à VMC-224). Chaque test référence le numéro d'exemple (e.g. VMC-159, VMC-167) comme spécification de référence.
