# Loader / boot / input regression benches

Run all four from the repository root:

```sh
tests/sim/run.sh
```

They need [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`,
`vvp`) on `PATH`. Build products go to `build/sim/`, which is gitignored.

| Bench | What it proves |
|---|---|
| `tb_input_chord.sv` | Start + Select fires once inside the window, never on a lone press, never repeats while held, and fires again after release. |
| `tb_boot_ctrl.sv` | `loader_reset` is a power-on one-shot (a late unlock does not re-arm it), the watchdog asserts `loader_abort`, and `boot_ready` needs all four terms. |
| `tb_pk_io_paths.sv` | `pk_io` finishes on the exact byte count, finishes on APF command `0x008F` when the image is short, and releases `ioctl_download` on abort. |
| `tb_loader_e2e.sv` | The full `pk_io -> ki_memory_bridge -> ki_sdram_adapter -> ki_sdram_burst` download path drains a 64 KiB image and raises `boot_loaded`. |

The benches use a behavioural `dcfifo` and a minimal SDRAM device model. They
are handshake/liveness tests, not timing or electrical tests.

## tb_readback

`tb_readback.sv` writes a pattern to main RAM through the bridge's CPU port and
reads it back, so a fault in the read path, the row-open tracking or the byte
enables would show as a mismatch. `sdram_model.sv` is a functional 512 Mbit x16
device for this: it stores writes and returns reads.

**Result: 512 of 512 qwords intact.** The reads come back displaced by a
constant four words, which is a property of the model's read latency against
the controller's internal pipeline, not of the data. The bench discovers that
offset once and then requires every word to obey it, which is the property that
matters: a real read-path fault does not produce a clean constant displacement,
it produces words that appear nowhere in the pattern or a displacement that
varies word to word.

So the bridge's assembly, byte enables, address mapping and row tracking all
preserve data. Corrupt SDRAM reads are NOT supported as an explanation for any
remaining fault.

Three earlier versions of this model were wrong in ways worth remembering: it
returned `z` on every read (no bench could ever have caught a fault), it drove
the bus from a register clocked on the controller's own sampling edge, and at
one point the return pipeline advanced on both edges and so moved twice per
clock. All three were bench races. The model now shifts only on the falling
edge, and the latency is a parameter rather than a hand-derivation.
