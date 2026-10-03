-- uart_tx.vhd
-- 8N1 UART transmitter, LSB first, with an extra idle gap after every byte.
--
-- Handshake (valid/ready):
--   tx_ready is '1' only while idle. A byte is accepted on the clock edge
--   where tx_valid = '1' AND tx_ready = '1'. Both this module and the sender
--   see the same edge, so there is no race.
--
-- The gap:
--   The guide warns that the Tang Nano 20K's BL616 USB bridge can drop or
--   corrupt bytes sent back-to-back. After each stop bit we hold the line
--   high for GAP_CYCLES extra clocks before accepting the next byte.
--   This adds directly to measured latency, so tune it with the robust test.
--   Budget: about 4 ms of headroom over 7 inter-byte gaps (~590 us each max).
--   Default 2700 clocks = 100 us at 27 MHz = 0.7 ms total per response.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        CLKS_PER_BIT : positive := 234;
        GAP_CYCLES   : natural  := 2700
    );
    port (
        clk      : in  std_logic;
        tx_valid : in  std_logic;
        tx_data  : in  std_logic_vector(7 downto 0);
        tx_ready : out std_logic;
        tx       : out std_logic                     -- to the pin
    );
end entity;

architecture rtl of uart_tx is

    -- One counter is shared by the bit timer and the gap timer.
    function max_nat(a, b : natural) return natural is
    begin
        if a > b then
            return a;
        else
            return b;
        end if;
    end function;

    constant CNT_TOP : natural := max_nat(CLKS_PER_BIT, GAP_CYCLES);

    type state_t is (S_IDLE, S_START, S_DATA, S_STOP, S_GAP);
    signal state : state_t := S_IDLE;

    signal clk_cnt : natural range 0 to CNT_TOP := 0;
    signal bit_idx : natural range 0 to 7 := 0;
    signal shreg   : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_r    : std_logic := '1';   -- line idles HIGH

begin

    tx       <= tx_r;
    tx_ready <= '1' when state = S_IDLE else '0';

    process (clk)
    begin
        if rising_edge(clk) then
            case state is

                when S_IDLE =>
                    tx_r    <= '1';
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if tx_valid = '1' then
                        shreg <= tx_data;
                        state <= S_START;
                    end if;

                when S_START =>
                    tx_r <= '0';
                    if clk_cnt = CLKS_PER_BIT - 1 then
                        clk_cnt <= 0;
                        state   <= S_DATA;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when S_DATA =>
                    tx_r <= shreg(0);   -- LSB first
                    if clk_cnt = CLKS_PER_BIT - 1 then
                        clk_cnt <= 0;
                        shreg   <= '0' & shreg(7 downto 1);
                        if bit_idx = 7 then
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                        end if;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when S_STOP =>
                    tx_r <= '1';
                    if clk_cnt = CLKS_PER_BIT - 1 then
                        clk_cnt <= 0;
                        if GAP_CYCLES = 0 then
                            state <= S_IDLE;
                        else
                            state <= S_GAP;
                        end if;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when S_GAP =>
                    tx_r <= '1';
                    if clk_cnt >= GAP_CYCLES - 1 then
                        clk_cnt <= 0;
                        state   <= S_IDLE;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

            end case;
        end if;
    end process;

end architecture;
