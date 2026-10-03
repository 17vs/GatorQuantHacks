-- ma_core.vhd
-- Design B: one shared moving-average engine, slots processed one at a time.
--
-- FSM:  IDLE --pkt_valid--> SLOT1 --> SLOT2 --> RESP --> IDLE
--
--   IDLE  : latch the request. If index = 0, clear ALL state (new session).
--   SLOT1 : run the engine on (item1, price1), write that item's state back.
--   SLOT2 : run the engine on (item2, price2), write that item's state back.
--   RESP  : hand the 8-byte response to packet_tx.
--
-- Routing is by item ID, never by slot. is_b selects which item's registers
-- the shared datapath reads and writes. Because SLOT1 finishes writing before
-- SLOT2 reads, a packet carrying the same item in both slots still works.
--
-- Per item:  window(0..15), sum (20 bits), prev (16 bits), last action.
-- The window is a shift register: newest price enters at window(0), oldest
-- falls out of window(15). No pointer, no read mux.
--
-- Warm-up uses the same formula as everything else:
--   new_sum = sum - oldest + current
-- Because index 0 zeroes the window, "oldest" is 0 for the first 16 samples,
-- so warm-up packets simply add their price. This keeps the invariant
-- sum == sum of the 16 window entries at all times, and at index 16 the
-- oldest entry is exactly the index-0 price.
--
-- Warm-up is decided by the INDEX (spec: indices 0-15), not a per-item flag.
-- At index 16 crossings are evaluated, which is the first scored packet.
--
-- The whole computation takes about 4 clocks (~150 ns). The UART needs
-- ~700 us just to receive the request, so doing things one at a time costs
-- nothing measurable and saves LUTs.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ma_core is
    port (
        clk        : in  std_logic;
        pkt_valid  : in  std_logic;
        pkt_data   : in  std_logic_vector(63 downto 0);
        resp_valid : out std_logic;
        resp_data  : out std_logic_vector(63 downto 0)
    );
end entity;

architecture rtl of ma_core is

    constant ITEM_B   : std_logic_vector(7 downto 0) := x"22";
    constant ACT_NONE : std_logic_vector(1 downto 0) := "00";
    constant ACT_SELL : std_logic_vector(1 downto 0) := "01";
    constant ACT_BUY  : std_logic_vector(1 downto 0) := "10";

    type window_t is array (0 to 15) of unsigned(15 downto 0);

    ------------------------------------------------------------------------
    -- Per-item state (flip-flops; FFs are not scored, only LUTs are)
    ------------------------------------------------------------------------
    signal win_a  : window_t := (others => (others => '0'));
    signal win_b  : window_t := (others => (others => '0'));
    signal sum_a  : unsigned(19 downto 0) := (others => '0');
    signal sum_b  : unsigned(19 downto 0) := (others => '0');
    signal prev_a : unsigned(15 downto 0) := (others => '0');
    signal prev_b : unsigned(15 downto 0) := (others => '0');
    signal act_a  : std_logic_vector(1 downto 0) := ACT_NONE;
    signal act_b  : std_logic_vector(1 downto 0) := ACT_NONE;

    -- Ask synthesis to keep the windows as plain flip-flops rather than
    -- packing them into LUT-based shift registers (which WOULD cost LUTs).
    -- The synchronous clear on index 0 should also prevent that packing.
    -- Verify in the Resource Usage Summary either way.
    attribute syn_srlstyle : string;
    attribute syn_srlstyle of win_a : signal is "registers";
    attribute syn_srlstyle of win_b : signal is "registers";

    ------------------------------------------------------------------------
    -- Control
    ------------------------------------------------------------------------
    type state_t is (S_IDLE, S_SLOT1, S_SLOT2, S_RESP);
    signal state : state_t := S_IDLE;

    signal req     : std_logic_vector(63 downto 0) := (others => '0');
    signal res1    : std_logic_vector(1 downto 0)  := ACT_NONE;
    signal res2    : std_logic_vector(1 downto 0)  := ACT_NONE;
    signal valid_r : std_logic := '0';

    ------------------------------------------------------------------------
    -- Request fields (pure wire slices, zero logic)
    ------------------------------------------------------------------------
    signal req_index  : std_logic_vector(15 downto 0);
    signal req_item1  : std_logic_vector(7 downto 0);
    signal req_price1 : unsigned(15 downto 0);
    signal req_item2  : std_logic_vector(7 downto 0);
    signal req_price2 : unsigned(15 downto 0);

    ------------------------------------------------------------------------
    -- Shared datapath (combinational)
    ------------------------------------------------------------------------
    signal cur_item  : std_logic_vector(7 downto 0);
    signal cur_price : unsigned(15 downto 0);
    signal is_b      : std_logic;
    signal oldest    : unsigned(15 downto 0);
    signal sum_s     : unsigned(19 downto 0);
    signal prev_s    : unsigned(15 downto 0);
    signal act_s     : std_logic_vector(1 downto 0);
    signal new_sum   : unsigned(19 downto 0);
    signal old_avg   : unsigned(15 downto 0);
    signal new_avg   : unsigned(15 downto 0);
    signal warmup    : std_logic;
    signal prev_lt   : std_logic;
    signal prev_eq   : std_logic;
    signal cur_lt    : std_logic;
    signal cur_eq    : std_logic;
    signal clear     : std_logic;
    signal wr_a      : std_logic;
    signal wr_b      : std_logic;
    signal buy       : std_logic;
    signal sell      : std_logic;
    signal act_next  : std_logic_vector(1 downto 0);

