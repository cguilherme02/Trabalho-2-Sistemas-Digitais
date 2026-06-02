--------------------------------------------------------------------------------
-- FILE        : game_controller.vhd
-- PROJECT     : TERMO (Wordle) – EEL480 Digital Systems
-- BOARD       : Digilent Spartan-3AN Starter Kit (XC3S700AN-FGG484)
-- DESCRIPTION : Top-level game FSM.  Orchestrates the full TERMO game loop:
--
--   1. Player 1 enters a 5-letter secret word (displayed as '*').
--   2. Player 2 makes up to 6 guesses of 5 letters each.
--   3. After each guess the comparator result is displayed on LCD line 2:
--        'O'  → CORRECT   (right letter, right position)
--        '+'  → EXISTS    (right letter, wrong position)
--        '-'  → WRONG     (letter not in word)
--   4. Game ends with "YOU WIN!" or "GAME OVER!" message.
--
--   LCD line layout during gameplay
--   ─────────────────────────────────────────────────────
--   Line 1 (0x80): active word / guess  [16 chars]
--   Line 2 (0xC0): status / feedback    [16 chars]
--
--   SHARED LCD-WRITE HELPER
--   The states S_WR_CMD … S_WR_CHR_WL implement a reusable
--   "write one string to LCD" sub-machine.  Any game state that
--   needs to update the display sets the signals:
--       wr_cmd      – cursor-position command (sent as RS=0)
--       wr_len      – number of data characters (0 = command only)
--       wr_buf(0..15) – characters to write (RS=1)
--       ret_state   – state to enter once the write is complete
--   …and then transitions to S_WR_CMD.
--
-- CLK         : 50 MHz system clock
-- AUTHOR      : EEL480 Group
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity game_controller is
    port (
        clk          : in  std_logic;                    -- 50 MHz system clock
        rst          : in  std_logic;                    -- Active-high sync reset
        -- ---- Keyboard interface (from ps2_keyboard) -------------------------
        ascii_in     : in  std_logic_vector(7 downto 0); -- ASCII of last key
        key_valid    : in  std_logic;                    -- '1' for one clock on key
        -- ---- LCD interface (to lcd_controller) -----------------------------
        lcd_char_out : out std_logic_vector(7 downto 0); -- Byte to send to LCD
        lcd_rs_out   : out std_logic;                    -- 0=cmd / 1=data
        lcd_send_out : out std_logic;                    -- One-clock send pulse
        lcd_busy     : in  std_logic;                    -- '1' while LCD is busy
        -- ---- Word interface (to word_comparator) ---------------------------
        secret_out   : out std_logic_vector(39 downto 0); -- Packed secret word
        guess_out    : out std_logic_vector(39 downto 0); -- Packed current guess
        fb_in        : in  std_logic_vector(9 downto 0);  -- Comparator feedback
        win_in       : in  std_logic;                     -- All-correct flag
        -- ---- Status LEDs ---------------------------------------------------
        led_p1_done  : out std_logic;  -- Lit after P1 enters word
        led_win      : out std_logic;  -- Lit on Player-2 win
        led_lose     : out std_logic   -- Lit when max attempts exhausted
    );
end entity game_controller;

