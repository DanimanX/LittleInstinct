-- Behavioural stand-in for rtl/cpu/RamMLAB.vhd, for simulation only.
--
-- RamMLAB wraps altdpram with ram_block_type => "MLAB", which will not
-- elaborate without Altera's megafunction library. This model reproduces the
-- semantics that configuration gives (from RamMLAB.vhd's generic map):
--
--   indata_reg / wrcontrol_wraddress_reg  INCLOCK        write on inclock
--   rdaddress_reg / address_reg           UNREGISTERED    no read address latch
--   outdata_reg                           UNREGISTERED    q is combinational
--
-- So this is a plain single-clock RAM with an asynchronous read: a write lands
-- on the inclock edge and shows at q immediately, with no read latency. That
-- matters to cpu_instrcache, which reads the tag a cycle before it compares it
-- and relies on the tag being there.
--
-- The store lives in a variable inside one process on purpose: two processes
-- assigning elements of one array signal are two drivers, and VHDL resolves an
-- element no driver wrote to 'U'.
--
-- NOT modelled: MLAB versus M10K placement, byte-enable lanes (width_byteena
-- is never set away from 1 by this design), and power-up contents.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity RamMLAB is
   generic
   (
      width         : natural;
      width_byteena : natural := 1;
      widthad       : natural
   );
   port
   (
      inclock   : in  std_logic;
      wren      : in  std_logic;
      data      : in  std_logic_vector(width-1 downto 0);
      wraddress : in  std_logic_vector(widthad-1 downto 0);
      rdaddress : in  std_logic_vector(widthad-1 downto 0);
      q         : out std_logic_vector(width-1 downto 0)
   );
end entity;

architecture sim of RamMLAB is
   type mem_t is array (0 to 2**widthad - 1) of std_logic_vector(width-1 downto 0);
begin
   ram : process (inclock, rdaddress)
      variable mem : mem_t := (others => (others => '0'));
      variable ia  : integer;
   begin
      if rising_edge(inclock) and wren = '1' then
         ia := to_integer(unsigned(wraddress));
         mem(ia) := data;
      end if;
      q <= mem(to_integer(unsigned(rdaddress)));
   end process;
end architecture;
