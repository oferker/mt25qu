--------------------------------------------------------------------------------
-- MT25QU128ABA Generic SPI Transaction Engine (v20)
--
-- The controller is a DUMB SPI engine. The user provides:
--   cmd_code        : the raw 8-bit opcode to send
--   cmd_mode        : "00"=extended(1-1-1), "01"=dual(2-2-2), "10"=quad(4-4-4)
--   cmd_has_addr    : '1' to include 24-bit address phase
--   cmd_has_data    : '1' to include data phase
--   cmd_data_dir    : '0'=write, '1'=read
--   cmd_dummy_cycles: number of dummy SCK cycles (0=none)
--   cmd_len         : number of data bytes (0..256)
--
-- The controller shifts CMD -> ADDR -> DUMMY -> DATA on the correct number
-- of IO lines based on cmd_mode. No automatic WREN, no WIP polling.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mt25q_qspi_ctrl is
    generic (
        CLK_DIV    : integer := 4;
        CS_GAP_LEN : integer := 10
    );
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;

        -- Command interface
        cmd_start        : in  std_logic;
        cmd_code         : in  std_logic_vector(7 downto 0);
        cmd_mode         : in  std_logic_vector(1 downto 0);
        cmd_addr         : in  std_logic_vector(23 downto 0);
        cmd_has_addr     : in  std_logic;
        cmd_has_data     : in  std_logic;
        cmd_data_dir     : in  std_logic;
        cmd_dummy_cycles : in  std_logic_vector(4 downto 0);
        cmd_len          : in  std_logic_vector(8 downto 0);
        busy             : out std_logic;

        -- Write data (user -> controller)
        wr_data          : in  std_logic_vector(7 downto 0);
        wr_valid         : in  std_logic;
        wr_ready         : out std_logic;

        -- Read data (controller -> user)
        rd_data          : out std_logic_vector(7 downto 0);
        rd_valid         : out std_logic;

        -- SPI physical pins
        spi_sck          : out std_logic;
        spi_cs_n         : out std_logic;
        spi_io_i         : in  std_logic_vector(3 downto 0);
        spi_io_o         : out std_logic_vector(3 downto 0);
        spi_io_t         : out std_logic_vector(3 downto 0)
    );
end entity mt25q_qspi_ctrl;

architecture rtl of mt25q_qspi_ctrl is

    type state_t is (
        S_IDLE,
        S_CS_GAP,
        S_SEND_CMD,
        S_SEND_ADDR,
        S_DUMMY,
        S_DATA_WRITE,
        S_DATA_READ,
        S_DONE
    );

    signal state       : state_t := S_IDLE;

    -- CS gap
    signal gap_cnt     : integer range 0 to CS_GAP_LEN := 0;

    -- SPI clock divider
    signal clk_cnt     : integer range 0 to CLK_DIV - 1 := 0;
    signal sck_en      : std_logic := '0';
    signal sck_reg     : std_logic := '0';
    signal sck_rising  : std_logic;
    signal sck_falling : std_logic;

    -- Shift register and bit counter
    signal shift_reg   : std_logic_vector(31 downto 0) := (others => '0');
    signal bit_cnt     : integer range 0 to 63 := 0;

    -- Byte counter
    signal byte_cnt    : unsigned(8 downto 0) := (others => '0');

    -- Saved command parameters
    signal s_code      : std_logic_vector(7 downto 0);
    signal s_mode      : std_logic_vector(1 downto 0);
    signal s_addr      : std_logic_vector(23 downto 0);
    signal s_has_addr  : std_logic;
    signal s_has_data  : std_logic;
    signal s_data_dir  : std_logic;
    signal s_dummy     : integer range 0 to 31;
    signal s_len       : unsigned(8 downto 0);

    -- Nibble/bit accumulator for reads
    signal nibble_cnt  : integer range 0 to 7 := 0;
    signal rx_byte     : std_logic_vector(7 downto 0);

    -- Nibble/bit counter for writes
    signal tx_byte     : std_logic_vector(7 downto 0);
    signal tx_sub_cnt  : integer range 0 to 7 := 0;
    signal need_data   : std_logic := '0';

    -- CS control
    signal cs_n        : std_logic := '1';

    -- IO output / tristate
    signal io_out      : std_logic_vector(3 downto 0) := "0000";
    signal io_tri      : std_logic_vector(3 downto 0) := "1111";

    -- Helper: tristate mask for output in given mode
    function out_tri(mode : std_logic_vector(1 downto 0)) return std_logic_vector is
    begin
        case mode is
            when "00"   => return "1110";  -- extended: IO[0] driven
            when "01"   => return "1100";  -- dual: IO[1:0] driven
            when "10"   => return "0000";  -- quad: IO[3:0] driven
            when others => return "1110";
        end case;
    end function;

    -- Helper: bits per clock edge for given mode
    function bits_per_edge(mode : std_logic_vector(1 downto 0)) return integer is
    begin
        case mode is
            when "00"   => return 1;
            when "01"   => return 2;
            when "10"   => return 4;
            when others => return 1;
        end case;
    end function;

    -- Helper: number of SCK edges to shift N bits in given mode
    function edges_needed(nbits : integer; mode : std_logic_vector(1 downto 0)) return integer is
    begin
        return nbits / bits_per_edge(mode);
    end function;

