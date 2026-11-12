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

## tb_readback - and an honest limit

`tb_readback.sv` writes a pattern to main RAM through the bridge's CPU port and
reads it back, so a fault in the read path, the row-open tracking or the byte
enables would show as a mismatch. `sdram_model.sv` is a functional 512 Mbit x16
device for this: it stores writes and returns reads. The read latency is a
parameter (`RD_LAT`) swept from the command line, because the controller's own
comment states the word arrives *three clocks after* `cas_pipe[0]` through a
command register plus `dq_cap` and `dq_stg`, and re-deriving that by hand is
what produced three wrong versions of this model.

**Status: not settled.** At `RD_LAT=9`, 504 of 512 qwords match and the 8
failures sit exactly on the last 16 bytes of each 0x400-byte (one SDRAM row)
block, returning `z`. The most likely explanation is this model, not the
design: the controller pipelines several burst-length-1 reads, and the model
holds only ONE outstanding read (`due`), so a read issued while a previous one
is still in flight overwrites it - which is worst exactly where the request
pattern changes, at a row boundary. Until the model tracks multiple in-flight
reads, those 8 failures must NOT be read as a design defect.

What the bench does establish: the model's alignment is a single-parameter
knob and 504/512 words survive a full write-read round trip through
`ki_memory_bridge -> ki_sdram_adapter -> ki_sdram_x2 -> ki_sdram_burst`, so the
bridge's assembly, byte enables and address mapping are broadly correct.