architecture rtl of game_controller is

    ---------------------------------------------------------------------------
    -- ASCII constants
    ---------------------------------------------------------------------------
    constant ASCII_CR   : std_logic_vector(7 downto 0) := x"0D"; -- Enter
    constant ASCII_BS   : std_logic_vector(7 downto 0) := x"08"; -- Backspace
    constant ASCII_SPC  : std_logic_vector(7 downto 0) := x"20"; -- Space
    constant ASCII_STAR : std_logic_vector(7 downto 0) := x"2A"; -- *
    constant ASCII_UNDR : std_logic_vector(7 downto 0) := x"5F"; -- _

    -- Feedback display characters
    constant FB_CORRECT : std_logic_vector(7 downto 0) := x"4F"; -- 'O'
    constant FB_EXISTS  : std_logic_vector(7 downto 0) := x"2B"; -- '+'
    constant FB_WRONG   : std_logic_vector(7 downto 0) := x"2D"; -- '-'

    ---------------------------------------------------------------------------
    -- Type aliases
    ---------------------------------------------------------------------------
    type word5_t  is array (0 to 4)  of std_logic_vector(7 downto 0);
    type str16_t  is array (0 to 15) of std_logic_vector(7 downto 0);

    ---------------------------------------------------------------------------
    -- Full game-state enumeration
    ---------------------------------------------------------------------------
    type state_t is (
        -- Initialisation
        S_INIT,
        -- Player-1 setup states (each lasts exactly one clock; see comments)
        S_P1_WR_L2,        -- Setup: write P1 prompt to LCD line 2
        S_P1_WR_L1,        -- Setup: write blank input area to line 1
        S_P1_INPUT,        -- Wait for P1 key-presses
        S_P1_ECHO,         -- Setup: echo '*' for the letter just entered
        -- Player-2 setup states
        S_P2_CLR,          -- Setup: clear display between attempts
        S_P2_WR_L1,        -- Setup: write guess header to line 1
        S_P2_WR_L2,        -- Setup: clear line 2
        S_P2_INPUT,        -- Wait for P2 key-presses
        S_P2_ECHO,         -- Setup: echo the letter just entered
        -- Comparison and result
        S_COMPARE,         -- Single-clock compare + feedback setup
        S_WR_FEEDBACK,     -- Setup: write feedback to line 2
        S_CHECK_RESULT,    -- Single-clock win/lose decision
        S_WAIT_CONTINUE,   -- Wait for Enter before next attempt
        -- End-game states
        S_WIN_WR_L1,       -- Setup: write "*** YOU WIN! ***" to line 1
        S_WIN_WR_L2,       -- Setup: write attempt count to line 2
        S_LOSE_WR_L1,      -- Setup: write "GAME OVER!!!    " to line 1
        S_LOSE_WR_L2,      -- Setup: write "WORD: ABCDE     " to line 2
        S_GAME_OVER,       -- Terminal state; wait for reset
        -- ---- LCD write helper sub-states ------------------------------------
        -- Entry: set wr_cmd, wr_len, wr_buf(0..wr_len-1), ret_state
        -- then transition to S_WR_CMD.
        S_WR_CMD,          -- Send cursor-position command
        S_WR_CMD_WH,       -- Wait for lcd_busy to go HIGH
        S_WR_CMD_WL,       -- Wait for lcd_busy to go LOW
        S_WR_CHR,          -- Send one data character
        S_WR_CHR_WH,       -- Wait for lcd_busy HIGH
        S_WR_CHR_WL        -- Wait for lcd_busy LOW; advance wr_pos or finish
    );

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------
    signal state      : state_t := S_INIT;
    signal ret_state  : state_t := S_GAME_OVER; -- Return destination after write

    -- Game data
    signal secret     : word5_t := (others => ASCII_SPC);
    signal guess      : word5_t := (others => ASCII_SPC);
    signal input_pos  : integer range 0 to 5 := 0;   -- Current letter position (0–4)
    signal attempt    : integer range 0 to 6 := 0;   -- Number of completed guesses

    -- LCD write helper registers
    signal wr_buf     : str16_t := (others => ASCII_SPC);
    signal wr_len     : integer range 0 to 16 := 0;  -- Data chars after cursor cmd
    signal wr_pos     : integer range 0 to 15 := 0;  -- Index into wr_buf
    signal wr_cmd     : std_logic_vector(7 downto 0) := x"80"; -- Cursor cmd

    -- LCD output registers
    signal lcd_char_r : std_logic_vector(7 downto 0) := (others => '0');
    signal lcd_rs_r   : std_logic := '0';
    signal lcd_send_r : std_logic := '0';

    -- LED registers
    signal led_p1_r   : std_logic := '0';
    signal led_win_r  : std_logic := '0';
    signal led_lose_r : std_logic := '0';

    ---------------------------------------------------------------------------
    -- Helper: convert integer 0..9 to ASCII digit '0'..'9'
    ---------------------------------------------------------------------------
    function to_ascii_digit(n : integer range 0 to 9)
        return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(n + 48, 8));
    end function;

    ---------------------------------------------------------------------------
    -- Helper: convert 2-bit feedback code to display character
    ---------------------------------------------------------------------------
    function fb_char(fb : std_logic_vector(1 downto 0))
        return std_logic_vector is
    begin
        case fb is
            when "10"   => return FB_CORRECT; -- 'O'
            when "01"   => return FB_EXISTS;  -- '+'
            when others => return FB_WRONG;   -- '-'
        end case;
    end function;

