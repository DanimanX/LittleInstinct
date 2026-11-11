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
