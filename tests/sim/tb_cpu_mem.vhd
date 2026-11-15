-- Does a store survive a load THROUGH THE REAL CPU?
--
-- The bench the d-cache work pointed at. Driving cpu_datacache from outside
-- means re-deriving its contract, and three attempts at that were wrong in ways
-- only the cache's own assertions caught. This instead runs a MIPS program on
-- the real cpu_pocket - same entity, same generics synthesis uses - and lets
-- the CPU generate the address / write-enable / write-data sequence itself.
--
-- The program, at the reset vector 0xBFC00000:
--
--   sw    $t1, 0($t0)      store 0x12345678 to 0x08001000
--   lw    $t2, 0($t0)      read it back
--   bne   $t2, $t1, fail   and branch on inequality
--   sw    $t1, 8($t0)      the same at +8, so the second doubleword of the
--   lw    $t3, 8($t0)      line is covered too
--   bne   $t3, $t1, fail
--   sw    $t1, 0($t4)      pass: write 0x12345678 to 0x10000000
--   fail: sw $t1, 0($t4)   fail: write it to 0x10000004
--
-- The pass condition is a WRITE THE PROGRAM MAKES, not an internal signal, so
-- it does not depend on this bench's reading of the cache's internals. A write
-- of 0x12345678 to 0x10000000 is the whole test.
--
-- This is the shape of the fault being chased: on hardware the game stores a
-- pointer into its stack frame, loads it two instructions later, and takes an
-- AdEL from a pointer that was never valid - so "does sw then lw round-trip" is
-- exactly the property in question.
--
-- NOT covered: the write-back path (needs a dirty victim), TLB translation
-- beyond what the reset state gives, and interrupts.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cpu_mem is
end entity;

