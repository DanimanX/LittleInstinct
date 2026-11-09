# Licensing of this tree

The port code in this repository is licensed **GPL-3.0-or-later**; see
[LICENSE](LICENSE). It is derived from, and links against,
[MiSTer-devel/Arcade-KillerInstinct_MiSTer](https://github.com/MiSTer-devel/Arcade-KillerInstinct_MiSTer),
also GPL-3.0-or-later, vendored unmodified under `upstream/`.

Two parts are **not** under the GPL and keep their own terms:

- `src/fpga/apf/` — `apf_top.v`, `common.v`, `io_bridge_peripheral.v`,
  `io_pad_controller.v`, `mf_*.v`: the Analogue Pocket Framework, under the
  Analogue APF Software License Agreement in each file's header. Vendored
  unmodified from the Analogue openFPGA framework as distributed with
  `akoaysigod/pocket_saturn_core`.
- `src/fpga/core/core_bridge_cmd.v` (Analogue, © 2022), `src/fpga/core/sound_i2s.sv`
  and `src/fpga/core/sync_fifo.sv` (MIT, Adam Gastineau).

`src/fpga/glue/psram_phy.sv` is from `akoaysigod/pocket_saturn_core` and follows
that repository's GPL-3.0 terms.

Killer Instinct is a trademark of Rare / Nintendo / Midway. This project is not
affiliated with any of them. No game data is included or distributed here.
