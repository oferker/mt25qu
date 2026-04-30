--------------------------------------------------------------------------------
-- Package: MT25QU128ABA command definitions and constants  (v10)
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package mt25q_qspi_pkg is

    -- Command opcodes
    constant CMD_WRITE_ENABLE           : std_logic_vector(7 downto 0) := x"06";
    constant CMD_READ_STATUS_REG        : std_logic_vector(7 downto 0) := x"05";
    constant CMD_READ_FLAG_STATUS_REG   : std_logic_vector(7 downto 0) := x"70";
    constant CMD_READ_ENH_VOL_CFG_REG  : std_logic_vector(7 downto 0) := x"65";
    constant CMD_WRITE_ENH_VOL_CFG_REG : std_logic_vector(7 downto 0) := x"61";
    constant CMD_READ_ID                : std_logic_vector(7 downto 0) := x"9F";

    -- Quad SPI
    constant CMD_QUAD_PAGE_PROGRAM      : std_logic_vector(7 downto 0) := x"32"; -- 1-1-4
    constant CMD_QUAD_OUTPUT_FAST_READ  : std_logic_vector(7 downto 0) := x"6B"; -- 1-1-4
    constant CMD_QUAD_IO_FAST_READ      : std_logic_vector(7 downto 0) := x"EB"; -- 1-4-4

    -- Erase
    constant CMD_SUBSECTOR_ERASE_4KB    : std_logic_vector(7 downto 0) := x"20";
    constant CMD_SECTOR_ERASE_64KB      : std_logic_vector(7 downto 0) := x"D8";
    constant CMD_BULK_ERASE             : std_logic_vector(7 downto 0) := x"C7";

    -- Geometry
    constant PAGE_SIZE      : integer := 256;
    constant DUMMY_CYCLES   : integer := 8;   -- for 0x6B command

end package mt25q_qspi_pkg;