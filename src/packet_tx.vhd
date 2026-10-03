-- packet_tx.vhd
-- Sends one 64-bit response as 8 UART bytes, most significant byte first.
--
-- ma_core holds resp_data stable in registers until the next request, and
-- the judge never sends the next request before this response is complete
-- (stop-and-wait). So instead of copying the response into a second 64-bit
-- shift register (which needs a 64-bit load mux, ~64 LUTs), we simply pick
-- byte number byte_cnt straight out of resp_data.
--
-- Handshake with uart_tx: a byte is accepted on the clock edge where
-- tx_valid = '1' and tx_ready = '1'. The inter-byte gap lives in uart_tx.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity packet_tx is
    port (
        clk        : in  std_logic;
        resp_valid : in  std_logic;                      -- 1-clock pulse
        resp_data  : in  std_logic_vector(63 downto 0);  -- byte 0 in 63..56
        tx_valid   : out std_logic;
        tx_data    : out std_logic_vector(7 downto 0);
        tx_ready   : in  std_logic
    );
end entity;

architecture rtl of packet_tx is

    signal byte_cnt : unsigned(2 downto 0) := (others => '0');
    signal active   : std_logic := '0';

begin

    tx_valid <= active;

    -- Byte 0 is bits 63..56, byte 7 is bits 7..0.
    with byte_cnt select tx_data <=
        resp_data(63 downto 56) when "000",
        resp_data(55 downto 48) when "001",
        resp_data(47 downto 40) when "010",
        resp_data(39 downto 32) when "011",
        resp_data(31 downto 24) when "100",
        resp_data(23 downto 16) when "101",
        resp_data(15 downto  8) when "110",
        resp_data( 7 downto  0) when others;

    process (clk)
    begin
        if rising_edge(clk) then
            if active = '0' then
                if resp_valid = '1' then
                    byte_cnt <= (others => '0');
                    active   <= '1';
                end if;

            elsif tx_ready = '1' then
                -- uart_tx takes the current byte on this edge.
                if byte_cnt = 7 then
                    active <= '0';
                end if;
                byte_cnt <= byte_cnt + 1;   -- wraps 7 -> 0
            end if;
        end if;
    end process;

end architecture;
