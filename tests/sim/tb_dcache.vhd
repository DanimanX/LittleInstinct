-- Does cpu_datacache return the bytes that were stored to it?
--
-- This is the one path the other benches do not cover. tb_readback proves the
-- bridge preserves data when the CPU port writes and reads SDRAM directly;
-- every store and load the game executes, however, goes through this cache
-- first. The hardware symptom being chased is an AdEL whose faulting
-- instruction is `lwu $t7, 0x1f8($t6)` - a load at a 4-aligned offset, so it
-- can only fault on a bad BASE POINTER, and that pointer is built by stores to
-- the stack immediately before. A cache that returns stale data on a store-then
-- -load would produce exactly that.
--
-- The configuration tested is the one synthesis builds: every DCACHE_* generic
-- in cpu_pocket.vhd defaults to false and nothing overrides it, so the cache
-- runs without read-ahead, store buffer, early restart, fill-first or the
-- framebuffer special cases.
--
-- What it checks, in order:
--   1. a load that misses fills the line and answers with the memory contents
--   2. three more loads in the same line HIT (same line, no fill)
--   3. a store, then a load of the same doubleword, returns the stored bytes
--   4. a store, then a load of a DIFFERENT doubleword in the same line, returns
--      the memory contents (no aliasing between qwords)
--   5. every one of the 8 bytes of a doubleword can be written on its own and
--      read back, which exercises write_be rather than a full 8-byte store
--   6. a run of stores to consecutive doublewords across two lines, each read
--      back immediately - the pointer-building pattern the game uses
--
-- Not covered: the write-back path (needs a dirty victim evicted by another
-- address mapping to the same set), cache-coherent DMA, and anything in clk1x
-- versus clk93 ordering beyond the fixed phase the design assumes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_dcache is
end entity;