begin

    ---------------------------------------------------------------------------
    -- Output port assignments
    ---------------------------------------------------------------------------
    lcd_char_out <= lcd_char_r;
    lcd_rs_out   <= lcd_rs_r;
    lcd_send_out <= lcd_send_r;
    led_p1_done  <= led_p1_r;
    led_win      <= led_win_r;
    led_lose     <= led_lose_r;

    -- Pack words for the comparator (letter 0 in bits 7..0)
    secret_out <= secret(4) & secret(3) & secret(2) & secret(1) & secret(0);
    guess_out  <= guess(4)  & guess(3)  & guess(2)  & guess(1)  & guess(0);

    ---------------------------------------------------------------------------
    -- Main clocked process
    ---------------------------------------------------------------------------
    p_game : process(clk)
    begin
        if rising_edge(clk) then
            ---------------------------------------------------------------------------
            -- Synchronous reset: return to initial state, clear all game data
            ---------------------------------------------------------------------------
            if rst = '1' then
                state      <= S_INIT;
                input_pos  <= 0;
                attempt    <= 0;
                led_p1_r   <= '0';
                led_win_r  <= '0';
                led_lose_r <= '0';
                lcd_send_r <= '0';
                lcd_char_r <= (others => '0');
                lcd_rs_r   <= '0';
                secret     <= (others => ASCII_SPC);
                guess      <= (others => ASCII_SPC);
                wr_len     <= 0;
                wr_pos     <= 0;
            else
                -- Default: do not pulse lcd_send
                lcd_send_r <= '0';

                case state is

                    ----------------------------------------------------------------
                    -- S_INIT : wait for LCD controller to finish initialisation
                    ----------------------------------------------------------------
                    when S_INIT =>
                        if lcd_busy = '0' then
                            -- LCD ready; write P1 prompt to line 2
                            -- "P1: ENTER WORD  "
                            wr_cmd     <= x"C0"; -- Line 2, position 0
                            wr_len     <= 16;
                            wr_buf(0)  <= x"50"; -- P
                            wr_buf(1)  <= x"31"; -- 1
                            wr_buf(2)  <= x"3A"; -- :
                            wr_buf(3)  <= ASCII_SPC;
                            wr_buf(4)  <= x"45"; -- E
                            wr_buf(5)  <= x"4E"; -- N
                            wr_buf(6)  <= x"54"; -- T
                            wr_buf(7)  <= x"45"; -- E
                            wr_buf(8)  <= x"52"; -- R
                            wr_buf(9)  <= ASCII_SPC;
                            wr_buf(10) <= x"57"; -- W
                            wr_buf(11) <= x"4F"; -- O
                            wr_buf(12) <= x"52"; -- R
                            wr_buf(13) <= x"44"; -- D
                            wr_buf(14) <= ASCII_SPC;
                            wr_buf(15) <= ASCII_SPC;
                            ret_state  <= S_P1_WR_L1;
                            state      <= S_WR_CMD;
                        end if;

                    ----------------------------------------------------------------
                    -- S_P1_WR_L2 is merged into S_INIT above.
                    -- After that write, ret_state brings us here:
                    ----------------------------------------------------------------

                    ----------------------------------------------------------------
                    -- S_P1_WR_L1 : write 5 underscores + spaces to line 1
                    --              (represents 5 empty letter slots)
                    ----------------------------------------------------------------
                    when S_P1_WR_L1 =>
                        wr_cmd     <= x"80"; -- Line 1, position 0
                        wr_len     <= 16;
                        wr_buf(0)  <= ASCII_UNDR; -- _ placeholder for letter 0
                        wr_buf(1)  <= ASCII_UNDR;
                        wr_buf(2)  <= ASCII_UNDR;
                        wr_buf(3)  <= ASCII_UNDR;
                        wr_buf(4)  <= ASCII_UNDR; -- _ placeholder for letter 4
                        wr_buf(5)  <= ASCII_SPC;
                        wr_buf(6)  <= ASCII_SPC;
                        wr_buf(7)  <= ASCII_SPC;
                        wr_buf(8)  <= ASCII_SPC;
                        wr_buf(9)  <= ASCII_SPC;
                        wr_buf(10) <= ASCII_SPC;
                        wr_buf(11) <= ASCII_SPC;
                        wr_buf(12) <= ASCII_SPC;
                        wr_buf(13) <= ASCII_SPC;
                        wr_buf(14) <= ASCII_SPC;
                        wr_buf(15) <= ASCII_SPC;
                        input_pos  <= 0;
                        secret     <= (others => ASCII_SPC);
                        ret_state  <= S_P1_INPUT;
                        state      <= S_WR_CMD;

                    ----------------------------------------------------------------
                    -- S_P1_INPUT : wait for P1 to type 5 letters then press Enter
                    ----------------------------------------------------------------
                    when S_P1_INPUT =>
                        if key_valid = '1' then
                            if ascii_in = ASCII_CR then
                                -- Enter pressed
                                if input_pos = 5 then
                                    -- Word is complete; hand over to Player 2
                                    led_p1_r  <= '1';
                                    -- Set up "clear display" write, go to P2 setup
                                    wr_cmd    <= x"01"; -- Clear Display command
                                    wr_len    <= 0;     -- No data characters
                                    ret_state <= S_P2_WR_L1;
                                    state     <= S_WR_CMD;
                                end if;
                                -- If fewer than 5 letters: ignore Enter

                            elsif ascii_in = ASCII_BS then
                                -- Backspace: erase last letter if any
                                if input_pos > 0 then
                                    secret(input_pos - 1) <= ASCII_SPC;
                                    -- Position cursor back and write '_'
                                    wr_cmd    <= std_logic_vector(
                                                  unsigned(x"80") +
                                                  to_unsigned(input_pos - 1, 8));
                                    wr_len    <= 1;
                                    wr_buf(0) <= ASCII_UNDR;
                                    ret_state <= S_P1_INPUT;
                                    input_pos <= input_pos - 1;
                                    state     <= S_WR_CMD;
                                end if;

                            elsif input_pos < 5 then
                                -- Accept only uppercase letters A–Z
                                if ascii_in >= x"41" and ascii_in <= x"5A" then
                                    secret(input_pos) <= ascii_in;
                                    -- Echo '*' at current position
                                    wr_cmd    <= std_logic_vector(
                                                  unsigned(x"80") +
                                                  to_unsigned(input_pos, 8));
                                    wr_len    <= 1;
                                    wr_buf(0) <= ASCII_STAR; -- Hide letter as *
                                    ret_state <= S_P1_INPUT;
                                    input_pos <= input_pos + 1;
                                    state     <= S_WR_CMD;
                                end if;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- S_P2_CLR : called between guesses (merged with S_P1_INPUT
                    --             end-path above for first entry).
                    --            Clear display, then build P2 header on line 1.
                    ----------------------------------------------------------------
                    when S_P2_CLR =>
                        wr_cmd    <= x"01"; -- Clear Display
                        wr_len    <= 0;
                        ret_state <= S_P2_WR_L1;
                        state     <= S_WR_CMD;

                    ----------------------------------------------------------------
                    -- S_P2_WR_L1 : "GUESS N: _____  " on line 1
                    ----------------------------------------------------------------
                    when S_P2_WR_L1 =>
                        wr_cmd     <= x"80"; -- Line 1, position 0
                        wr_len     <= 16;
                        wr_buf(0)  <= x"47"; -- G
                        wr_buf(1)  <= x"55"; -- U
                        wr_buf(2)  <= x"45"; -- E
                        wr_buf(3)  <= x"53"; -- S
                        wr_buf(4)  <= x"53"; -- S
                        wr_buf(5)  <= ASCII_SPC;
                        wr_buf(6)  <= to_ascii_digit(attempt + 1); -- 1..6
                        wr_buf(7)  <= x"3A"; -- :
                        wr_buf(8)  <= ASCII_SPC;
                        wr_buf(9)  <= ASCII_UNDR; -- _ letter slot 0
                        wr_buf(10) <= ASCII_UNDR;
                        wr_buf(11) <= ASCII_UNDR;
                        wr_buf(12) <= ASCII_UNDR;
                        wr_buf(13) <= ASCII_UNDR; -- _ letter slot 4
                        wr_buf(14) <= ASCII_SPC;
                        wr_buf(15) <= ASCII_SPC;
                        -- Reset guess buffer and input cursor
                        guess      <= (others => ASCII_SPC);
                        input_pos  <= 0;
                        ret_state  <= S_P2_WR_L2;
                        state      <= S_WR_CMD;

                    ----------------------------------------------------------------
                    -- S_P2_WR_L2 : blank line 2 (clear previous feedback)
                    ----------------------------------------------------------------
                    when S_P2_WR_L2 =>
                        wr_cmd     <= x"C0"; -- Line 2, position 0
                        wr_len     <= 16;
                        wr_buf(0)  <= ASCII_SPC;
                        wr_buf(1)  <= ASCII_SPC;
                        wr_buf(2)  <= ASCII_SPC;
                        wr_buf(3)  <= ASCII_SPC;
                        wr_buf(4)  <= ASCII_SPC;
                        wr_buf(5)  <= ASCII_SPC;
                        wr_buf(6)  <= ASCII_SPC;
                        wr_buf(7)  <= ASCII_SPC;
                        wr_buf(8)  <= ASCII_SPC;
                        wr_buf(9)  <= ASCII_SPC;
                        wr_buf(10) <= ASCII_SPC;
                        wr_buf(11) <= ASCII_SPC;
                        wr_buf(12) <= ASCII_SPC;
                        wr_buf(13) <= ASCII_SPC;
                        wr_buf(14) <= ASCII_SPC;
                        wr_buf(15) <= ASCII_SPC;
                        ret_state  <= S_P2_INPUT;
                        state      <= S_WR_CMD;

                    ----------------------------------------------------------------
                    -- S_P2_INPUT : collect 5 letters from Player 2
                    -- Cursor starts at line 1, position 9 (after "GUESS N: ")
                    ----------------------------------------------------------------
                    when S_P2_INPUT =>
                        if key_valid = '1' then
                            if ascii_in = ASCII_CR then
                                if input_pos = 5 then
                                    -- Guess complete; run comparison
                                    state <= S_COMPARE;
                                end if;

                            elsif ascii_in = ASCII_BS then
                                if input_pos > 0 then
                                    guess(input_pos - 1) <= ASCII_SPC;
                                    -- Restore '_' at the erased position (offset 9)
                                    wr_cmd    <= std_logic_vector(
                                                  unsigned(x"89") +
                                                  to_unsigned(input_pos - 1, 8));
                                    wr_len    <= 1;
                                    wr_buf(0) <= ASCII_UNDR;
                                    ret_state <= S_P2_INPUT;
                                    input_pos <= input_pos - 1;
                                    state     <= S_WR_CMD;
                                end if;

                            elsif input_pos < 5 then
                                if ascii_in >= x"41" and ascii_in <= x"5A" then
                                    guess(input_pos) <= ascii_in;
                                    -- Echo the actual letter (position offset 9)
                                    wr_cmd    <= std_logic_vector(
                                                  unsigned(x"89") +
                                                  to_unsigned(input_pos, 8));
                                    wr_len    <= 1;
                                    wr_buf(0) <= ascii_in;
                                    ret_state <= S_P2_INPUT;
                                    input_pos <= input_pos + 1;
                                    state     <= S_WR_CMD;
                                end if;
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- S_COMPARE : one-clock state; the comparator is purely
                    --             combinational so fb_in / win_in are already valid.
                    --             Increment attempt counter and prepare feedback.
                    ----------------------------------------------------------------
                    when S_COMPARE =>
                        attempt    <= attempt + 1;
                        -- Build feedback string  (5 symbols + 11 spaces)
                        wr_cmd     <= x"C0"; -- Line 2, position 0
                        wr_len     <= 16;
                        wr_buf(0)  <= fb_char(fb_in(1 downto 0));  -- letter 0
                        wr_buf(1)  <= fb_char(fb_in(3 downto 2));  -- letter 1
                        wr_buf(2)  <= fb_char(fb_in(5 downto 4));  -- letter 2
                        wr_buf(3)  <= fb_char(fb_in(7 downto 6));  -- letter 3
                        wr_buf(4)  <= fb_char(fb_in(9 downto 8));  -- letter 4
                        wr_buf(5)  <= ASCII_SPC;
                        wr_buf(6)  <= ASCII_SPC;
                        wr_buf(7)  <= ASCII_SPC;
                        wr_buf(8)  <= ASCII_SPC;
                        wr_buf(9)  <= ASCII_SPC;
                        wr_buf(10) <= ASCII_SPC;
                        wr_buf(11) <= ASCII_SPC;
                        wr_buf(12) <= ASCII_SPC;
                        wr_buf(13) <= ASCII_SPC;
                        wr_buf(14) <= ASCII_SPC;
                        wr_buf(15) <= ASCII_SPC;
                        ret_state  <= S_CHECK_RESULT;
                        state      <= S_WR_CMD;

                    ----------------------------------------------------------------
                    -- S_WR_FEEDBACK : handled by the write helper above
                    --                 (ret_state=S_CHECK_RESULT set in S_COMPARE)
                    ----------------------------------------------------------------

                    ----------------------------------------------------------------
                    -- S_CHECK_RESULT : win/lose check (one clock after feedback write)
                    ----------------------------------------------------------------
                    when S_CHECK_RESULT =>
                        if win_in = '1' then
                            led_win_r <= '1';
                            state     <= S_WIN_WR_L1;
                        elsif attempt = 6 then
                            led_lose_r <= '1';
                            state      <= S_LOSE_WR_L1;
                        else
                            -- Not won and attempts remain; wait for Enter
                            state <= S_WAIT_CONTINUE;
                        end if;

                    ----------------------------------------------------------------
                    -- S_WAIT_CONTINUE : player views the feedback, presses Enter
                    ----------------------------------------------------------------
                    when S_WAIT_CONTINUE =>
                        if key_valid = '1' and ascii_in = ASCII_CR then
                            state <= S_P2_CLR;
                        end if;

                    ----------------------------------------------------------------
                    -- WIN DISPLAY
                    -- Line 1: "*** YOU WIN! ***"
                    -- Line 2: "IN N ATTEMPTS   "
                    ----------------------------------------------------------------
                    when S_WIN_WR_L1 =>
                        wr_cmd     <= x"80"; -- Overwrite line 1
                        wr_len     <= 16;
                        wr_buf(0)  <= ASCII_STAR;
                        wr_buf(1)  <= ASCII_STAR;
                        wr_buf(2)  <= ASCII_STAR;
                        wr_buf(3)  <= ASCII_SPC;
                        wr_buf(4)  <= x"59"; -- Y
                        wr_buf(5)  <= x"4F"; -- O
                        wr_buf(6)  <= x"55"; -- U
                        wr_buf(7)  <= ASCII_SPC;
                        wr_buf(8)  <= x"57"; -- W
                        wr_buf(9)  <= x"49"; -- I
                        wr_buf(10) <= x"4E"; -- N
                        wr_buf(11) <= x"21"; -- !
                        wr_buf(12) <= ASCII_SPC;
                        wr_buf(13) <= ASCII_STAR;
                        wr_buf(14) <= ASCII_STAR;
                        wr_buf(15) <= ASCII_STAR;
                        ret_state  <= S_WIN_WR_L2;
                        state      <= S_WR_CMD;

                    when S_WIN_WR_L2 =>
                        wr_cmd     <= x"C0"; -- Overwrite line 2
                        wr_len     <= 16;
                        wr_buf(0)  <= x"49"; -- I
                        wr_buf(1)  <= x"4E"; -- N
                        wr_buf(2)  <= ASCII_SPC;
                        wr_buf(3)  <= to_ascii_digit(attempt); -- attempts used
                        wr_buf(4)  <= ASCII_SPC;
                        wr_buf(5)  <= x"41"; -- A
                        wr_buf(6)  <= x"54"; -- T
                        wr_buf(7)  <= x"54"; -- T
                        wr_buf(8)  <= x"45"; -- E
                        wr_buf(9)  <= x"4D"; -- M
                        wr_buf(10) <= x"50"; -- P
                        wr_buf(11) <= x"54"; -- T
                        wr_buf(12) <= x"53"; -- S
                        wr_buf(13) <= ASCII_SPC;
                        wr_buf(14) <= ASCII_SPC;
                        wr_buf(15) <= ASCII_SPC;
                        ret_state  <= S_GAME_OVER;
                        state      <= S_WR_CMD;

                    ----------------------------------------------------------------
                    -- LOSE DISPLAY
                    -- Line 1: "GAME OVER!!!    "
                    -- Line 2: "WORD: ABCDE     "
                    ----------------------------------------------------------------
                    when S_LOSE_WR_L1 =>
                        wr_cmd     <= x"80";
                        wr_len     <= 16;
                        wr_buf(0)  <= x"47"; -- G
                        wr_buf(1)  <= x"41"; -- A
                        wr_buf(2)  <= x"4D"; -- M
                        wr_buf(3)  <= x"45"; -- E
                        wr_buf(4)  <= ASCII_SPC;
                        wr_buf(5)  <= x"4F"; -- O
                        wr_buf(6)  <= x"56"; -- V
                        wr_buf(7)  <= x"45"; -- E
                        wr_buf(8)  <= x"52"; -- R
                        wr_buf(9)  <= x"21"; -- !
                        wr_buf(10) <= x"21"; -- !
                        wr_buf(11) <= x"21"; -- !
                        wr_buf(12) <= ASCII_SPC;
                        wr_buf(13) <= ASCII_SPC;
                        wr_buf(14) <= ASCII_SPC;
                        wr_buf(15) <= ASCII_SPC;
                        ret_state  <= S_LOSE_WR_L2;
                        state      <= S_WR_CMD;

                    when S_LOSE_WR_L2 =>
                        -- Reveal the secret word on line 2
                        wr_cmd     <= x"C0";
                        wr_len     <= 16;
                        wr_buf(0)  <= x"57"; -- W
                        wr_buf(1)  <= x"4F"; -- O
                        wr_buf(2)  <= x"52"; -- R
                        wr_buf(3)  <= x"44"; -- D
                        wr_buf(4)  <= x"3A"; -- :
                        wr_buf(5)  <= ASCII_SPC;
                        wr_buf(6)  <= secret(0); -- Actual letters
                        wr_buf(7)  <= secret(1);
                        wr_buf(8)  <= secret(2);
                        wr_buf(9)  <= secret(3);
                        wr_buf(10) <= secret(4);
                        wr_buf(11) <= ASCII_SPC;
                        wr_buf(12) <= ASCII_SPC;
                        wr_buf(13) <= ASCII_SPC;
                        wr_buf(14) <= ASCII_SPC;
                        wr_buf(15) <= ASCII_SPC;
                        ret_state  <= S_GAME_OVER;
                        state      <= S_WR_CMD;

                    ----------------------------------------------------------------
                    -- S_GAME_OVER : terminal state; only RST can restart
                    ----------------------------------------------------------------
                    when S_GAME_OVER =>
                        null; -- Intentionally empty; wait for external reset

                    ================================================================
                    -- LCD WRITE HELPER SUB-MACHINE
                    -- Handles one command + wr_len data characters.
                    --
                    -- Send pattern per byte:
                    --   1. Assert lcd_send_r for ONE clock (→ LCD latches byte)
                    --   2. Wait for lcd_busy to go HIGH (LCD started operation)
                    --   3. Wait for lcd_busy to go LOW  (LCD finished operation)
                    -- Then advance to the next character or return to ret_state.
                    ================================================================

                    ----------------------------------------------------------------
                    -- Step 1a : Send the cursor-position command
                    ----------------------------------------------------------------
                    when S_WR_CMD =>
                        if lcd_busy = '0' then
                            lcd_char_r <= wr_cmd; -- Cursor command
                            lcd_rs_r   <= '0';    -- RS=0 for commands
                            lcd_send_r <= '1';    -- One-clock send pulse
                            wr_pos     <= 0;      -- Reset data index
                            state      <= S_WR_CMD_WH;
                        end if;

                    -- Step 1b : Wait for busy HIGH (LCD started)
                    when S_WR_CMD_WH =>
                        lcd_send_r <= '0';
                        if lcd_busy = '1' then
                            state <= S_WR_CMD_WL;
                        end if;

                    -- Step 1c : Wait for busy LOW (LCD finished command)
                    when S_WR_CMD_WL =>
                        if lcd_busy = '0' then
                            -- If there are data characters to write, go to character path
                            if wr_len > 0 then
                                state <= S_WR_CHR;
                            else
                                state <= ret_state; -- Command-only write; done
                            end if;
                        end if;

                    ----------------------------------------------------------------
                    -- Step 2a : Send one data character at wr_buf(wr_pos)
                    ----------------------------------------------------------------
                    when S_WR_CHR =>
                        if lcd_busy = '0' then
                            lcd_char_r <= wr_buf(wr_pos); -- Character
                            lcd_rs_r   <= '1';            -- RS=1 for data
                            lcd_send_r <= '1';
                            state      <= S_WR_CHR_WH;
                        end if;

                    -- Step 2b : Wait for busy HIGH
                    when S_WR_CHR_WH =>
                        lcd_send_r <= '0';
                        if lcd_busy = '1' then
                            state <= S_WR_CHR_WL;
                        end if;

                    -- Step 2c : Wait for busy LOW; advance or finish
                    when S_WR_CHR_WL =>
                        if lcd_busy = '0' then
                            if wr_pos = wr_len - 1 then
                                -- Last character written; return to caller
                                state <= ret_state;
                            else
                                wr_pos <= wr_pos + 1;
                                state  <= S_WR_CHR;
                            end if;
                        end if;

                    when others =>
                        state <= S_INIT;

                end case;
            end if; -- rst
        end if; -- rising_edge
    end process p_game;

end architecture rtl;
