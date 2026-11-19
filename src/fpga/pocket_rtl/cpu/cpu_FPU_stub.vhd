-- Measurement stub: same port list as cpu_FPU; outputs tied to zero except command_done (see below).
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity cpu_FPU_stub is
   port
   (
      clk93             : in  std_logic;
      reset             : in  std_logic;
      error_FPU         : out std_logic;
      csr_export        : out unsigned(24 downto 0);
      fpuRegMode        : in  std_logic;
      command_ena       : in  std_logic;
      command_code      : in  unsigned(31 downto 0);
      command_op1       : in  unsigned(63 downto 0);
      command_op2       : in  unsigned(63 downto 0);
      command_done      : out std_logic;
      transfer_ena      : in  std_logic;
      transfer_code     : in  unsigned(3 downto 0);
      transfer_RD       : in  unsigned(4 downto 0);
      transfer_value    : in  unsigned(63 downto 0);
      transfer_data     : out unsigned(63 downto 0);
      mul_result        : in  unsigned(127 downto 0);
      exceptionFPU      : out std_logic;
      FPU_CF            : out std_logic;
      FPUWriteTarget    : out unsigned(4 downto 0);
      FPUWriteData      : out unsigned(63 downto 0);
      FPUWriteEnable    : out std_logic;
      FPUWriteMask      : out std_logic_vector(1 downto 0);
      SS_FPU_CF         : in  std_logic;
      SS_CSR            : in  unsigned(24 downto 0)
   );
end;

architecture stub of cpu_FPU_stub is
begin
   csr_export     <= (others => '0');
   error_FPU      <= '0';
   -- NOT a constant '1'. cpu_pocket's stage 3 reads command_done every cycle
   -- ("FPU unstall": done with no forward use clears stall3), so a stuck '1'
   -- released every load-use bubble after one cycle, whether or not the load
   -- had answered - the dependent instruction then ran on the OLD register.
   -- That was the Pocket's AdEL at 0x8802EC48 (V187: `sll t8,t7,2` at
   -- 0x8802E51C used t7 from before `lw t7,28(sp)`). The real cpu_FPU drives
   -- '0' by default and '1' only alongside a command; answering every command
   -- in its own cycle keeps a COP1 op from hanging the pipeline (the
   -- "command_ena and not command_done" stall) without that side effect.
   command_done   <= command_ena;
   transfer_data  <= (others => '0');
   exceptionFPU   <= '0';
   FPU_CF         <= '0';
   FPUWriteTarget <= (others => '0');
   FPUWriteData   <= (others => '0');
   FPUWriteEnable <= '0';
   FPUWriteMask   <= (others => '0');
end;
