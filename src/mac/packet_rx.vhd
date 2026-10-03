-- packet_rx.vhd
-- Collects 8 UART bytes into one 64-bit request.
--
-- Bytes are shifted in at the bottom, so after 8 bytes the FIRST byte
-- received sits in bits 63..56. That matches the protocol's MSB-first
-- byte order, so every field is just a fixed slice of pkt_data:
--
--   index  = pkt_data(63 downto 48)
--   item1  = pkt_data(47 downto 40)
--   price1 = pkt_data(39 downto 24)
--   item2  = pkt_data(23 downto 16)
--   price2 = pkt_data(15 downto 0)
--
-- Shifting (instead of writing buf(byte_count)) needs no decoder and no
-- 8-way mux, which saves LUTs.
--
-- Stale-byte flush:
--   If a packet is half received and the line then goes quiet for
--   2**TIMEOUT_LOG2 clocks, the partial packet is discarded. During a judged
--   run a dropped byte times out that packet regardless, so this does not
--   rescue that case. What it DOES protect is the start of a run: a stray
--   byte from opening the COM port, or an aborted earlier test, would
--   otherwise shift every following packet by one byte and fail the whole
--   run.
--
--   Using a power of two means "timed out" is just the counter's top bit,
--   instead of comparing against an arbitrary constant.
--   TIMEOUT_LOG2 = 17 -> 131072 clocks = 4.85 ms at 27 MHz.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity packet_rx is
    generic (
        TIMEOUT_LOG2 : positive := 17
    );
    port (
        clk       : in  std_logic;
        rx_valid  : in  std_logic;
        rx_data   : in  std_logic_vector(7 downto 0);
        pkt_valid : out std_logic;                       -- 1-clock pulse
        pkt_data  : out std_logic_vector(63 downto 0)
    );
end entity;

architecture rtl of packet_rx is

    signal shreg    : std_logic_vector(63 downto 0) := (others => '0');
    signal byte_cnt : unsigned(2 downto 0) := (others => '0');
    signal idle_cnt : unsigned(TIMEOUT_LOG2 downto 0) := (others => '0');
    signal timeout  : std_logic;
    signal valid_r  : std_logic := '0';

begin

    pkt_valid <= valid_r;
    pkt_data  <= shreg;

    timeout <= idle_cnt(TIMEOUT_LOG2);

    -- Shift register: enable only, no reset, no mux -> no LUTs.
    process (clk)
    begin
        if rising_edge(clk) then
            if rx_valid = '1' then
                shreg <= shreg(55 downto 0) & rx_data;
            end if;
        end if;
    end process;

    -- Byte counter and packet strobe.
    process (clk)
    begin
        if rising_edge(clk) then
            valid_r <= '0';
            if rx_valid = '1' then
                if byte_cnt = 7 then
                    valid_r <= '1';      -- all 8 bytes are in
                end if;
                byte_cnt <= byte_cnt + 1;   -- wraps 7 -> 0
            elsif timeout = '1' then
                byte_cnt <= (others => '0');   -- discard partial packet
            end if;
        end if;
    end process;

    -- Idle timer: cleared by any byte or when no packet is in progress,
    -- otherwise counts up until its top bit sets, then holds.
    process (clk)
    begin
        if rising_edge(clk) then
            if rx_valid = '1' or byte_cnt = 0 then
                idle_cnt <= (others => '0');
            elsif timeout = '0' then
                idle_cnt <= idle_cnt + 1;
            end if;
        end if;
    end process;

end architecture;