begin

    ----------------------------------------------------------------
    -- SPI Clock Generation
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or sck_en = '0' then
                clk_cnt <= 0;
                sck_reg <= '0';
            else
                if clk_cnt = CLK_DIV - 1 then
                    clk_cnt <= 0;
                    sck_reg <= not sck_reg;
                else
                    clk_cnt <= clk_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    sck_rising  <= '1' when clk_cnt = CLK_DIV - 1 and sck_reg = '0' and sck_en = '1' else '0';
    sck_falling <= '1' when clk_cnt = CLK_DIV - 1 and sck_reg = '1' and sck_en = '1' else '0';

    spi_sck  <= sck_reg;
    spi_cs_n <= cs_n;
    spi_io_o <= io_out;
    spi_io_t <= io_tri;

    ----------------------------------------------------------------
    -- Main FSM
    ----------------------------------------------------------------
    process(clk)
        variable v_bpe : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state    <= S_IDLE;
                cs_n     <= '1';
                sck_en   <= '0';
                io_tri   <= "1111";
                io_out   <= "0000";
                rd_valid <= '0';
                wr_ready <= '0';
                need_data <= '0';
            else
                rd_valid <= '0';
                wr_ready <= '0';

                case state is

                --------------------------------------------------------
                -- IDLE
                --------------------------------------------------------
                when S_IDLE =>
                    io_tri <= "1111";
                    io_out <= "0000";
                    if cmd_start = '1' then
                        s_code     <= cmd_code;
                        s_mode     <= cmd_mode;
                        s_addr     <= cmd_addr;
                        s_has_addr <= cmd_has_addr;
                        s_has_data <= cmd_has_data;
                        s_data_dir <= cmd_data_dir;
                        s_dummy    <= to_integer(unsigned(cmd_dummy_cycles));
                        s_len      <= unsigned(cmd_len);

                        gap_cnt <= CS_GAP_LEN;
                        state   <= S_CS_GAP;
                    end if;

                --------------------------------------------------------
                -- CS GAP - ensure CS# high for CS_GAP_LEN cycles
                --------------------------------------------------------
                when S_CS_GAP =>
                    cs_n   <= '1';
                    sck_en <= '0';
                    io_tri <= "1111";
                    if gap_cnt = 0 then
                        -- Assert CS, enable clock, start command phase
                        cs_n   <= '0';
                        sck_en <= '1';
                        io_tri <= out_tri(s_mode);

                        -- Pre-drive first bits of opcode
                        case s_mode is
                            when "10" =>  -- quad: 4 bits
                                io_out <= s_code(7 downto 4);
                            when "01" =>  -- dual: 2 bits
                                io_out <= "00" & s_code(7 downto 6);
                            when others =>  -- extended: 1 bit
                                io_out <= "000" & s_code(7);
                        end case;

                        -- Load shift reg with remaining opcode bits
                        shift_reg(31 downto 24) <= s_code;
                        bit_cnt <= edges_needed(8, s_mode) - 1;
                        state   <= S_SEND_CMD;
                    else
                        gap_cnt <= gap_cnt - 1;
                    end if;

                --------------------------------------------------------
                -- SEND COMMAND - shift out 8-bit opcode
                --------------------------------------------------------
                when S_SEND_CMD =>
                    if sck_falling = '1' then
                        v_bpe := bits_per_edge(s_mode);
                        -- Shift out next chunk
                        case s_mode is
                            when "10" =>
                                io_out <= shift_reg(27 downto 24);
                                shift_reg(31 downto 24) <= shift_reg(27 downto 24) & "0000";
                            when "01" =>
                                io_out <= "00" & shift_reg(29 downto 28);
                                shift_reg(31 downto 24) <= shift_reg(29 downto 24) & "00";
                            when others =>
                                io_out <= "000" & shift_reg(30);
                                shift_reg(31 downto 24) <= shift_reg(30 downto 24) & '0';
                        end case;

                        if bit_cnt = 0 then
                            -- Command done, what's next?
                            if s_has_addr = '1' then
                                -- Load address
                                shift_reg(31 downto 8) <= s_addr;
                                bit_cnt <= edges_needed(24, s_mode) - 1;

                                -- Pre-drive first address chunk
                                case s_mode is
                                    when "10" =>
                                        io_out <= s_addr(23 downto 20);
                                    when "01" =>
                                        io_out <= "00" & s_addr(23 downto 22);
                                    when others =>
                                        io_out <= "000" & s_addr(23);
                                end case;

                                state <= S_SEND_ADDR;
                            elsif s_dummy > 0 then
                                bit_cnt <= s_dummy - 1;
                                io_tri  <= "1111";
                                state   <= S_DUMMY;
                            elsif s_has_data = '1' then
                                byte_cnt <= s_len;
                                if s_data_dir = '1' then
                                    io_tri     <= "1111";
                                    nibble_cnt <= 0;
                                    state      <= S_DATA_READ;
                                else
                                    io_tri    <= out_tri(s_mode);
                                    need_data <= '1';
                                    tx_sub_cnt <= 0;
                                    state     <= S_DATA_WRITE;
                                end if;
                            else
                                state <= S_DONE;
                            end if;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                -- SEND 24-BIT ADDRESS
                --------------------------------------------------------
                when S_SEND_ADDR =>
                    if sck_falling = '1' then
                        -- Shift out next chunk
                        case s_mode is
                            when "10" =>
                                io_out <= shift_reg(27 downto 24);
                                shift_reg(31 downto 8) <= shift_reg(27 downto 8) & "0000";
                            when "01" =>
                                io_out <= "00" & shift_reg(29 downto 28);
                                shift_reg(31 downto 8) <= shift_reg(29 downto 8) & "00";
                            when others =>
                                io_out <= "000" & shift_reg(30);
                                shift_reg(31 downto 8) <= shift_reg(30 downto 8) & '0';
                        end case;

                        if bit_cnt = 0 then
                            if s_dummy > 0 then
                                bit_cnt <= s_dummy - 1;
                                io_tri  <= "1111";
                                state   <= S_DUMMY;
                            elsif s_has_data = '1' then
                                byte_cnt <= s_len;
                                if s_data_dir = '1' then
                                    io_tri     <= "1111";
                                    nibble_cnt <= 0;
                                    state      <= S_DATA_READ;
                                else
                                    io_tri    <= out_tri(s_mode);
                                    need_data <= '1';
                                    tx_sub_cnt <= 0;
                                    state     <= S_DATA_WRITE;
                                end if;
                            else
                                state <= S_DONE;
                            end if;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                -- DUMMY CYCLES
                --------------------------------------------------------
                when S_DUMMY =>
                    io_tri <= "1111";
                    if sck_falling = '1' then
                        if bit_cnt = 0 then
                            if s_has_data = '1' then
                                byte_cnt <= s_len;
                                if s_data_dir = '1' then
                                    nibble_cnt <= 0;
                                    state      <= S_DATA_READ;
                                else
                                    io_tri    <= out_tri(s_mode);
                                    need_data <= '1';
                                    tx_sub_cnt <= 0;
                                    state     <= S_DATA_WRITE;
                                end if;
                            else
                                state <= S_DONE;
                            end if;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                -- DATA READ
                -- Extended: 8 edges/byte, sample IO[1]
                -- Dual:     4 edges/byte, sample IO[1:0]
                -- Quad:     2 edges/byte, sample IO[3:0]
                --------------------------------------------------------
                when S_DATA_READ =>
                    io_tri <= "1111";
                    if sck_rising = '1' then
                        case s_mode is
                            when "10" =>  -- quad: 2 edges per byte
                                if nibble_cnt = 0 then
                                    rx_byte(7 downto 4) <= spi_io_i;
                                    nibble_cnt <= 1;
                                else
                                    rd_data    <= rx_byte(7 downto 4) & spi_io_i;
                                    rd_valid   <= '1';
                                    nibble_cnt <= 0;
                                    byte_cnt   <= byte_cnt - 1;
                                    if byte_cnt = 1 then
                                        state <= S_DONE;
                                    end if;
                                end if;

                            when "01" =>  -- dual: 4 edges per byte
                                case nibble_cnt is
                                    when 0 =>
                                        rx_byte(7 downto 6) <= spi_io_i(1 downto 0);
                                        nibble_cnt <= 1;
                                    when 1 =>
                                        rx_byte(5 downto 4) <= spi_io_i(1 downto 0);
                                        nibble_cnt <= 2;
                                    when 2 =>
                                        rx_byte(3 downto 2) <= spi_io_i(1 downto 0);
                                        nibble_cnt <= 3;
                                    when 3 =>
                                        rd_data    <= rx_byte(7 downto 2) & spi_io_i(1 downto 0);
                                        rd_valid   <= '1';
                                        nibble_cnt <= 0;
                                        byte_cnt   <= byte_cnt - 1;
                                        if byte_cnt = 1 then
                                            state <= S_DONE;
                                        end if;
                                    when others =>
                                        nibble_cnt <= 0;
                                end case;

                            when others =>  -- extended: 8 edges per byte, on IO[1]
                                rx_byte <= rx_byte(6 downto 0) & spi_io_i(1);
                                if nibble_cnt = 7 then
                                    rd_data    <= rx_byte(6 downto 0) & spi_io_i(1);
                                    rd_valid   <= '1';
                                    nibble_cnt <= 0;
                                    byte_cnt   <= byte_cnt - 1;
                                    if byte_cnt = 1 then
                                        state <= S_DONE;
                                    end if;
                                else
                                    nibble_cnt <= nibble_cnt + 1;
                                end if;
                        end case;
                    end if;

                --------------------------------------------------------
                -- DATA WRITE
                -- Extended: 8 edges/byte on IO[0]
                -- Dual:     4 edges/byte on IO[1:0]
                -- Quad:     2 edges/byte on IO[3:0]
                --------------------------------------------------------
                when S_DATA_WRITE =>
                    if need_data = '1' then
                        wr_ready <= '1';
                        if wr_valid = '1' then
                            tx_byte    <= wr_data;
                            need_data  <= '0';
                            tx_sub_cnt <= 0;
                        end if;
                    elsif sck_falling = '1' then
                        case s_mode is
                            when "10" =>  -- quad
                                if tx_sub_cnt = 0 then
                                    io_out     <= tx_byte(7 downto 4);
                                    tx_sub_cnt <= 1;
                                else
                                    io_out     <= tx_byte(3 downto 0);
                                    tx_sub_cnt <= 0;
                                    byte_cnt   <= byte_cnt - 1;
                                    if byte_cnt = 1 then
                                        state <= S_DONE;
                                    else
                                        need_data <= '1';
                                    end if;
                                end if;

                            when "01" =>  -- dual
                                case tx_sub_cnt is
                                    when 0 =>
                                        io_out <= "00" & tx_byte(7 downto 6);
                                        tx_sub_cnt <= 1;
                                    when 1 =>
                                        io_out <= "00" & tx_byte(5 downto 4);
                                        tx_sub_cnt <= 2;
                                    when 2 =>
                                        io_out <= "00" & tx_byte(3 downto 2);
                                        tx_sub_cnt <= 3;
                                    when 3 =>
                                        io_out <= "00" & tx_byte(1 downto 0);
                                        tx_sub_cnt <= 0;
                                        byte_cnt   <= byte_cnt - 1;
                                        if byte_cnt = 1 then
                                            state <= S_DONE;
                                        else
                                            need_data <= '1';
                                        end if;
                                    when others =>
                                        tx_sub_cnt <= 0;
                                end case;

                            when others =>  -- extended
                                io_out <= "000" & tx_byte(7 - tx_sub_cnt);
                                if tx_sub_cnt = 7 then
                                    tx_sub_cnt <= 0;
                                    byte_cnt   <= byte_cnt - 1;
                                    if byte_cnt = 1 then
                                        state <= S_DONE;
                                    else
                                        need_data <= '1';
                                    end if;
                                else
                                    tx_sub_cnt <= tx_sub_cnt + 1;
                                end if;
                        end case;
                    end if;

                --------------------------------------------------------
                -- DONE
                --------------------------------------------------------
                when S_DONE =>
                    cs_n   <= '1';
                    sck_en <= '0';
                    io_tri <= "1111";
                    io_out <= "0000";
                    state  <= S_IDLE;

                when others =>
                    state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

    busy <= '0' when state = S_IDLE else '1';

end architecture rtl;