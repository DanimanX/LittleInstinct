-- Runs the REAL Killer Instinct boot ROM on the real CPU (ki_cpu_core, with
-- the generics ki_core_pocket.sv synthesises) and reproduces the Pocket's
-- first-boot hang:
--
--   bfc003e8  lui   v0,0x8000
--   bfc003ec  li    v1,255
--   bfc003f0  mtc0  zero,TagLo
--   bfc003f4  cache 0x09,0(v0)          D-cache Index_Store_Tag (TagLo = 0)
--   bfc003f8  cache 0x09,0x2000(v0)
--   bfc003fc  lw    zero,0(v0)          first D-cache miss of the boot
--   bfc00400  lw    zero,0x2000(v0)     second miss, same set  <-- hardware
--                                        froze here at 599 retired
--
-- 0xBFC00000 executes `j 0x1FC00388`, which calls 0x1FC004BC (the COP0 / TLB
-- setup loop, instruction fetches only), then 0x1FC003CC (two stores to
-- 0xB0000000, an I/O hole), then 0x1FC003E8. So those two loads are the
-- FIRST data-cache accesses since reset: nothing has ever been evicted.
--
-- The memory model is a transcription of ki_memory_bridge_pocket.sv's
-- CPU-facing paths, not an invention: same states, same edge for every
-- register, same 4-qword beat order for a line fill, same 256-cycle boot ROM
-- access (BOOT_ROM_WAIT_SHIFT = 4 on a 16-word request), same "done on the
-- cycle the last qword goes out" rule for an SDRAM line. Where it differs,
-- the difference is named at the point where it is made.
--
-- What it therefore answers: does the CPU + D-cache side of the handshake
-- complete when the bridge does what the bridge says it does?
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_cpu_boot is
   generic
   (
      -- The SDRAM read's schedule, in clk1x cycles after the bridge accepts
      -- the request. Measured on the real chain - ki_memory_bridge +
      -- ki_sdram_adapter + ki_sdram_x2 + ki_sdram_burst + the SDRAM device -
      -- by tests/sim/tb_cpu_line_fills.sv, which issues this same request:
      -- grant at +2, one 64-bit beat every 2 cycles from +8, done at +15.
      GRANT_AT    : integer := 2;
      BEAT0       : integer := 8;
      BEAT_STEP   : integer := 2;
      BEAT_N      : integer := 4;
      DONE_AT     : integer := 15;
      -- Cycles of deferral added to every SDRAM answer: the bridge's IDLE
      -- serves video, DCS ROM and download traffic before the CPU, so a real
      -- answer can be much later than the measured 15 cycles.
      DEFER       : integer := 0;
      -- Stop with PASS_BOOT as soon as this many instructions have retired:
      -- the hardware froze at 0x257 (599) retires, so passing 0x400 means the
      -- sequence that froze the board ran to completion.
      PASS_RET    : integer := 16#400#;
      RUN_CYCLES  : integer := 60000
   );
end entity;

