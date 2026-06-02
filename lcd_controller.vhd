--------------------------------------------------------------------------------
-- FILE        : lcd_controller.vhd
-- PROJECT     : TERMO (Wordle) – EEL480 Digital Systems
-- BOARD       : Digilent Spartan-3AN Starter Kit (XC3S700AN-FGG484)
-- DESCRIPTION : HD44780-compatible 16x2 LCD controller in 4-bit interface mode.
--               Executes the full power-on initialisation sequence (3x 8-bit
--               wake-up nibbles followed by the 4-bit switch and configuration
--               commands), then accepts single-byte write requests from the
--               game controller.  A byte is either a COMMAND (RS=0) or a
--               DATA character (RS=1) and is sent in two 4-bit nibbles with
--               compliant E-pulse timing.
-- CLK         : 50 MHz system clock  (1 clock = 20 ns)
-- AUTHOR      : EEL480 Group
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity lcd_controller is
    port (
        clk        : in  std_logic;                    -- 50 MHz system clock
        rst        : in  std_logic;                    -- Active-high synchronous reset
        -- ---- User interface ------------------------------------------------
        lcd_char   : in  std_logic_vector(7 downto 0); -- Byte to send (cmd or char)
        lcd_rs_in  : in  std_logic;                    -- 0 = command, 1 = data char
        lcd_send   : in  std_logic;                    -- Pulse '1' for one cycle to send
        lcd_busy   : out std_logic;                    -- '1' while controller is busy
        -- ---- LCD hardware pins (4-bit mode) ---------------------------------
        lcd_rs     : out std_logic;                    -- Register Select
        lcd_rw     : out std_logic;                    -- Read/Write  (tied '0')
        lcd_e      : out std_logic;                    -- Enable pulse
        lcd_db     : out std_logic_vector(7 downto 4)  -- D7..D4 upper nibble only
    );
end entity lcd_controller;

architecture rtl of lcd_controller is

    ---------------------------------------------------------------------------
    -- Timing constants (50 MHz clock = 20 ns per cycle)
    ---------------------------------------------------------------------------
    constant C_PWR_DELAY  : natural := 750_000;  -- 15 ms  power-on wait
    constant C_INIT_4MS   : natural := 205_000;  -- ~4.1 ms after 1st wake-up
    constant C_INIT_100US : natural :=   5_000;  -- 100 µs  after 2nd/3rd wake-up
    constant C_CLR_DELAY  : natural := 100_000;  -- ~2 ms   for Clear / Return-Home
    constant C_CMD_DELAY  : natural :=   2_500;  -- 50 µs   for all other commands
    constant C_E_HIGH     : natural :=      25;  -- 500 ns  E pulse width (high)
    constant C_E_LOW      : natural :=      25;  -- 500 ns  E low time (inter-nibble)
    constant C_RS_SETUP   : natural :=       3;  -- 60 ns   RS/data setup before E↑

    ---------------------------------------------------------------------------
    -- State-machine type
    ---------------------------------------------------------------------------
    type lcd_state_t is (
        -- Power-on / initialisation states
        ST_PWR_DELAY,                                       -- Wait 15 ms
        -- Three 8-bit wake-up nibbles (only high nibble 0x3 is sent)
        ST_WU1_SETUP, ST_WU1_EHI, ST_WU1_ELO, ST_WU1_WAIT,
        ST_WU2_SETUP, ST_WU2_EHI, ST_WU2_ELO, ST_WU2_WAIT,
        ST_WU3_SETUP, ST_WU3_EHI, ST_WU3_ELO, ST_WU3_WAIT,
        -- Switch to 4-bit mode (nibble 0x2)
        ST_4B_SETUP,  ST_4B_EHI,  ST_4B_ELO,  ST_4B_WAIT,
        -- Init commands sent in 4-bit mode (indexed by init_idx)
        ST_IC_HI_SETUP, ST_IC_HI_EHI, ST_IC_HI_ELO,
        ST_IC_LO_SETUP, ST_IC_LO_EHI, ST_IC_LO_ELO,
        ST_IC_WAIT,
        -- Idle / user-command path
        ST_IDLE,
        ST_UC_HI_SETUP, ST_UC_HI_EHI, ST_UC_HI_ELO,
        ST_UC_LO_SETUP, ST_UC_LO_EHI, ST_UC_LO_ELO,
        ST_UC_WAIT
    );

    ---------------------------------------------------------------------------
    -- Initialisation command ROM (sent AFTER switching to 4-bit mode)
    -- 0x28 = Function Set : 4-bit bus, 2 lines, 5×8 font
    -- 0x0C = Display ON, cursor OFF, blink OFF
    -- 0x01 = Clear Display  (needs the longer C_CLR_DELAY wait)
    -- 0x06 = Entry Mode     : increment, no display shift
    ---------------------------------------------------------------------------
    type cmd_rom_t is array (0 to 3) of std_logic_vector(7 downto 0);
    constant INIT_CMDS : cmd_rom_t := (x"28", x"0C", x"01", x"06");

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------
    signal state        : lcd_state_t := ST_PWR_DELAY;
    signal timer        : natural range 0 to C_PWR_DELAY := 0;
    signal init_idx     : integer range 0 to 3 := 0;

    -- Latched byte for current operation (either init or user)
    signal byte_latch   : std_logic_vector(7 downto 0) := (others => '0');
    signal rs_latch     : std_logic := '0';

    -- Registered output pins
    signal lcd_e_r      : std_logic := '0';
    signal lcd_rs_r     : std_logic := '0';
    signal lcd_db_r     : std_logic_vector(7 downto 4) := (others => '0');
    signal lcd_busy_r   : std_logic := '1';

