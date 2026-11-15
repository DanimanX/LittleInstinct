-- Behavioural stand-in for rtl/cpu/dpram.vhd, for simulation only.
--
-- dpram.vhd wraps altsyncram, and any simulator without Altera's megafunction
-- library (GHDL included) cannot elaborate it. This model reproduces the
-- semantics of the configuration dpram.vhd actually requests:
--
--   operation_mode                BIDIR_DUAL_PORT   true dual port
--   address_reg_a / _b            CLOCK0 / CLOCK1   read address is registered
--   outdata_reg_a / _b            UNREGISTERED      q is combinational from that
--                                                   registered address: one clock
--   read_during_write_mode_port_* NEW_DATA_NO_NBE_READ
--                                                   a read of the address written
--                                                   in the same cycle sees the NEW
--                                                   data
--   clock_enable_input_a / _b     NORMAL            clken gates the port
--
-- The one-lag read and the new-data-during-write both matter to the caches:
-- cpu_datacache reads expecting the registered address, and a store's
-- read-modify-write has to see its own write.
--
-- The store lives in a VARIABLE inside a single process sensitive to both
-- clocks. That is not a shortcut: two processes assigning elements of one
-- array signal are two drivers, and an element no driver wrote resolves to
-- 'U'. The first version of this model did that, and every lane the second
-- port had not touched came back as X.
--
-- NOT modelled: MLAB versus M10K placement, and power-up contents beyond the
-- zeros altsyncram is asked for (power_up_uninitialized => "FALSE").
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram is
   generic
   (
      addr_width : integer := 8;
      data_width : integer := 8
   );
   port
   (
      clock_a   : in  std_logic;
      clken_a   : in  std_logic := '1';
      address_a : in  std_logic_vector(addr_width-1 downto 0);
      data_a    : in  std_logic_vector(data_width-1 downto 0);
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width-1 downto 0);

      clock_b   : in  std_logic;
      clken_b   : in  std_logic := '1';
      address_b : in  std_logic_vector(addr_width-1 downto 0);
      data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width-1 downto 0)
   );
end entity;

architecture sim of dpram is
   type mem_t is array (0 to 2**addr_width - 1) of std_logic_vector(data_width-1 downto 0);
begin
   dual : process (clock_a, clock_b)
      variable mem  : mem_t := (others => (others => '0'));
      variable ra_a : integer range 0 to 2**addr_width - 1 := 0;
      variable ra_b : integer range 0 to 2**addr_width - 1 := 0;
      variable ia   : integer;
      variable ib   : integer;
   begin
      if rising_edge(clock_a) and clken_a = '1' then
         ia := to_integer(unsigned(address_a));
         if wren_a = '1' then
            mem(ia) := data_a;
         end if;
         ra_a := ia;
      end if;
      q_a <= mem(ra_a);

      if rising_edge(clock_b) and clken_b = '1' then
         ib := to_integer(unsigned(address_b));
         if wren_b = '1' then
            mem(ib) := data_b;
         end if;
         ra_b := ib;
      end if;
      q_b <= mem(ra_b);
   end process;
end architecture;

-- ---------------------------------------------------------------------------
-- dpram_dif: the second RAM entity dpram.vhd defines, with independent port
-- widths and chip selects. cpu_instrcache uses it for the data array.
--
-- Configuration, from dpram.vhd's generic map for this entity:
--   address_reg_a   default (UNREGISTERED)  port A reads asynchronously
--   address_reg_b   CLOCK1                  port B read address is registered
--   outdata_reg_*   UNREGISTERED            q combinational from that address
--   read_during_write_mode_port_*  NEW_DATA
--   cs_*            a deselected port drives its q to all ones, as dpram.vhd's
--                   own SYN architecture does (q <= (others => '1'))
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_dif is
   generic
   (
      addr_width_a : integer := 8;
      data_width_a : integer := 8;
      addr_width_b : integer := 8;
      data_width_b : integer := 8
   );
   port
   (
      clock_a   : in  std_logic;
      address_a : in  std_logic_vector(addr_width_a-1 downto 0);
      data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
      clken_a   : in  std_logic := '1';
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width_a-1 downto 0);
      cs_a      : in  std_logic := '1';

      clock_b   : in  std_logic;
      address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
      data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
      clken_b   : in  std_logic := '1';
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width_b-1 downto 0);
      cs_b      : in  std_logic := '1'
   );
end entity;

architecture sim of dpram_dif is
   -- The wider of the two organisations sizes the array; a design that gives
   -- the ports different widths reads the same words through both.
   -- VHDL has no ternary: "a > b and a or b" mixes and/or around a relation
   -- and is illegal, and integer'max is not available here either.
   function imax(a, b : integer) return integer is
   begin
      if a > b then return a; else return b; end if;
   end function;
   constant AW : integer := imax(addr_width_a, addr_width_b);
   constant DW : integer := imax(data_width_a, data_width_b);
   type mem_t is array (0 to 2**AW - 1) of std_logic_vector(DW-1 downto 0);
begin
   dual : process (clock_a, clock_b, address_a, cs_a, cs_b)
      variable mem  : mem_t := (others => (others => '0'));
      variable ra_b : integer range 0 to 2**AW - 1 := 0;
      variable ia   : integer;
      variable ib   : integer;
   begin
      if rising_edge(clock_a) and clken_a = '1' and wren_a = '1' and cs_a = '1' then
         ia := to_integer(unsigned(address_a));
         mem(ia)(data_width_a-1 downto 0) := data_a;
      end if;
      if cs_a = '1' then
         q_a <= mem(to_integer(unsigned(address_a)))(data_width_a-1 downto 0);
      else
         q_a <= (others => '1');
      end if;

      if rising_edge(clock_b) and clken_b = '1' then
         ib := to_integer(unsigned(address_b));
         if wren_b = '1' and cs_b = '1' then
            mem(ib)(data_width_b-1 downto 0) := data_b;
         end if;
         ra_b := ib;
      end if;
      if cs_b = '1' then
         q_b <= mem(ra_b)(data_width_b-1 downto 0);
      else
         q_b <= (others => '1');
      end if;
   end process;
end architecture;