architecture sim of tb_cpu_boot is

   constant T      : time := 20 ns;
   constant ROMLEN : integer := 8192;   -- the bridge's boot cache: 8 KiB

   signal clk1x : std_logic := '0';
   signal clk93 : std_logic := '0';
   signal reset : std_logic := '1';
   signal irq   : std_logic_vector(1 downto 0) := "00";
   signal pause : std_logic := '0';

   signal mem_request     : std_logic;
   signal mem_rnw         : std_logic;
   signal mem_address     : std_logic_vector(31 downto 0);
   signal mem_req64       : std_logic;
   signal mem_size        : std_logic_vector(2 downto 0);
   signal mem_writeMask   : std_logic_vector(7 downto 0);
   signal mem_dataWrite   : std_logic_vector(63 downto 0);
   signal mem_line_write  : std_logic;
   signal mem_line_ra     : std_logic;
   signal mem_line_data   : std_logic_vector(255 downto 0);
   signal mem_line_bytes  : std_logic_vector(31 downto 0);
   signal mem_dataRead    : std_logic_vector(63 downto 0) := (others => '0');
   signal mem_done        : std_logic := '0';
   signal cache_grant     : std_logic := '0';
   signal cache_data      : std_logic_vector(63 downto 0) := (others => '0');
   signal cache_data_ready: std_logic := '0';
   signal fast_ok         : std_logic := '0';
   signal fast_req_tog    : std_logic;
   signal fast_req_line   : std_logic_vector(31 downto 0);
   signal fast_window     : std_logic := '0';
   signal fast_beat       : std_logic := '0';
   signal fast_first      : std_logic := '0';
   signal fast_qword      : std_logic_vector(63 downto 0) := (others => '0');
   signal fast_done_tog   : std_logic := '0';
   signal errors          : std_logic_vector(5 downto 0);
   signal debug_fetch_pc  : std_logic_vector(31 downto 0);
   signal debug_retired   : std_logic_vector(31 downto 0);
   signal debug_perf_prof : std_logic_vector(335 downto 0);
   signal debug_prof_fine : std_logic_vector(2 downto 0);
   signal debug_gpr_s1    : std_logic_vector(31 downto 0);
   signal debug_irq_count : std_logic_vector(31 downto 0);
   signal debug_t2_reload_count : std_logic_vector(31 downto 0);
   signal debug_h1_op     : std_logic_vector(31 downto 0);
   signal debug_dep_pc    : std_logic_vector(31 downto 0);
   signal debug_dep_valid : std_logic;
   signal debug_dep_trigger : std_logic_vector(1 downto 0);
   signal debug_exc_cause : std_logic_vector(31 downto 0);
   signal debug_badvaddr  : std_logic_vector(31 downto 0);
   signal debug_cop0_cause_live : std_logic_vector(31 downto 0);
   signal debug_ret_count : std_logic_vector(31 downto 0);
   signal debug_retire_pc : std_logic_vector(31 downto 0);
   signal debug_retire_opcode : std_logic_vector(31 downto 0);
   signal debug_trace_bus : std_logic_vector(895 downto 0);
   signal debug_eret_epc  : std_logic_vector(31 downto 0);
   signal debug_eret_target : std_logic_vector(31 downto 0);
   signal debug_eret_flags : std_logic_vector(31 downto 0);
   signal debug_ds_count  : std_logic_vector(31 downto 0);
   signal debug_ds_first  : std_logic_vector(31 downto 0);
   signal debug_trace_trigger : std_logic := '0';
   signal perf_flip       : std_logic := '0';
   signal perf_clear      : std_logic := '0';
   signal prof_fine_sel   : std_logic_vector(3 downto 0) := "0000";
   signal perf_bridge_out : std_logic_vector(15 downto 0) := (others => '0');
   signal perf_bridge_burst : std_logic_vector(15 downto 0) := (others => '0');
   signal debug_perf_bus  : std_logic_vector(223 downto 0);
   signal debug_perf_worst: std_logic_vector(223 downto 0);

   -- The boot cache: the first 8 KiB of roms/kinst.rom, as the loader leaves
   -- it. The file stores each 32-bit word little-endian, and pk_io's download
   -- path assembles the eight bytes of a qword in stream order, so
   --   boot_cache(A) = rom[A..A+7] read as a big-endian 64-bit number
   -- and a 32-bit read of word A is bits 31:0 for even A, 63:32 for odd.
   type boot_t is array (0 to ROMLEN / 8 - 1) of std_logic_vector(63 downto 0);
   signal boot_cache : boot_t := (others => (others => '0'));
   signal rom_loaded : boolean := false;

   -- Low SDRAM (0x0000_0000..0x0007_FFFF, the CPU sees it as KSEG0
   -- 0x8000_0000). Small and sparse: the boot's only data accesses in this
   -- window are the two lw of the D-cache init loop, and both are reads of
   -- memory nothing has written yet.
   type ram_t is array (0 to 8191) of std_logic_vector(63 downto 0);
   signal ram : ram_t := (others => (others => '0'));

   signal cycles : integer := 0;
   signal requests : integer := 0;

   -- External names, so the log can say what the cache was doing when the CPU
   -- stopped. debug_state is the cache's own tState'pos, exported for the
   -- debug page; reading it here avoids naming a type declared inside an
   -- architecture, which an external name cannot.
   signal dc_state   : std_logic_vector(4 downto 0);
   signal dc_req     : std_logic;
   signal dc_active  : std_logic;
   signal dc_filldone: std_logic;

   function hex8(v : std_logic_vector(31 downto 0)) return string is
   begin
      return to_hstring(unsigned(v));
   end function;

