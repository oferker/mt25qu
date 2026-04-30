--------------------------------------------------------------------------------
-- MT25QU128ABA QSPI Package - Command opcodes and constants
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package mt25q_qspi_pkg is

    -- Extended SPI commands (1-1-x protocol)
    constant CMD_WRITE_ENABLE          : std_logic_vector(7 downto 0) := x"06";
    constant CMD_READ_STATUS_REG       : std_logic_vector(7 downto 0) := x"05";
    constant CMD_READ_ENH_VOL_CFG_REG  : std_logic_vector(7 downto 0) := x"65";
    constant CMD_WRITE_ENH_VOL_CFG_REG : std_logic_vector(7 downto 0) := x"61";
    constant CMD_SUBSECTOR_ERASE_4KB   : std_logic_vector(7 downto 0) := x"20";
    constant CMD_QUAD_OUTPUT_FAST_READ : std_logic_vector(7 downto 0) := x"6B";  -- 1-1-4
    constant CMD_QUAD_PAGE_PROGRAM     : std_logic_vector(7 downto 0) := x"32";  -- 1-1-4

    -- Quad I/O commands (4-4-4 protocol, used after quad mode enabled)
    constant CMD_QUAD_IO_FAST_READ     : std_logic_vector(7 downto 0) := x"EB";  -- 4-4-4
    constant CMD_PAGE_PROGRAM          : std_logic_vector(7 downto 0) := x"02";  -- 4-4-4 in quad mode

    -- Dummy cycle counts
    constant DUMMY_CYCLES              : integer := 8;   -- for 0x6B (extended SPI)
    constant DUMMY_CYCLES_QIO          : integer := 10;  -- for 0xEB (2 mode + 8 dummy)

end package mt25q_qspi_pkg;