begin

    -- Assign registered values to ports
    lcd_e   <= lcd_e_r;
    lcd_rs  <= lcd_rs_r;
    lcd_rw  <= '0';          -- Always write
    lcd_db  <= lcd_db_r;
    lcd_busy <= lcd_busy_r;

    ---------------------------------------------------------------------------
    -- Main state machine
    ---------------------------------------------------------------------------
    p_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= ST_PWR_DELAY;
                timer      <= 0;
                init_idx   <= 0;
                lcd_e_r    <= '0';
                lcd_rs_r   <= '0';
                lcd_db_r   <= (others => '0');
                lcd_busy_r <= '1';
            else
                case state is

                    ----------------------------------------------------------------
                    -- POWER-ON DELAY (15 ms)
                    ----------------------------------------------------------------
                    when ST_PWR_DELAY =>
                        lcd_busy_r <= '1';
                        lcd_e_r    <= '0';
                        if timer = C_PWR_DELAY - 1 then
                            timer <= 0; state <= ST_WU1_SETUP;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- WAKE-UP NIBBLE #1 : send nibble 0x3 then wait 4.1 ms
                    ----------------------------------------------------------------
                    when ST_WU1_SETUP =>
                        lcd_rs_r <= '0'; lcd_db_r <= "0011";
                        if timer = C_RS_SETUP - 1 then
                            timer <= 0; state <= ST_WU1_EHI;
                        else timer <= timer + 1; end if;
                    when ST_WU1_EHI =>
                        lcd_e_r <= '1';
                        if timer = C_E_HIGH - 1 then
                            timer <= 0; lcd_e_r <= '0'; state <= ST_WU1_ELO;
                        else timer <= timer + 1; end if;
                    when ST_WU1_ELO =>
                        if timer = C_E_LOW - 1 then
                            timer <= 0; state <= ST_WU1_WAIT;
                        else timer <= timer + 1; end if;
                    when ST_WU1_WAIT =>
                        if timer = C_INIT_4MS - 1 then
                            timer <= 0; state <= ST_WU2_SETUP;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- WAKE-UP NIBBLE #2 : send nibble 0x3 then wait 100 µs
                    ----------------------------------------------------------------
                    when ST_WU2_SETUP =>
                        lcd_rs_r <= '0'; lcd_db_r <= "0011";
                        if timer = C_RS_SETUP - 1 then
                            timer <= 0; state <= ST_WU2_EHI;
                        else timer <= timer + 1; end if;
                    when ST_WU2_EHI =>
                        lcd_e_r <= '1';
                        if timer = C_E_HIGH - 1 then
                            timer <= 0; lcd_e_r <= '0'; state <= ST_WU2_ELO;
                        else timer <= timer + 1; end if;
                    when ST_WU2_ELO =>
                        if timer = C_E_LOW - 1 then
                            timer <= 0; state <= ST_WU2_WAIT;
                        else timer <= timer + 1; end if;
                    when ST_WU2_WAIT =>
                        if timer = C_INIT_100US - 1 then
                            timer <= 0; state <= ST_WU3_SETUP;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- WAKE-UP NIBBLE #3 : send nibble 0x3 then wait 100 µs
                    ----------------------------------------------------------------
                    when ST_WU3_SETUP =>
                        lcd_rs_r <= '0'; lcd_db_r <= "0011";
                        if timer = C_RS_SETUP - 1 then
                            timer <= 0; state <= ST_WU3_EHI;
                        else timer <= timer + 1; end if;
                    when ST_WU3_EHI =>
                        lcd_e_r <= '1';
                        if timer = C_E_HIGH - 1 then
                            timer <= 0; lcd_e_r <= '0'; state <= ST_WU3_ELO;
                        else timer <= timer + 1; end if;
                    when ST_WU3_ELO =>
                        if timer = C_E_LOW - 1 then
                            timer <= 0; state <= ST_WU3_WAIT;
                        else timer <= timer + 1; end if;
                    when ST_WU3_WAIT =>
                        if timer = C_INIT_100US - 1 then
                            timer <= 0; state <= ST_4B_SETUP;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- SWITCH TO 4-BIT MODE : send nibble 0x2 then wait 100 µs
                    ----------------------------------------------------------------
                    when ST_4B_SETUP =>
                        lcd_rs_r <= '0'; lcd_db_r <= "0010";
                        if timer = C_RS_SETUP - 1 then
                            timer <= 0; state <= ST_4B_EHI;
                        else timer <= timer + 1; end if;
                    when ST_4B_EHI =>
                        lcd_e_r <= '1';
                        if timer = C_E_HIGH - 1 then
                            timer <= 0; lcd_e_r <= '0'; state <= ST_4B_ELO;
                        else timer <= timer + 1; end if;
                    when ST_4B_ELO =>
                        if timer = C_E_LOW - 1 then
                            timer <= 0; state <= ST_4B_WAIT;
                        else timer <= timer + 1; end if;
                    when ST_4B_WAIT =>
                        if timer = C_INIT_100US - 1 then
                            timer      <= 0;
                            init_idx   <= 0;
                            byte_latch <= INIT_CMDS(0);
                            rs_latch   <= '0';
                            state      <= ST_IC_HI_SETUP;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- INIT COMMAND : high nibble send
                    ----------------------------------------------------------------
                    when ST_IC_HI_SETUP =>
                        lcd_rs_r <= rs_latch;
                        lcd_db_r <= byte_latch(7 downto 4);
                        if timer = C_RS_SETUP - 1 then
                            timer <= 0; state <= ST_IC_HI_EHI;
                        else timer <= timer + 1; end if;
                    when ST_IC_HI_EHI =>
                        lcd_e_r <= '1';
                        if timer = C_E_HIGH - 1 then
                            timer <= 0; lcd_e_r <= '0'; state <= ST_IC_HI_ELO;
                        else timer <= timer + 1; end if;
                    when ST_IC_HI_ELO =>
                        if timer = C_E_LOW - 1 then
                            timer <= 0; state <= ST_IC_LO_SETUP;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- INIT COMMAND : low nibble send
                    ----------------------------------------------------------------
                    when ST_IC_LO_SETUP =>
                        lcd_rs_r <= rs_latch;
                        lcd_db_r <= byte_latch(3 downto 0);
                        if timer = C_RS_SETUP - 1 then
                            timer <= 0; state <= ST_IC_LO_EHI;
                        else timer <= timer + 1; end if;
                    when ST_IC_LO_EHI =>
                        lcd_e_r <= '1';
                        if timer = C_E_HIGH - 1 then
                            timer <= 0; lcd_e_r <= '0'; state <= ST_IC_LO_ELO;
                        else timer <= timer + 1; end if;
                    when ST_IC_LO_ELO =>
                        if timer = C_E_LOW - 1 then
                            timer <= 0; state <= ST_IC_WAIT;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- INIT COMMAND : settle time then advance to next init command
                    ----------------------------------------------------------------
                    when ST_IC_WAIT =>
                        -- Clear Display (0x01) needs the long wait
                        if byte_latch = x"01" then
                            if timer = C_CLR_DELAY - 1 then
                                timer <= 0;
                                if init_idx = 3 then
                                    state <= ST_IDLE;
                                else
                                    init_idx   <= init_idx + 1;
                                    byte_latch <= INIT_CMDS(init_idx + 1);
                                    state      <= ST_IC_HI_SETUP;
                                end if;
                            else timer <= timer + 1; end if;
                        else
                            if timer = C_CMD_DELAY - 1 then
                                timer <= 0;
                                if init_idx = 3 then
                                    state <= ST_IDLE;
                                else
                                    init_idx   <= init_idx + 1;
                                    byte_latch <= INIT_CMDS(init_idx + 1);
                                    state      <= ST_IC_HI_SETUP;
                                end if;
                            else timer <= timer + 1; end if;
                        end if;

                    ----------------------------------------------------------------
                    -- IDLE : ready to accept a user byte
                    ----------------------------------------------------------------
                    when ST_IDLE =>
                        lcd_busy_r <= '0';
                        if lcd_send = '1' then
                            lcd_busy_r <= '1';
                            byte_latch <= lcd_char;
                            rs_latch   <= lcd_rs_in;
                            state      <= ST_UC_HI_SETUP;
                        end if;

                    ----------------------------------------------------------------
                    -- USER COMMAND : high nibble send
                    ----------------------------------------------------------------
                    when ST_UC_HI_SETUP =>
                        lcd_rs_r <= rs_latch;
                        lcd_db_r <= byte_latch(7 downto 4);
                        if timer = C_RS_SETUP - 1 then
                            timer <= 0; state <= ST_UC_HI_EHI;
                        else timer <= timer + 1; end if;
                    when ST_UC_HI_EHI =>
                        lcd_e_r <= '1';
                        if timer = C_E_HIGH - 1 then
                            timer <= 0; lcd_e_r <= '0'; state <= ST_UC_HI_ELO;
                        else timer <= timer + 1; end if;
                    when ST_UC_HI_ELO =>
                        if timer = C_E_LOW - 1 then
                            timer <= 0; state <= ST_UC_LO_SETUP;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- USER COMMAND : low nibble send
                    ----------------------------------------------------------------
                    when ST_UC_LO_SETUP =>
                        lcd_rs_r <= rs_latch;
                        lcd_db_r <= byte_latch(3 downto 0);
                        if timer = C_RS_SETUP - 1 then
                            timer <= 0; state <= ST_UC_LO_EHI;
                        else timer <= timer + 1; end if;
                    when ST_UC_LO_EHI =>
                        lcd_e_r <= '1';
                        if timer = C_E_HIGH - 1 then
                            timer <= 0; lcd_e_r <= '0'; state <= ST_UC_LO_ELO;
                        else timer <= timer + 1; end if;
                    when ST_UC_LO_ELO =>
                        if timer = C_E_LOW - 1 then
                            timer <= 0; state <= ST_UC_WAIT;
                        else timer <= timer + 1; end if;

                    ----------------------------------------------------------------
                    -- USER COMMAND : settle time (Clear/Home need longer wait)
                    ----------------------------------------------------------------
                    when ST_UC_WAIT =>
                        if byte_latch = x"01" or byte_latch = x"02" then
                            if timer = C_CLR_DELAY - 1 then
                                timer <= 0; state <= ST_IDLE;
                            else timer <= timer + 1; end if;
                        else
                            if timer = C_CMD_DELAY - 1 then
                                timer <= 0; state <= ST_IDLE;
                            else timer <= timer + 1; end if;
                        end if;

                    when others =>
                        state <= ST_IDLE;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