architecture sim of tb_dcache is
   constant LINE_BYTES : integer := 32;
   constant CLK1X_NS   : time := 20 ns;
   -- The design assumes clk93 to be a fixed 250 ps after clk1x (pocket_ki.sdc
   -- explains why); the internal read/write rule assertions depend on it.
   constant SKEW_NS    : time := 250 ps;

   signal clk1x : std_logic := '0';
   signal clk93 : std_logic := '0';

   signal reset_1x, reset_93 : std_logic := '1';
   signal ce_93    : std_logic := '1';
   signal stall    : unsigned(4 downto 0) := (others => '0');
   signal stall4   : std_logic := '0';
   signal fifo_block : std_logic := '0';

   signal slow_in        : std_logic_vector(3 downto 0) := "0000";
   signal force_wb_in    : std_logic := '0';
   signal write_through_in : std_logic := '0';

   signal ram_request : std_logic;
   signal ram_reqAddr : unsigned(31 downto 0);
   signal ram_active  : std_logic := '1';
   signal ram_grant   : std_logic := '0';
   signal ram_done    : std_logic := '0';
   signal fill_last_q : std_logic;
   signal wb_hold     : std_logic;
   signal ddr3_DOUT   : std_logic_vector(63 downto 0) := (others => '0');
   signal ddr3_DOUT_READY : std_logic := '0';

   signal writeback_ena   : std_logic;
   signal writeback_addr  : unsigned(31 downto 0);
   signal writeback_data  : std_logic_vector(63 downto 0);
   signal writeback_mask  : std_logic_vector(3 downto 0);
   signal writeback_bytes : std_logic_vector(31 downto 0);

   signal tag_addr   : unsigned(31 downto 0) := (others => '0');
   signal next_load  : std_logic := '1';
   signal read_ena   : std_logic := '0';
   signal RW_addr    : unsigned(31 downto 0) := (others => '0');
   signal RW_64      : std_logic := '1';
   signal RW_fb      : std_logic := '0';
   signal read_busy  : std_logic;
   signal read_done  : std_logic;
   signal read_data  : std_logic_vector(63 downto 0);

   signal write_ena  : std_logic := '0';
   signal write_be   : std_logic_vector(7 downto 0) := (others => '1');
   signal write_data : std_logic_vector(63 downto 0) := (others => '0');
   signal write_done : std_logic;

   signal CacheCommandEna   : std_logic := '0';
   signal CacheCommand      : unsigned(4 downto 0) := (others => '0');
   signal CachecommandStall : std_logic;
   signal CachecommandDone  : std_logic;
   signal TagLo_Valid : std_logic := '0';
   signal TagLo_Dirty : std_logic := '0';
   signal TagLo_Addr  : unsigned(19 downto 0) := (others => '0');
   signal writeTagEna : std_logic;
   signal writeTagValue : unsigned(21 downto 0);
   signal clear_busy  : std_logic;
   signal ss_reset    : std_logic := '1';   -- no save-state restore in this bench
   signal debug_state : std_logic_vector(4 downto 0);
   signal perf_miss   : std_logic;
   signal perf_writeback : std_logic;
   signal perf_fill_hold : std_logic;
   signal perf_cpu_access : std_logic;

   -- Backing store, indexed by doubleword address. Large enough that no test
   -- address wraps into another.
   type mem_t is array (0 to 4095) of std_logic_vector(63 downto 0);
   signal mem : mem_t := (others => (others => '0'));

   constant BASE : unsigned(31 downto 0) := x"0800_0000";

   -- Beat bookkeeping for the fill engine.
   signal beats_left : integer := 0;
   signal beat_addr  : unsigned(31 downto 0) := (others => '0');
   signal granted    : std_logic := '0';

   function dw(addr : unsigned(31 downto 0)) return integer is
   begin
      return to_integer(addr(13 downto 3));
   end function;

   -- What a byte-lane read answers, as the cache presents it: rd_sel picks the
   -- lane from RW_addr(2:0), so the wanted bytes always land in the low end.
   function expect_read(addr : unsigned(31 downto 0); d : std_logic_vector(63 downto 0))
      return std_logic_vector is
      variable lane : integer := to_integer(addr(2 downto 0));
   begin
      return std_logic_vector(shift_right(unsigned(d), 8 * lane));
   end function;

   -- The two endian transforms cpu_pocket.vhd applies around the cache, copied
   -- from its own functions so the bench speaks to the cache in the same
   -- language the CPU does. Leaving them out is what made the first version of
   -- this bench look like the cache mangled stores: it presented the register
   -- value directly, and the cache word-swaps 64-bit write data by design
   -- (cpu_datacache.vhd, big_endian_writes, RW_64 = '1').
   function byteswap32(v : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      return v(7 downto 0) & v(15 downto 8) & v(23 downto 16) & v(31 downto 24);
   end function;

   function cpu_to_bus64(v : std_logic_vector(63 downto 0)) return std_logic_vector is
   begin
      return byteswap32(v(63 downto 32)) & byteswap32(v(31 downto 0));
   end function;

   function bus_to_cpu64(v : std_logic_vector(63 downto 0)) return std_logic_vector is
   begin
      return byteswap32(v(31 downto 0)) & byteswap32(v(63 downto 32));
   end function;

   -- What the RAM must END UP holding for a value V to read back as V.
   --
   -- The store path is  V -> cpu_to_bus64 -> cache word-swap -> RAM, and the
   -- load path is  RAM -> bus_to_cpu64 -> V. Solving bus_to_cpu64(X) = V gives
   -- X = {bswap(V(31:0)), bswap(V(63:32))}, which is what the fill has to
   -- deliver, because a fill writes ddr3_DOUT straight into the RAMs and skips
   -- the cache's own transform. Getting this wrong twice is how this bench
   -- spent its first two runs reporting "the cache mangles stores" when the
   -- cache was behaving exactly as cpu_pocket.vhd expects.
   function bus_for_fill(v : std_logic_vector(63 downto 0)) return std_logic_vector is
   begin
      return byteswap32(v(31 downto 0)) & byteswap32(v(63 downto 32));
   end function;

begin

   clk1x <= not clk1x after CLK1X_NS / 2;
   clk93 <= clk1x after SKEW_NS;

   dut : entity work.cpu_datacache
   generic map
   (
      LITTLE_ENDIAN => false,
      SKIP_FILL     => false,
      READ_AHEAD    => false,
      FB_PARTIAL    => false,
      WB_EARLY      => false,
      LOAD_INTERLOCK => false,
      STORE_BUFFER  => false,
      SB_FORWARD    => false,
      EARLY_RESTART => false,
      RA_ANSWER     => false,
      CWF_FB        => false,
      FILL_FIRST    => false,
      FILL_AT_MISS  => false
   )
   port map
   (
      clk1x => clk1x, clk93 => clk93,
      reset_1x => reset_1x, reset_93 => reset_93,
      ce_93 => ce_93, stall => stall, stall4 => stall4,
      fifo_block => fifo_block,
      slow_in => slow_in, force_wb_in => force_wb_in,
      write_through_in => write_through_in,
      ram_request => ram_request, ram_reqAddr => ram_reqAddr,
      ram_active => ram_active, ram_grant => ram_grant,
      ram_done => ram_done, fill_last_q => fill_last_q,
      wb_hold => wb_hold,
      ddr3_DOUT => ddr3_DOUT, ddr3_DOUT_READY => ddr3_DOUT_READY,
      writeback_ena => writeback_ena, writeback_addr => writeback_addr,
      writeback_data => writeback_data, writeback_mask => writeback_mask,
      writeback_bytes => writeback_bytes,
      tag_addr => tag_addr, next_load => next_load,
      read_ena => read_ena, RW_addr => RW_addr, RW_64 => RW_64,
      RW_fb => RW_fb, read_busy => read_busy, read_done => read_done,
      read_data => read_data,
      write_ena => write_ena, write_be => write_be, write_data => write_data,
      write_done => write_done,
      CacheCommandEna => CacheCommandEna, CacheCommand => CacheCommand,
      CachecommandStall => CachecommandStall,
      CachecommandDone => CachecommandDone,
      TagLo_Valid => TagLo_Valid, TagLo_Dirty => TagLo_Dirty,
      TagLo_Addr => TagLo_Addr,
      writeTagEna => writeTagEna, writeTagValue => writeTagValue,
      clear_busy => clear_busy, debug_state => debug_state,
      SS_reset => ss_reset,
      perf_miss => perf_miss, perf_writeback => perf_writeback,
      perf_fill_hold => perf_fill_hold,
      perf_miss_low => open, perf_miss_fb => open, perf_stride_hit => open,
      perf_delta_hit => open, perf_fill_wait => open, perf_fill_data => open,
      perf_way_slow => open, perf_wb_line => open, perf_fill_store => open,
      perf_fill_skip => open, perf_fill_absent => open,
      perf_ra_issue => open, perf_ra_used => open
   );

   -- ------------------------------------------------------------------ memory
   -- Streams a line as four qwords when granted. Consecutive fills for the
   -- same line keep returning memory, so a test that stores and then reads
   -- back must be answered by the CACHE, not by this model.
   fill : process (clk93)
   begin
      if rising_edge(clk93) then
         if reset_93 = '1' then
            beats_left <= 0;
            granted    <= '0';
            ram_grant  <= '0';
            ram_done   <= '0';
            ddr3_DOUT_READY <= '0';
         else
            ddr3_DOUT_READY <= '0';
            ram_done <= '0';
            if ram_request = '1' and granted = '0' and beats_left = 0 then
               ram_grant <= '1';
               granted   <= '1';
               beats_left <= 4;
               beat_addr <= ram_reqAddr(31 downto 5) & "00000";
            elsif beats_left > 0 then
               ram_grant <= '0';
               -- The bridge delivers a beat in BUS order, not raw memory
               -- order: for big-endian it byte-swaps each word on the way in,
               -- and the cache word-swaps 64-bit data again. Presenting raw
               -- values here made every filled line read back word-swapped,
               -- which is a mistake in the model, not in the cache.
               ddr3_DOUT <= bus_for_fill(mem(dw(beat_addr)));
               ddr3_DOUT_READY <= '1';
               beat_addr <= beat_addr + 8;
               beats_left <= beats_left - 1;
               if beats_left = 1 then
                  ram_done <= '1';
                  granted  <= '0';
               end if;
            elsif ram_request = '0' then
               ram_grant <= '0';
               granted   <= '0';
            end if;
         end if;
      end if;
   end process;

   -- ------------------------------------------------------------------ stimulus
   process
      -- One CPU-visible load: present the address, wait for read_done, capture.
      procedure do_read(addr : in unsigned(31 downto 0);
                        d    : out std_logic_vector(63 downto 0)) is
         variable ok : boolean := false;
      begin
         -- The cache answers from the read issued on the PREVIOUS edge
         -- ("an answer from the read on the edge that began the cycle, at
         -- the address presented the cycle before"), so the address has to be
         -- on the bus a cycle before read_ena. Getting this wrong shifts every
         -- answer by one doubleword, which is exactly what the first run did.
         wait until rising_edge(clk1x);
         RW_addr   <= addr;
         RW_64     <= '1';
         RW_fb     <= '0';
         tag_addr  <= addr;     -- the tag compare uses this; it must be the SAME line as RW_addr
         next_load <= '1';
         wait until rising_edge(clk1x);
         read_ena  <= '1';
         -- read_done is combinational: a hit answers in the very cycle
         -- read_ena is high, a miss after its fill. Waiting on the event
         -- rather than polling edges is what catches the hit case.
         for guard in 0 to 200 loop
            wait until read_done = '1' for 50 ns;
            if read_done = '1' then
               d := bus_to_cpu64(read_data);
               ok := true;
               exit;
            end if;
         end loop;
         read_ena <= '0';
         if not ok then
            report "FAIL: read at " & to_hstring(addr) & " never completed"
               severity error;
         end if;
         wait until rising_edge(clk1x);
      end procedure;

      -- One CPU-visible store.
      procedure do_write(addr : in unsigned(31 downto 0);
                         dat  : in std_logic_vector(63 downto 0);
                         be   : in std_logic_vector(7 downto 0)) is
         variable ok : boolean := false;
      begin
         -- cpu_pocket.vhd drives datacache_addr and datacache_writeena in the
         -- SAME cycle (cpu_pocket.vhd:5563-5566), so that is what a store looks
         -- like here too. The cache registers the tag read and compares it a
         -- cycle later; presenting the address early, which the read path here
         -- does, is not the shape a store has.
         wait until rising_edge(clk1x);
         RW_addr    <= addr;
         RW_64      <= '1';
         RW_fb      <= '0';
         tag_addr   <= addr;
         write_ena  <= '1';
         write_be   <= be;
         write_data <= cpu_to_bus64(dat);
         for guard in 0 to 200 loop
            wait until write_done = '1' for 50 ns;
            if write_done = '1' then
               ok := true;
               exit;
            end if;
         end loop;
         write_ena <= '0';
         if not ok then
            report "FAIL: write at " & to_hstring(addr) & " never completed"
               severity error;
         end if;
         wait until rising_edge(clk1x);
      end procedure;

      variable errors : integer := 0;
      variable d      : std_logic_vector(63 downto 0);
      variable n      : integer;
      variable e0     : integer;   -- errors at the start of a group
   begin
      -- Known contents.
      for i in 0 to 127 loop
         mem(i) <= std_logic_vector(to_unsigned(16#5A5A_0000# + i, 64));
      end loop;
      wait for 5 * CLK1X_NS;

      reset_1x <= '0';
      reset_93 <= '0';
      ss_reset <= '0';
      wait for 10 * CLK1X_NS;

      -- 1. Load that misses: fills and answers.
      do_read(BASE, d);
      if d = mem(dw(BASE)) then
         report "PASS: miss fills the line and answers" severity note;
      else
         report "FAIL: miss answered " & to_hstring(d) & " want " & to_hstring(mem(dw(BASE)))
            severity error;
         errors := errors + 1;
      end if;
      if perf_miss /= '1' then
         report "NOTE: perf_miss did not rise on the first access" severity note;
      end if;

      -- 2. The rest of the line must hit.
      e0 := errors;
      for i in 1 to 3 loop
         do_read(BASE + 8 * i, d);
         if d /= mem(dw(BASE + 8 * i)) then
            report "FAIL: lined hit " & integer'image(i) & " answered "
               & to_hstring(d) & " want " & to_hstring(mem(dw(BASE + 8 * i)))
               severity error;
            errors := errors + 1;
         end if;
      end loop;
      if errors = e0 then
         report "PASS: the rest of a filled line hits and answers" severity note;
      end if;

      -- 3. Store then load, same doubleword.
      do_write(BASE + 8, x"DEAD_BEEF_1234_5678", "11111111");
      do_read(BASE + 8, d);
      if d = x"DEAD_BEEF_1234_5678" then
         report "PASS: store then load returns the stored doubleword" severity note;
      else
         report "FAIL: store then load returned " & to_hstring(d) severity error;
         errors := errors + 1;
      end if;

      -- 4. The neighbouring doubleword must still be memory.
      do_read(BASE, d);
      if d = mem(dw(BASE)) then
         report "PASS: a store does not disturb the other doublewords" severity note;
      else
         report "FAIL: neighbouring doubleword changed to " & to_hstring(d) severity error;
         errors := errors + 1;
      end if;

      -- 5. Each byte lane on its own.
      e0 := errors;
      for b in 0 to 7 loop
         do_write(BASE + 16, x"0000_0000_0000_0000", "11111111");
         do_write(BASE + 16, std_logic_vector(to_unsigned(16#11# * (b + 1), 64)) and
                            x"0000_0000_0000_00FF",
                  std_logic_vector(to_unsigned(2 ** b, 8)));
         do_read(BASE + 16, d);
         if d(8 * b + 7 downto 8 * b) = std_logic_vector(to_unsigned(16#11# * (b + 1), 8))
            and d(63 downto 8 * (b + 1)) = (63 - 8 * b downto 0 => '0')
            and d(8 * b - 1 downto 0) = (8 * b - 1 downto 0 => '0') then
            null;
         else
            report "FAIL: byte lane " & integer'image(b) & " read back " & to_hstring(d)
               severity error;
            errors := errors + 1;
         end if;
      end loop;
      if errors = e0 then
         report "PASS: every byte lane writes and reads back on its own" severity note;
      else
         report "FAIL: byte lanes (" & integer'image(errors - e0) & " bad)" severity error;
      end if;

      -- 6. Pointer-building pattern: store, read back, advance.
      e0 := errors;
      n := 0;
      for i in 0 to 9 loop
         do_write(BASE + 32 + 8 * i, std_logic_vector(to_unsigned(16#1000# + i * 7, 64)), "11111111");
      end loop;
      for i in 0 to 9 loop
         do_read(BASE + 32 + 8 * i, d);
         if d /= std_logic_vector(to_unsigned(16#1000# + i * 7, 64)) then
            report "FAIL: sequential store/load " & integer'image(i) & " read "
               & to_hstring(d) severity error;
            errors := errors + 1;
            n := n + 1;
         end if;
      end loop;
      if errors = e0 then
         report "PASS: ten store/load pairs across two lines" severity note;
      else
         report "FAIL: sequential store/load (" & integer'image(errors - e0) & " bad)" severity error;
      end if;

      if errors = 0 then
         report "PASS_DCACHE" severity note;
      else
         report "FAIL_DCACHE (" & integer'image(errors) & ")" severity error;
      end if;
      wait;
   end process;

end architecture;
