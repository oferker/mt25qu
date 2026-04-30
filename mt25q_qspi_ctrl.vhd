--------------------------------------------------------------------------------
-- MT25QU128ABA Quad-SPI Controller  (v12)
--
-- Features:
--   - Quad Page Program (0x32): cmd & addr on 1 line, data on 4 lines
--   - Quad Output Fast Read (0x6B): cmd & addr on 1 line, data on 4 lines
--   - Subsector Erase 4KB (0x20)
--   - Automatic Write Enable before program/erase
--   - Automatic WIP polling after program/erase
--   - Enable Quad mode via Enhanced Volatile Config Register
--   - CS# held high for at least 10 clk cycles between SPI transactions
--
-- Interface:
--   cmd_start   : pulse high for 1 clock to begin an operation
--   cmd_op      : "00" = Quad Read, "01" = Quad Page Program,
--                 "10" = Subsector Erase, "11" = Enable Quad Mode
--   cmd_addr    : 24-bit flash address
--   cmd_len     : number of bytes to read or write (max 256)
--   busy        : high while controller is working
--
--   wr_data     : byte to write, sampled when wr_valid='1'
--   wr_valid    : push interface - user presents data
--   wr_ready    : controller can accept next byte
--
--   rd_data     : byte read from flash
--   rd_valid    : high for 1 clock when rd_data is valid
--
-- QSPI physical pins:
--   spi_sck     : serial clock output
--   spi_cs_n    : chip select, active low
--   spi_io_o    : output data to flash IO[3:0]
--   spi_io_i    : input data from flash IO[3:0]
--   spi_io_t    : tristate control per pin
--                 '1' = high-Z (input/tristate), '0' = driven (output)
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mt25q_qspi_pkg.all;

entity mt25q_qspi_ctrl is
    generic (
        CLK_DIV    : integer := 4;  -- spi_sck = clk / (2 * CLK_DIV)
        CS_GAP_LEN : integer := 10  -- minimum clk cycles CS# stays high between transactions
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        -- Command interface
        cmd_start   : in  std_logic;
        cmd_op      : in  std_logic_vector(1 downto 0);
        cmd_addr    : in  std_logic_vector(23 downto 0);
        cmd_len     : in  unsigned(8 downto 0);           -- 0..256
        busy        : out std_logic;

        -- Write data interface (user -> controller)
        wr_data     : in  std_logic_vector(7 downto 0);
        wr_valid    : in  std_logic;
        wr_ready    : out std_logic;

        -- Read data interface (controller -> user)
        rd_data     : out std_logic_vector(7 downto 0);
        rd_valid    : out std_logic;

        -- QSPI physical pins
        spi_sck     : out std_logic;
        spi_cs_n    : out std_logic;
        spi_io_i    : in  std_logic_vector(3 downto 0);
        spi_io_o    : out std_logic_vector(3 downto 0);
        spi_io_t    : out std_logic_vector(3 downto 0)  -- '1'=input, '0'=output
    );
end entity mt25q_qspi_ctrl;