begin

   clk1x <= not clk1x after T / 2;
   -- The Pocket: clk_cpu and clk_core are the SAME net (one PLL output). A
   -- delta makes the two names two signals; zero skew is what hardware has.
   clk93 <= clk1x;

   -- ------------------------------------------------------------------ ROM
   rom : process
      type char_file is file of character;
      file f : char_file;
      variable ch : character;
      variable q  : std_logic_vector(63 downto 0);
      variable i  : integer := 0;
   begin
      file_open(f, "roms/kinst.rom", read_mode);
      while i < ROMLEN / 8 loop
         q := (others => '0');
         -- little-endian assembly of the eight bytes, which is what pk_io's
         -- download path leaves in boot_cache[]: the first halfword of the
         -- stream lands in bits 15:0, so qword bit 8i is file byte i.
         for k in 0 to 7 loop
            read(f, ch);
            q(8 * k + 7 downto 8 * k) :=
               std_logic_vector(to_unsigned(character'pos(ch), 8));
         end loop;
         boot_cache(i) <= q;
         i := i + 1;
      end loop;
      file_close(f);
      rom_loaded <= true;
      report "tb_cpu_boot: boot ROM loaded, 8 KiB" severity note;
      wait;
   end process;

   -- ------------------------------------------------------------------- DUT
   dut : entity work.ki_cpu_core
   generic map
   (
      DEBUG_TRACE   => 0,
      -- Exactly ki_core_pocket.sv's generic map.
      SYNC_CROSSING => 0,
      DCACHE_SKIP_FILL  => 0,
      DCACHE_FB_PARTIAL => 0,
      DCACHE_WB_EARLY   => 0,
      DCACHE_STORE_BUFFER => 0,
      DCACHE_SB_FORWARD => 0,
      DCACHE_CWF_FB     => 0,
      DCACHE_FILL_FIRST => 0,
      DCACHE_FILL_AT_MISS => 0,
      DCACHE_READ_AHEAD => 0,
      DCACHE_RA_ANSWER  => 0,
      DCACHE_EARLY_RESTART => 0,
      DIRECT_FILL   => 0
   )
   port map
   (
      clk1x => clk1x, clk93 => clk93, reset => reset, irq => irq, pause => pause,
      mem_request => mem_request, mem_rnw => mem_rnw, mem_address => mem_address,
      mem_req64 => mem_req64, mem_size => mem_size,
      mem_writeMask => mem_writeMask, mem_dataWrite => mem_dataWrite,
      mem_line_write => mem_line_write, mem_line_ra => mem_line_ra,
      mem_line_data => mem_line_data, mem_line_bytes => mem_line_bytes,
      mem_dataRead => mem_dataRead, mem_done => mem_done,
      cache_grant => cache_grant, cache_data => cache_data,
      cache_data_ready => cache_data_ready,
      fast_ok => fast_ok, fast_req_tog => fast_req_tog,
      fast_req_line => fast_req_line, fast_window => fast_window,
      fast_beat => fast_beat, fast_first => fast_first,
      fast_qword => fast_qword, fast_done_tog => fast_done_tog,
      errors => errors, debug_fetch_pc => debug_fetch_pc,
      debug_retired => debug_retired, debug_perf_prof => debug_perf_prof,
      debug_prof_fine => debug_prof_fine, debug_gpr_s1 => debug_gpr_s1,
      debug_irq_count => debug_irq_count,
      debug_t2_reload_count => debug_t2_reload_count,
      debug_h1_op => debug_h1_op,
      debug_dep_pc => debug_dep_pc, debug_dep_valid => debug_dep_valid,
      debug_dep_trigger => debug_dep_trigger,
      debug_exc_cause => debug_exc_cause, debug_badvaddr => debug_badvaddr,
      debug_cop0_cause_live => debug_cop0_cause_live,
      debug_ret_count => debug_ret_count,
      debug_retire_pc => debug_retire_pc,
      debug_retire_opcode => debug_retire_opcode,
      debug_trace_bus => debug_trace_bus, debug_trace_frozen => open,
      debug_eret_epc => debug_eret_epc, debug_eret_target => debug_eret_target,
      debug_eret_flags => debug_eret_flags,
      debug_ds_count => debug_ds_count, debug_ds_first => debug_ds_first,
      debug_trace_trigger => debug_trace_trigger,
      perf_flip => perf_flip, perf_clear => perf_clear,
      prof_fine_sel => prof_fine_sel,
      perf_bridge_out => perf_bridge_out,
      perf_bridge_burst => perf_bridge_burst,
      debug_perf_bus => debug_perf_bus,
      debug_perf_worst => debug_perf_worst
   );

   -- ------------------------------------------------- memory model (bridge)
   -- Transcription of ki_memory_bridge_pocket.sv. State names are the
   -- bridge's, so the two can be read side by side.
   mem : process (clk1x)
      type tst is (IDLE, BOOT_ROM_ACCESS_WAIT, BOOT_CACHE_READ_WAIT,
                   BOOT_CACHE_READ_RETURN, SDRAM_READ_WAIT,
                   SDRAM_WRITE_ISSUE, SDRAM_WRITE_WAIT);
      variable st : tst := IDLE;

      variable pend        : boolean := false;
      variable rnw         : std_logic;
      variable a           : std_logic_vector(31 downto 0);
      variable r64         : std_logic;
      variable line_w      : std_logic;

      variable beats       : integer;   -- read_beats_remaining, 64-bit beats
      variable bq          : std_logic_vector(63 downto 0);
      variable bwa         : integer;   -- boot_cache_read_address (qword index)

      variable waitc       : integer;   -- boot_rom_wait_cycles
      variable ret_st      : tst;

      variable words_left  : integer;   -- read_words_remaining, 16-bit words
      variable widx        : integer;   -- read_word_index
      variable buf         : std_logic_vector(63 downto 0);
      variable word_a      : integer;   -- memory_word_address (16-bit words)
      variable ph          : integer := 0;
      variable lba         : integer := 0;
      variable rdata       : std_logic_vector(63 downto 0);

      variable ismem, isboot : boolean;
      variable nwords      : integer;
      variable qw          : std_logic_vector(63 downto 0);
      variable w_idx       : integer;
   begin
      if rising_edge(clk1x) then
         mem_done         <= '0';
         cache_grant      <= '0';
         cache_data_ready <= '0';

         if reset = '1' then
            st := IDLE; pend := false;
         else
            case st is
               when IDLE =>
                  if mem_request = '1' then
                     pend := true;
                     rnw    := mem_rnw;
                     a      := mem_address;
                     r64    := mem_req64;
                     line_w := mem_line_write;
                     requests <= requests + 1;
                     -- Instruction fetches are the boot ROM's own line
                     -- buffer traffic and would drown the log; data traffic
                     -- and the two stores are what this bench is about.
                     if r64 = '1' or line_w = '1' then
                        report "REQ " & hex8(a) & " rnw=" & std_logic'image(rnw)(2)
                           & " size=" & integer'image(to_integer(unsigned(mem_size)))
                           & " cyc=" & integer'image(cycles)
                           & " pc=" & hex8(debug_fetch_pc)
                           & " ret=" & hex8(debug_retired)
                           severity note;
                     end if;

                     ismem  := (unsigned(a) <= 16#0007_FFFF#) or
                               (unsigned(a) >= 16#0800_0000# and unsigned(a) <= 16#087F_FFFF#) or
                               (unsigned(a) >= 16#0880_0000# and unsigned(a) <= 16#088F_FFFF#) or
                               (unsigned(a) >= 16#1FC0_0000# and unsigned(a) <= 16#1FC7_FFFF#);
                     isboot := (unsigned(a) >= 16#1FC0_0000# and unsigned(a) <= 16#1FC7_FFFF#);

                     if not ismem then
                        -- ki_memory_bridge_pocket.sv:1196-1199. Not memory
                        -- and not I/O: the answer is all ones, next cycle.
                        mem_dataRead <= x"FFFFFFFFFFFFFFFF";
                        mem_done     <= '1';
                        st := IDLE;
                     elsif rnw = '0' and line_w = '0' then
                        -- An ordinary store to memory: SDRAM write burst.
                        words_left := 0;
                        st := SDRAM_WRITE_ISSUE;
                     elsif rnw = '1' and line_w = '0' and
                           isboot and a(18 downto 13) = "000000" and
                           (r64 = '0' or unsigned(a(12 downto 0)) <= 16#1FE0#) then
                        -- active_boot_cache_read: the 8 KiB boot cache.
                        if r64 = '1' then
                           beats := 4;  nwords := 16;
                        else
                           beats := 1;  nwords := 2;
                        end if;
                        bwa  := to_integer(unsigned(a(12 downto 3)));
                        waitc := nwords * 16;      -- BOOT_ROM_WAIT_SHIFT = 4
                        cache_grant <= '1';
                        ret_st := BOOT_CACHE_READ_WAIT;
                        st := BOOT_ROM_ACCESS_WAIT;
                     else
                        -- SDRAM read.
                        if r64 = '1' then
                           beats := to_integer(unsigned(mem_size));
                           nwords := 16;
                           word_a := to_integer(unsigned(a(25 downto 3))) * 4;
                        else
                           beats := 1;  nwords := 2;
                           word_a := to_integer(unsigned(a(25 downto 2))) * 2;
                        end if;
                        if beats > 4 then beats := 4; end if;
                        waitc := 0;
                        st := SDRAM_READ_WAIT;
                        ph   := 0;
                        lba  := to_integer(unsigned(a(25 downto 5)));
                        mem_dataRead <= ram(lba mod 8192);
                     end if;
                  end if;

               when BOOT_ROM_ACCESS_WAIT =>
                  -- Same countdown, same edge: returns when waitc <= 1.
                  if waitc <= 1 then
                     st := ret_st;
                  else
                     waitc := waitc - 1;
                  end if;

               when BOOT_CACHE_READ_WAIT =>
                  st := BOOT_CACHE_READ_RETURN;

               when BOOT_CACHE_READ_RETURN =>
                  qw := boot_cache(bwa);
                  rdata := qw;
                  mem_dataRead <= qw;
                  if r64 = '1' then
                     cache_data <= qw;
                     cache_data_ready <= '1';
                  else
                     if a(2) = '1' then
                        mem_dataRead <= x"00000000" & qw(63 downto 32);
                     else
                        mem_dataRead <= x"00000000" & qw(31 downto 0);
                     end if;
                  end if;
                  if beats <= 1 then
                     mem_done <= '1';
                     pend := false;
                     st := IDLE;
                  else
                     beats := beats - 1;
                     bwa := bwa + 1;
                     st := BOOT_CACHE_READ_WAIT;
                  end if;

               when SDRAM_READ_WAIT =>
                  -- The real chain's schedule, one line per cycle of it:
                  --   +2   cache_grant, the fill's way and start latched
                  --   +8,10,12,14  one 64-bit qword, low qword first
                  --   +15  mem_done, the cycle AFTER the last beat
                  -- Beat k places qword k of the line, and cpu_data_read
                  -- holds it from then on, as the bridge's register does.
                  ph := ph + 1;
                  if ph = GRANT_AT + DEFER then
                     cache_grant <= '1';
                  end if;
                  for k in 0 to BEAT_N - 1 loop
                     if ph = BEAT0 + DEFER + k * BEAT_STEP then
                        mem_dataRead <= ram((lba + k) mod 8192);
                        if r64 = '1' then
                           cache_data <= ram((lba + k) mod 8192);
                           cache_data_ready <= '1';
                        end if;
                     end if;
                  end loop;
                  if r64 = '0' and ph = BEAT0 + DEFER then
                     mem_dataRead <= ram(lba mod 8192);
                  end if;
                  if ph = DONE_AT + DEFER then
                     mem_done <= '1';
                     pend := false;
                     st := IDLE;
                  end if;

               when SDRAM_WRITE_ISSUE =>
                  if line_w = '1' then
                     -- line_req is acknowledged in the IDLE clock itself.
                     mem_done <= '1';
                     pend := false;
                     st := IDLE;
                  else
                     st := SDRAM_WRITE_WAIT;
                     ph := 0;
                  end if;

               when SDRAM_WRITE_WAIT =>
                  ph := ph + 1;
                  if ph < DONE_AT then
                     null;
                  else
                     if (a(31 downto 20) = x"080" or a(31 downto 20) = x"088") then
                        w_idx := to_integer(unsigned(a(15 downto 3)));
                        ram(w_idx) <= mem_dataWrite;
                     end if;
                     mem_done <= '1';
                     pend := false;
                     st := IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process;

   -- ------------------------------------------------------------------ watch
   -- GHDL external names: what the cache was doing when the CPU stopped.
   dc_state    <= << signal .tb_cpu_boot.dut.core.icpu_datacache.debug_state : std_logic_vector(4 downto 0) >>;
   dc_req      <= << signal .tb_cpu_boot.dut.core.icpu_datacache.ram_request : std_logic >>;
   dc_active   <= << signal .tb_cpu_boot.dut.core.icpu_datacache.ram_active : std_logic >>;
   dc_filldone <= << signal .tb_cpu_boot.dut.core.icpu_datacache.ram_done : std_logic >>;

   stimulus : process
      variable last_retired : std_logic_vector(31 downto 0) := (others => '0');
      variable still : integer := 0;
   begin
      reset <= '1';
      wait for 20 * T;
      reset <= '0';
      loop
         wait until rising_edge(clk1x);
         cycles <= cycles + 1;
         if debug_retired = last_retired then
            still := still + 1;
         else
            last_retired := debug_retired;
            still := 0;
         end if;
         if still = 5000 then
            report "STALL: no retirement for 5000 cycles at cyc=" & integer'image(cycles)
               & " pc=" & hex8(debug_fetch_pc)
               & " retired=" & hex8(debug_retired)
               & " errors=" & to_hstring(unsigned(errors))
               severity note;
         end if;
         if still = 20000 then
            report "HUNG: pc=" & hex8(debug_fetch_pc)
               & " retired=" & hex8(debug_retired)
               & " errors=" & to_hstring(unsigned(errors))
               & " cause=" & hex8(debug_cop0_cause_live)
               & " exc=" & hex8(debug_exc_cause)
               severity failure;
         end if;
         if unsigned(debug_retired) > PASS_RET then
            report "PASS_BOOT: retired=" & hex8(debug_retired)
               & " at cyc=" & integer'image(cycles)
               & " - past the point the board froze" severity note;
            wait;
         end if;
         if cycles >= RUN_CYCLES then
            report "END: cycles=" & integer'image(cycles)
               & " requests=" & integer'image(requests)
               & " pc=" & hex8(debug_fetch_pc)
               & " retired=" & hex8(debug_retired)
               & " errors=" & to_hstring(unsigned(errors))
               & " dcstate=" & to_hstring(dc_state)
               severity note;
            wait;
         end if;
      end loop;
   end process;

end architecture;