architecture sim of tb_cpu_mem is
   constant CLK1X_NS : time := 20 ns;
   constant SKEW_NS  : time := 250 ps;

   signal clk1x : std_logic := '0';
   signal clk93 : std_logic := '0';
   signal reset : std_logic := '1';
   signal irq : std_logic_vector(1 downto 0) := "00";
   signal pause : std_logic := '0';
   signal mem_request : std_logic;
   signal mem_rnw : std_logic;
   signal mem_address : std_logic_vector(31 downto 0);
   signal mem_req64 : std_logic;
   signal mem_size : std_logic_vector(2 downto 0);
   signal mem_writeMask : std_logic_vector(7 downto 0);
   signal mem_dataWrite : std_logic_vector(63 downto 0);
   signal mem_line_write : std_logic;
   signal mem_line_ra : std_logic;
   signal mem_line_data : std_logic_vector(255 downto 0);
   signal mem_line_bytes : std_logic_vector(31 downto 0);
   signal mem_dataRead : std_logic_vector(63 downto 0) := (others => '0');
   signal mem_done : std_logic := '0';
   signal cache_grant : std_logic := '0';
   signal cache_data : std_logic_vector(63 downto 0) := (others => '0');
   signal cache_data_ready : std_logic := '0';
   signal fast_ok : std_logic := '0';
   signal fast_req_tog : std_logic;
   signal fast_req_line : std_logic_vector(31 downto 0);
   signal fast_window : std_logic := '0';
   signal fast_beat : std_logic := '0';
   signal fast_first : std_logic := '0';
   signal fast_qword : std_logic_vector(63 downto 0) := (others => '0');
   signal fast_done_tog : std_logic := '0';
   signal errors : std_logic_vector(5 downto 0);
   signal debug_fetch_pc : std_logic_vector(31 downto 0);
   signal debug_retired : std_logic_vector(31 downto 0);
   signal debug_perf_prof : std_logic_vector(335 downto 0);
   signal debug_prof_fine : std_logic_vector(2 downto 0);
   signal debug_gpr_s1 : std_logic_vector(31 downto 0);
   signal debug_irq_count : std_logic_vector(31 downto 0);
   signal debug_t2_reload_count : std_logic_vector(31 downto 0);
   signal debug_h1_op : std_logic_vector(31 downto 0);
   signal debug_dep_pc : std_logic_vector(31 downto 0);
   signal debug_dep_valid : std_logic;
   signal debug_dep_trigger : std_logic_vector(1 downto 0);
   signal debug_exc_cause : std_logic_vector(31 downto 0);
   signal debug_cop0_cause_live : std_logic_vector(31 downto 0);
   signal debug_ret_count : std_logic_vector(31 downto 0);
   signal debug_retire_pc : std_logic_vector(31 downto 0);
   signal debug_retire_opcode : std_logic_vector(31 downto 0);
   signal debug_trace_bus : std_logic_vector(895 downto 0);
   signal debug_trace_frozen : std_logic;
   signal debug_eret_epc : std_logic_vector(31 downto 0);
   signal debug_eret_target : std_logic_vector(31 downto 0);
   signal debug_eret_flags : std_logic_vector(31 downto 0);
   signal debug_ds_count : std_logic_vector(31 downto 0);
   signal debug_ds_first : std_logic_vector(31 downto 0);
   signal debug_trace_trigger : std_logic := '0';
   signal perf_flip : std_logic := '0';
   signal perf_clear : std_logic := '0';
   signal prof_fine_sel : std_logic_vector(3 downto 0) := "0000";
   signal perf_bridge_out : std_logic_vector(15 downto 0) := (others => '0');
   signal perf_bridge_burst : std_logic_vector(15 downto 0) := (others => '0');
   signal debug_perf_bus : std_logic_vector(223 downto 0);
   signal debug_perf_worst : std_logic_vector(223 downto 0);

   -- The program.
   type rom_t is array (0 to 63) of std_logic_vector(31 downto 0);
   signal rom : rom_t := (others => (others => '0'));

   -- Data memory: 64 KiB at 0x0800_0000, one qword per entry.
   type ram_t is array (0 to 8191) of std_logic_vector(63 downto 0);
   signal ram : ram_t := (others => (others => '0'));

   signal pass_seen : boolean := false;
   signal fail_seen : boolean := false;
   signal fail_value : std_logic_vector(63 downto 0) := (others => '0');

   -- The CPU stores and fetches 64-bit beats in BUS order: for this big-endian
   -- build each 32-bit word arrives byte-swapped. Memory here holds the
   -- CPU-visible value, so both directions apply the same involution.
   function bswap32(v : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      return v(7 downto 0) & v(15 downto 8) & v(23 downto 16) & v(31 downto 24);
   end function;

   function swap_words(v : std_logic_vector(63 downto 0)) return std_logic_vector is
   begin
      return bswap32(v(31 downto 0)) & bswap32(v(63 downto 32));
   end function;

begin
   clk1x <= not clk1x after CLK1X_NS / 2;
   clk93 <= clk1x after SKEW_NS;

   rom(0) <= x"3C1D0800";   -- lui   $sp,0x0800
   rom(1) <= x"37BDF000";   -- ori   $sp,$sp,0xf000
   rom(2) <= x"3C080800";   -- lui   $t0,0x0800
   rom(3) <= x"35081000";   -- ori   $t0,$t0,0x1000
   rom(4) <= x"3C091234";   -- lui   $t1,0x1234
   rom(5) <= x"35295678";   -- ori   $t1,$t1,0x5678
   rom(6) <= x"AD090000";   -- sw    $t1,0($t0)
   rom(7) <= x"8D0A0000";   -- lw    $t2,0($t0)
   rom(8) <= x"15490009";   -- bne   $t2,$t1,fail
   rom(9) <= x"00000000";   -- nop
   rom(10) <= x"AD090008";  -- sw    $t1,8($t0)
   rom(11) <= x"8D0B0008";  -- lw    $t3,8($t0)
   rom(12) <= x"15690005";  -- bne   $t3,$t1,fail
   rom(13) <= x"00000000";  -- nop
   rom(14) <= x"3C041000";  -- lui   $t4,0x1000
   rom(15) <= x"AC890000";  -- sw    $t1,0($t4)      PASS marker
   rom(16) <= x"0BF00040";  -- j     self
   rom(17) <= x"00000000";  -- nop
   rom(18) <= x"3C041000";  -- FAIL: lui $t4,0x1000
   rom(19) <= x"35840004";  -- ori   $t4,$t4,4
   rom(20) <= x"AC890000";  -- sw    $t1,0($t4)      FAIL marker
   rom(21) <= x"0BF00054";  -- j     self
   rom(22) <= x"00000000";  -- nop

   -- Exactly the generics ki_core_pocket.sv uses, so this is the CPU build the
   -- Pocket runs: SYNC_CROSSING and DIRECT_FILL off, every DCACHE_* off, and
   -- LOAD_INTERLOCK / UNC_FAST_DONE / LOAD_MERGE_BYPASS left at ki_cpu_core's
   -- defaults of 1.
   dut : entity work.ki_cpu_core
   generic map
   (
      DEBUG_TRACE   => 0,
      SYNC_CROSSING => 0,
      DCACHE_FB_PARTIAL => 0,
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
      clk1x => clk1x,
      clk93 => clk93,
      reset => reset,
      irq => irq,
      pause => pause,
      mem_request => mem_request,
      mem_rnw => mem_rnw,
      mem_address => mem_address,
      mem_req64 => mem_req64,
      mem_size => mem_size,
      mem_writeMask => mem_writeMask,
      mem_dataWrite => mem_dataWrite,
      mem_line_write => mem_line_write,
      mem_line_ra => mem_line_ra,
      mem_line_data => mem_line_data,
      mem_line_bytes => mem_line_bytes,
      mem_dataRead => mem_dataRead,
      mem_done => mem_done,
      cache_grant => cache_grant,
      cache_data => cache_data,
      cache_data_ready => cache_data_ready,
      fast_ok => fast_ok,
      fast_req_tog => fast_req_tog,
      fast_req_line => fast_req_line,
      fast_window => fast_window,
      fast_beat => fast_beat,
      fast_first => fast_first,
      fast_qword => fast_qword,
      fast_done_tog => fast_done_tog,
      errors => errors,
      debug_fetch_pc => debug_fetch_pc,
      debug_retired => debug_retired,
      debug_perf_prof => debug_perf_prof,
      debug_prof_fine => open,
      debug_gpr_s1 => debug_gpr_s1,
      debug_irq_count => debug_irq_count,
      debug_t2_reload_count => debug_t2_reload_count,
      debug_h1_op => debug_h1_op,
      debug_dep_pc => debug_dep_pc,
      debug_dep_valid => debug_dep_valid,
      debug_dep_trigger => debug_dep_trigger,
      debug_exc_cause => debug_exc_cause,
      debug_cop0_cause_live => debug_cop0_cause_live,
      debug_ret_count => debug_ret_count,
      debug_retire_pc => debug_retire_pc,
      debug_retire_opcode => debug_retire_opcode,
      debug_trace_bus => debug_trace_bus,
      debug_trace_frozen => open,
      debug_eret_epc => debug_eret_epc,
      debug_eret_target => debug_eret_target,
      debug_eret_flags => debug_eret_flags,
      debug_ds_count => debug_ds_count,
      debug_ds_first => debug_ds_first,
      debug_trace_trigger => debug_trace_trigger,
      perf_flip => perf_flip,
      perf_clear => perf_clear,
      prof_fine_sel => prof_fine_sel,
      perf_bridge_out => perf_bridge_out,
      perf_bridge_burst => perf_bridge_burst,
      debug_perf_bus => open,
      debug_perf_worst => debug_perf_worst
   );

   -- ------------------------------------------------------------------ memory
   -- One request at a time. For a read: four beats on ddr3_DOUT with a READY
   -- pulse each, then mem_done - the order cpu_pocket.vhd documents for a cache
   -- fill ("beats in clk1x, the last one no later than mem_done"). For a write:
   -- capture and complete.
   mem : process (clk1x)
      variable addr    : unsigned(31 downto 0);
      variable beat    : integer := 0;
      variable busy    : boolean := false;
      variable is_line : boolean := false;
      variable idx     : integer;
      variable captured : std_logic_vector(63 downto 0);
      variable wa       : unsigned(31 downto 0);
   begin
      if rising_edge(clk1x) then
         cache_data_ready <= '0';
         cache_grant <= '0';
         mem_done <= '0';
         if reset = '1' then
            busy := false;
            beat := 0;
         elsif mem_request = '1' and not busy then
            addr := unsigned(mem_address);
            busy := true;
            beat := 0;
            is_line := (mem_req64 = '1');
         elsif busy then
            if mem_rnw = '1' then
               -- Compute the beat into a variable and drive BOTH outputs from
               -- it in the same cycle. Driving mem_dataRead from the ddr3_DOUT
               -- signal instead put it one beat behind, and the CPU's own
               -- interlock assertion caught it ("a load's bubble was released
               -- before its own answer").
               if addr >= 16#1FC0_0000# and addr < 16#1FC0_0400# then
                  idx := to_integer(addr(7 downto 3));
                  captured := bswap32(rom(2 * idx + 1)) & bswap32(rom(2 * idx));   -- low address word in the HIGH half
               elsif addr >= 16#0800_0000# and addr < 16#0801_0000# then
                  idx := to_integer(addr(15 downto 3));
                  captured := swap_words(ram(idx));
               else
                  captured := (others => '0');
               end if;
               cache_data <= captured;
               cache_grant <= '1';
               mem_dataRead <= captured;
               cache_data_ready <= '1';
               addr := addr + 8;
               beat := beat + 1;
               if (is_line and beat = 4) or (not is_line and beat = 1) then
                  mem_done <= '1';
                  busy := false;
               end if;
            else
               -- Write. A line write carries four qwords in mem_line_data.
               if mem_line_write = '1' then
                  for k in 0 to 3 loop
                     captured := mem_line_data(64 * k + 63 downto 64 * k);
                     wa := addr + 8 * k;
                     if wa >= 16#0800_0000# and wa < 16#0801_0000# then
                        idx := to_integer(wa(15 downto 3));
                        ram(idx) <= swap_words(captured);
                     end if;
                  end loop;
               else
                  captured := mem_dataWrite;
                  if addr = x"10000000" and captured(63 downto 32) = x"12345678" then
                     pass_seen <= true;
                  end if;
                  if addr = x"10000004" then
                     fail_seen <= true;
                     fail_value <= captured;
                  end if;
                  if addr >= 16#0800_0000# and addr < 16#0801_0000# then
                     idx := to_integer(addr(15 downto 3));
                     ram(idx) <= swap_words(captured);
                  end if;
               end if;
               mem_done <= '1';
               busy := false;
            end if;
         end if;
      end if;
   end process;

   -- ---------------------------------------------------------------- stimulus
   stimulus : process
   begin
      reset <= '1';

      wait for 10 * CLK1X_NS;
      reset <= '0';


      for cycles in 0 to 4000 loop
         wait until rising_edge(clk1x);
         if pass_seen then
            report "PASS_CPU_MEM: the program stored and loaded back through the CPU and wrote the pass marker"
               severity note;
            wait;
         end if;
         if fail_seen then
            report "FAIL_CPU_MEM: bne taken - the value read back did not match the value stored. Marker value "
               & to_hstring(fail_value)
               severity error;
            wait;
         end if;
         if errors /= "000000" then
            report "FAIL_CPU_MEM: CPU raised error flags " & to_hstring(errors)
               & " at PC=" & to_hstring(debug_fetch_pc)
               & " cause=" & to_hstring(debug_cop0_cause_live)
               severity error;
            wait;
         end if;
      end loop;
      -- The error flags and the COP0 cause are printed here because the first
      -- thing to check on a timeout is whether the CPU stopped on its own
      -- (errors /= 0) or simply never reached the marker.
      report "FAIL_CPU_MEM: timeout, PC=" & to_hstring(debug_fetch_pc)
         & " retired=" & to_hstring(debug_retired)
         & " errors=" & to_hstring(errors)
         & " cause_live=" & to_hstring(debug_cop0_cause_live)
         & " exc=" & to_hstring(debug_exc_cause)
         severity error;
      wait;
   end process;
end architecture;