architecture rtl of mt25q_qspi_ctrl is

    -- Main FSM
    type state_t is (
        S_IDLE,
        S_CS_GAP,
        S_WREN_CMD,
        S_SEND_CMD,
        S_SEND_ADDR,
        S_DUMMY,
        S_QUAD_READ,
        S_QUAD_WRITE,
        S_POLL_CMD,
        S_POLL_READ,
        S_POLL_WAIT,
        S_EQCFG_READ_CMD,
        S_EQCFG_READ_DATA,
        S_EQCFG_WREN,
        S_EQCFG_WRITE_CMD,
        S_EQCFG_WRITE_DATA,
        S_DONE
    );

    signal state        : state_t := S_IDLE;
    signal return_state : state_t := S_IDLE;

    -- CS gap counter and return state
    signal gap_cnt      : integer range 0 to CS_GAP_LEN - 1 := 0;
    signal gap_return   : state_t := S_IDLE;

    -- SPI clock divider
    signal clk_cnt      : integer range 0 to CLK_DIV - 1 := 0;
    signal sck_en       : std_logic := '0';
    signal sck_reg      : std_logic := '0';
    signal sck_rising   : std_logic;
    signal sck_falling  : std_logic;

    -- Shift register and bit counter
    signal shift_reg    : std_logic_vector(31 downto 0) := (others => '0');
    signal bit_cnt      : integer range 0 to 63 := 0;

    -- Byte counter for data phase
    signal byte_cnt     : unsigned(8 downto 0) := (others => '0');

    -- Saved command parameters
    signal saved_op     : std_logic_vector(1 downto 0);
    signal saved_addr   : std_logic_vector(23 downto 0);
    signal saved_len    : unsigned(8 downto 0);
    signal saved_opcode : std_logic_vector(7 downto 0);

    -- Nibble accumulator for quad read
    signal nibble_cnt   : integer range 0 to 1 := 0;
    signal rx_byte      : std_logic_vector(7 downto 0);

    -- Nibble counter for quad write
    signal tx_byte      : std_logic_vector(7 downto 0);
    signal tx_nib_cnt   : integer range 0 to 1 := 0;
    signal need_data    : std_logic := '0';

    -- CS control
    signal cs_n         : std_logic := '1';

    -- IO output / tristate
    signal io_out       : std_logic_vector(3 downto 0) := "0000";
    signal io_tri       : std_logic_vector(3 downto 0) := "1111";

    -- Status byte captured during polling
    signal status_byte  : std_logic_vector(7 downto 0);

    -- Config register value for quad enable
    signal cfg_reg_val  : std_logic_vector(7 downto 0);