begin

    req_index  <= req(63 downto 48);
    req_item1  <= req(47 downto 40);
    req_price1 <= unsigned(req(39 downto 24));
    req_item2  <= req(23 downto 16);
    req_price2 <= unsigned(req(15 downto 0));

    -- Which slot is being processed this clock
    cur_item  <= req_item2  when state = S_SLOT2 else req_item1;
    cur_price <= req_price2 when state = S_SLOT2 else req_price1;

    -- Route by item ID. 0x22 = item B, anything else = item A.
    -- (The spec fixes the IDs at 0x11 and 0x22.)
    is_b <= '1' when cur_item = ITEM_B else '0';

    -- Select the active item's state. This is the one mux that sharing needs.
    oldest <= win_b(15) when is_b = '1' else win_a(15);
    sum_s  <= sum_b     when is_b = '1' else sum_a;
    prev_s <= prev_b    when is_b = '1' else prev_a;
    act_s  <= act_b     when is_b = '1' else act_a;

    -- Steps 1-3 of the spec. ">> 4" is just a bit slice: zero logic.
    new_sum <= sum_s - resize(oldest, 20) + resize(cur_price, 20);
    old_avg <= sum_s(19 downto 4);
    new_avg <= new_sum(19 downto 4);

    -- Indices 0..15 are warm-up: index < 16  <=>  index(15 downto 4) = 0
    warmup <= '1' when unsigned(req_index(15 downto 4)) = 0 else '0';

    -- Steps 4-5, written with only two magnitude comparators:
    --   prev <= old_avg  =  prev_lt or prev_eq      prev >= old_avg  =  not prev_lt
    --   cur  >  new_avg  =  not (cur_lt or cur_eq)  cur  <  new_avg  =  cur_lt
    -- Equality checks are much cheaper than magnitude compares.
    prev_lt <= '1' when prev_s    < old_avg else '0';
    prev_eq <= '1' when prev_s    = old_avg else '0';
    cur_lt  <= '1' when cur_price < new_avg else '0';
    cur_eq  <= '1' when cur_price = new_avg else '0';

    buy  <= (prev_lt or prev_eq) and not (cur_lt or cur_eq);
    sell <= (not prev_lt) and cur_lt;

    -- Step 6: warm-up forces NONE; otherwise crossing, else repeat last action.
    act_next <= ACT_NONE when warmup = '1' else
                ACT_BUY  when buy    = '1' else
                ACT_SELL when sell   = '1' else
                act_s;

    -- Response: index, item1, action1, item2, action2, reserved 0x0000.
    -- Index and item IDs are echoed straight from the request, so the slot
    -- order automatically mirrors the request.
    resp_valid <= valid_r;
    resp_data  <= req(63 downto 40)                 -- index (16) + item1 (8)
                & "000000" & res1                   -- action1
                & req(23 downto 16)                 -- item2
                & "000000" & res2                   -- action2
                & x"0000";                          -- reserved

    -- Control decodes. clear has priority over writes, which lets synthesis
    -- use the flip-flops' built-in synchronous reset (DFFRE) for free.
    -- Written the other way round (clear inside an enabled branch), the
    -- tools add one LUT per bit: ~512 LUTs for the windows alone.
    clear <= '1' when state = S_IDLE and pkt_valid = '1'
                      and pkt_data(63 downto 48) = x"0000" else '0';
    wr_a  <= '1' when (state = S_SLOT1 or state = S_SLOT2) and is_b = '0' else '0';
    wr_b  <= '1' when (state = S_SLOT1 or state = S_SLOT2) and is_b = '1' else '0';

    ------------------------------------------------------------------------
    -- Per-item state. Index 0 clears everything; SLOT1/SLOT2 then treat
    -- index 0's prices as the first samples of the new window.
    ------------------------------------------------------------------------
    state_regs : process (clk)
    begin
        if rising_edge(clk) then
            if clear = '1' then
                win_a  <= (others => (others => '0'));
                win_b  <= (others => (others => '0'));
                sum_a  <= (others => '0');
                sum_b  <= (others => '0');
                prev_a <= (others => '0');
                prev_b <= (others => '0');
                act_a  <= ACT_NONE;
                act_b  <= ACT_NONE;
            else
                if wr_a = '1' then
                    for i in 15 downto 1 loop
                        win_a(i) <= win_a(i - 1);
                    end loop;
                    win_a(0) <= cur_price;
                    sum_a    <= new_sum;
                    prev_a   <= cur_price;
                    act_a    <= act_next;
                end if;
                if wr_b = '1' then
                    for i in 15 downto 1 loop
                        win_b(i) <= win_b(i - 1);
                    end loop;
                    win_b(0) <= cur_price;
                    sum_b    <= new_sum;
                    prev_b   <= cur_price;
                    act_b    <= act_next;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------------
    -- Control FSM
    ------------------------------------------------------------------------
    fsm : process (clk)
    begin
        if rising_edge(clk) then
            valid_r <= '0';

            case state is

                when S_IDLE =>
                    if pkt_valid = '1' then
                        req   <= pkt_data;
                        state <= S_SLOT1;
                    end if;

                when S_SLOT1 =>
                    res1  <= act_next;
                    state <= S_SLOT2;

                when S_SLOT2 =>
                    res2  <= act_next;
                    state <= S_RESP;

                when S_RESP =>
                    valid_r <= '1';
                    state   <= S_IDLE;

            end case;
        end if;
    end process;

end architecture;
