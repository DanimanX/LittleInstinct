-- Measurement stub: same port list as cpu_FPU, all outputs tied to zero.
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
   command_done   <= '1';
   transfer_data  <= (others => '0');
   exceptionFPU   <= '0';
   FPU_CF         <= '0';
   FPUWriteTarget <= (others => '0');
   FPUWriteData   <= (others => '0');
   FPUWriteEnable <= '0';
   FPUWriteMask   <= (others => '0');
end;