begin

    -- SPI Clock Generation
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or sck_en = '0' then
                clk_cnt  <= 0;
                sck_reg  <= '0';
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

    -- Main FSM
    process(clk)
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
            else
                rd_valid <= '0';
                wr_ready <= '0';

                case state is

                --------------------------------------------------------
                --  IDLE - wait for a command
                --------------------------------------------------------
                when S_IDLE =>
                    if cmd_start = '1' then
                        saved_op   <= cmd_op;
                        saved_addr <= cmd_addr;
                        saved_len  <= cmd_len;

                        case cmd_op is
                            when "00" =>  -- Quad Read
                                saved_opcode <= CMD_QUAD_OUTPUT_FAST_READ;
                                state        <= S_SEND_CMD;
                                return_state <= S_SEND_ADDR;
                            when "01" =>  -- Quad Page Program (needs WREN)
                                saved_opcode <= CMD_QUAD_PAGE_PROGRAM;
                                state        <= S_WREN_CMD;
                            when "10" =>  -- Subsector Erase (needs WREN)
                                saved_opcode <= CMD_SUBSECTOR_ERASE_4KB;
                                state        <= S_WREN_CMD;
                            when "11" =>  -- Enable Quad Mode
                                state <= S_EQCFG_READ_CMD;
                            when others =>
                                state <= S_IDLE;
                        end case;
                    end if;

                --------------------------------------------------------
                --  CS GAP - hold CS# high for CS_GAP_LEN clk cycles
                --  before proceeding to the next SPI transaction
                --------------------------------------------------------
                when S_CS_GAP =>
                    cs_n   <= '1';
                    sck_en <= '0';
                    io_tri <= "1111";
                    if gap_cnt = 0 then
                        state <= gap_return;
                    else
                        gap_cnt <= gap_cnt - 1;
                    end if;

                --------------------------------------------------------
                --  WRITE ENABLE (0x06) - 8 bits on SIO0
                --------------------------------------------------------
                when S_WREN_CMD =>
                    cs_n      <= '0';
                    sck_en    <= '1';
                    io_tri    <= "1110";   -- only IO0 output
                    io_out(0) <= CMD_WRITE_ENABLE(7);  -- pre-drive MSB
                    shift_reg(31 downto 24) <= CMD_WRITE_ENABLE(6 downto 0) & '0';
                    bit_cnt   <= 7;
                    state     <= S_SEND_CMD;
                    return_state <= S_DONE;

                --------------------------------------------------------
                --  SEND COMMAND opcode - 8 bits, single line (IO0)
                --------------------------------------------------------
                when S_SEND_CMD =>
                    if state = S_SEND_CMD and cs_n = '1' then
                        -- First entry: assert CS, load shift reg
                        cs_n      <= '0';
                        sck_en    <= '1';
                        io_tri    <= "1110";  -- IO0 = output
                        if return_state /= S_DONE then
                            -- Normal command (not WREN): pre-drive MSB
                            io_out(0) <= saved_opcode(7);
                            shift_reg(31 downto 24) <= saved_opcode(6 downto 0) & '0';
                        end if;
                        bit_cnt <= 7;
                    elsif sck_falling = '1' then
                        io_out(0) <= shift_reg(31);
                        shift_reg <= shift_reg(30 downto 0) & '0';
                        if bit_cnt = 0 then
                            -- Opcode fully shifted out
                            if return_state = S_DONE then
                                -- This was WREN: deassert CS, gap, then
                                -- re-enter to send the real opcode
                                cs_n         <= '1';
                                sck_en       <= '0';
                                gap_cnt      <= CS_GAP_LEN - 1;
                                gap_return   <= S_SEND_CMD;
                                return_state <= S_SEND_ADDR;
                                state        <= S_CS_GAP;
                            else
                                -- Real opcode done, move to address phase
                                state <= return_state;
                            end if;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                --  SEND 24-bit ADDRESS - single line (IO0)
                --------------------------------------------------------
                when S_SEND_ADDR =>
                    if bit_cnt = 0 and shift_reg(31 downto 8) = x"000000" then
                        -- First entry: load address into shift register
                        shift_reg(31 downto 8) <= saved_addr;
                        bit_cnt <= 24;
                    elsif sck_falling = '1' then
                        io_out(0) <= shift_reg(31);
                        shift_reg <= shift_reg(30 downto 0) & '0';
                        if bit_cnt = 0 then
                            -- Address fully shifted out - branch by operation
                            if saved_op = "00" then
                                -- Read: insert dummy cycles before data
                                state   <= S_DUMMY;
                                bit_cnt <= DUMMY_CYCLES - 1;
                            elsif saved_op = "01" then
                                -- Page program: switch IO to quad output
                                state      <= S_QUAD_WRITE;
                                byte_cnt   <= saved_len;
                                need_data  <= '1';
                                tx_nib_cnt <= 0;
                                io_tri     <= "0000"; -- all 4 lines output
                            elsif saved_op = "10" then
                                -- Erase: command complete, deassert CS, gap, then poll
                                cs_n       <= '1';
                                sck_en     <= '0';
                                gap_cnt    <= CS_GAP_LEN - 1;
                                gap_return <= S_POLL_CMD;
                                state      <= S_CS_GAP;
                            end if;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                --  DUMMY CYCLES (for quad read, 8 clocks for 0x6B)
                --------------------------------------------------------
                when S_DUMMY =>
                    io_tri <= "1111";  -- all inputs during dummy
                    if sck_falling = '1' then
                        if bit_cnt = 0 then
                            state      <= S_QUAD_READ;
                            byte_cnt   <= saved_len;
                            nibble_cnt <= 0;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                --  QUAD READ - 4 bits sampled per rising SCK edge
                --  Two nibbles (2 clocks) = 1 byte
                --------------------------------------------------------
                when S_QUAD_READ =>
                    io_tri <= "1111";  -- all inputs
                    if sck_rising = '1' then
                        if nibble_cnt = 0 then
                            -- Capture high nibble from IO[3:0]
                            rx_byte(7 downto 4) <= spi_io_i;
                            nibble_cnt <= 1;
                        else
                            -- Capture low nibble - full byte ready
                            rx_byte(3 downto 0) <= spi_io_i;
                            rd_data  <= rx_byte(7 downto 4) & spi_io_i;
                            rd_valid <= '1';
                            nibble_cnt <= 0;
                            byte_cnt <= byte_cnt - 1;
                            if byte_cnt = 1 then
                                -- Last byte received, end transaction
                                cs_n   <= '1';
                                sck_en <= '0';
                                state  <= S_DONE;
                            end if;
                        end if;
                    end if;

                --------------------------------------------------------
                --  QUAD WRITE - 4 bits driven per falling SCK edge
                --  Two nibbles (2 clocks) = 1 byte
                --------------------------------------------------------
                when S_QUAD_WRITE =>
                    io_tri <= "0000";  -- all outputs
                    if need_data = '1' then
                        -- Request the next byte from the user
                        wr_ready <= '1';
                        if wr_valid = '1' then
                            tx_byte   <= wr_data;
                            need_data <= '0';
                            tx_nib_cnt <= 0;
                        end if;
                    elsif sck_falling = '1' then
                        if tx_nib_cnt = 0 then
                            -- Drive high nibble on IO[3:0]
                            io_out     <= tx_byte(7 downto 4);
                            tx_nib_cnt <= 1;
                        else
                            -- Drive low nibble on IO[3:0]
                            io_out     <= tx_byte(3 downto 0);
                            tx_nib_cnt <= 0;
                            byte_cnt   <= byte_cnt - 1;
                            if byte_cnt = 1 then
                                -- Last byte sent, end transaction, gap, then poll
                                cs_n       <= '1';
                                sck_en     <= '0';
                                gap_cnt    <= CS_GAP_LEN - 1;
                                gap_return <= S_POLL_CMD;
                                state      <= S_CS_GAP;
                            else
                                need_data <= '1';
                            end if;
                        end if;
                    end if;

                --------------------------------------------------------
                --  POLL STATUS REGISTER - send opcode 0x05
                --------------------------------------------------------
                when S_POLL_CMD =>
                    cs_n      <= '0';
                    sck_en    <= '1';
                    io_tri    <= "1110";
                    io_out(0) <= CMD_READ_STATUS_REG(7);  -- pre-drive MSB
                    shift_reg(31 downto 24) <= CMD_READ_STATUS_REG(6 downto 0) & '0';
                    bit_cnt   <= 7;
                    state     <= S_POLL_READ;

                --------------------------------------------------------
                --  POLL - shift out opcode on IO0, then switch to
                --  input mode and read 8 status bits on IO1
                --------------------------------------------------------
                when S_POLL_READ =>
                    if sck_falling = '1' and io_tri /= "1111" then
                        if bit_cnt > 0 then
                            io_out(0) <= shift_reg(31);
                            shift_reg <= shift_reg(30 downto 0) & '0';
                            bit_cnt   <= bit_cnt - 1;
                        else
                            io_out(0) <= shift_reg(31);
                            io_tri    <= "1111";
                            bit_cnt   <= 8;
                            state     <= S_POLL_WAIT;
                        end if;
                    end if;

                --------------------------------------------------------
                --  POLL - read 8 bits of status register on IO1 (SO)
                --------------------------------------------------------
                when S_POLL_WAIT =>
                    io_tri <= "1111";
                    if sck_rising = '1' then
                        status_byte <= status_byte(6 downto 0) & spi_io_i(1);
                        if bit_cnt = 0 then
                            cs_n   <= '1';
                            sck_en <= '0';
                            if spi_io_i(1) = '0' then
                                -- WIP = 0, flash is ready
                                state <= S_DONE;
                            else
                                -- Flash still busy, gap then poll again
                                gap_cnt    <= CS_GAP_LEN - 1;
                                gap_return <= S_POLL_CMD;
                                state      <= S_CS_GAP;
                            end if;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                --  ENABLE QUAD MODE - Step 1:
                --  Read Enhanced Volatile Config Register (0x65)
                --------------------------------------------------------
                when S_EQCFG_READ_CMD =>
                    cs_n      <= '0';
                    sck_en    <= '1';
                    io_tri    <= "1110";
                    io_out(0) <= CMD_READ_ENH_VOL_CFG_REG(7);  -- pre-drive MSB
                    shift_reg(31 downto 24) <= CMD_READ_ENH_VOL_CFG_REG(6 downto 0) & '0';
                    bit_cnt   <= 7;
                    state     <= S_EQCFG_READ_DATA;

                --------------------------------------------------------
                --  ENABLE QUAD MODE - Step 2:
                --  Shift out opcode, then read 8-bit config value
                --------------------------------------------------------
                when S_EQCFG_READ_DATA =>
                    if sck_falling = '1' and bit_cnt > 0 and io_tri /= "1111" then
                        io_out(0) <= shift_reg(31);
                        shift_reg <= shift_reg(30 downto 0) & '0';
                        bit_cnt   <= bit_cnt - 1;

                    elsif bit_cnt = 0 and sck_falling = '1' and io_tri /= "1111" then
                        io_out(0) <= shift_reg(31);
                        io_tri    <= "1111";
                        bit_cnt   <= 8;

                    elsif io_tri = "1111" and sck_rising = '1' then
                        cfg_reg_val <= cfg_reg_val(6 downto 0) & spi_io_i(1);
                        if bit_cnt = 0 then
                            -- Done reading config, deassert CS, gap, then WREN
                            cs_n       <= '1';
                            sck_en     <= '0';
                            gap_cnt    <= CS_GAP_LEN - 1;
                            gap_return <= S_EQCFG_WREN;
                            state      <= S_CS_GAP;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                --  ENABLE QUAD MODE - Step 3:
                --  Send Write Enable (0x06) before modifying config
                --------------------------------------------------------
                when S_EQCFG_WREN =>
                    cs_n      <= '0';
                    sck_en    <= '1';
                    io_tri    <= "1110";
                    io_out(0) <= CMD_WRITE_ENABLE(7);  -- pre-drive MSB
                    shift_reg(31 downto 24) <= CMD_WRITE_ENABLE(6 downto 0) & '0';
                    bit_cnt   <= 7;
                    state     <= S_EQCFG_WRITE_CMD;

                --------------------------------------------------------
                --  ENABLE QUAD MODE - Step 4:
                --  Shift out the Write Enable opcode
                --------------------------------------------------------
                when S_EQCFG_WRITE_CMD =>
                    if sck_falling = '1' then
                        io_out(0) <= shift_reg(31);
                        shift_reg <= shift_reg(30 downto 0) & '0';
                        if bit_cnt = 0 then
                            -- WREN sent, deassert CS, gap, then write config
                            cs_n       <= '1';
                            sck_en     <= '0';
                            gap_cnt    <= CS_GAP_LEN - 1;
                            gap_return <= S_EQCFG_WRITE_DATA;
                            state      <= S_CS_GAP;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                --  ENABLE QUAD MODE - Step 5:
                --  Write modified config register value (0x61 + data)
                --  Bit 7 cleared = quad I/O enabled
                --  Bit 6 set     = dual I/O disabled
                --------------------------------------------------------
                when S_EQCFG_WRITE_DATA =>
                    if cs_n = '1' then
                        cs_n      <= '0';
                        sck_en    <= '1';
                        io_tri    <= "1110";
                        io_out(0) <= CMD_WRITE_ENH_VOL_CFG_REG(7);  -- pre-drive MSB
                        shift_reg(31 downto 25) <= CMD_WRITE_ENH_VOL_CFG_REG(6 downto 0);  -- 7 bits, no padding
						shift_reg(24 downto 17) <= (cfg_reg_val and x"7F") or x"40";       -- 8 bits immediately after
						bit_cnt <= 15;  
                    elsif sck_falling = '1' then
                        io_out(0) <= shift_reg(31);
                        shift_reg <= shift_reg(30 downto 0) & '0';
                        if bit_cnt = 0 then
                            cs_n   <= '1';
                            sck_en <= '0';
                            state  <= S_DONE;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;
                    end if;

                --------------------------------------------------------
                --  DONE - deassert everything, return to idle
                --------------------------------------------------------
                when S_DONE =>
                    cs_n   <= '1';
                    sck_en <= '0';
                    io_tri <= "1111";
                    state  <= S_IDLE;

                when others =>
                    state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

    busy <= '0' when state = S_IDLE else '1';

end architecture rtl;
