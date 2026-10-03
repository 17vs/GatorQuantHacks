# Team ClockCycleGang: GQH Hardware Track

## Team
- Vincent Schifano
- Daniel Cao
- Himmet Dhaliwal
- Avi Patel

## Description
A hardware moving-average crossing detector. The FPGA receives 8-byte UART requests containing prices for Item A (0x11) and Item B (0x22), keeps an independent 16-price window per item, and replies with 8 bytes containing a BUY / SELL / NONE action for each item.

## What runs on the FPGA
Everything: UART RX/TX, packet parsing, item routing by ID, the two 16-sample windows and 20-bit rolling sums, crossing detection, last-action hold, session reset on index 0, and response generation. No host software runs during judging.

## Hardware and tools
| Item | Value |
|---|---|
| Board | Tang Nano 20K |
| FPGA part | GW2AR-LV18QN88C8/I7 |
| HDL | VHDL |
| Gowin EDA version | V1.9.11.03 Education |
| Top-level entity | `top` |

## Repository layout
```text
README.md
src/          Six VHDL source files
constraints/  Organizer-supplied 19_tang_nano_20k.cst
testbench/    Organizer-provided Python on-board UART tests
gowin/        Gowin project files
bitstream/    Final tested run3.fs
results/      Test CSVs and per-run summaries
```

## Build and program

1. Open `gowin/run3.gprj` in Gowin EDA.
2. Confirm all six VHDL files and the organizer-supplied `.cst` are included in the project.
3. Set Top Module/Entity to `top` under Project > Configuration > Synthesize > General.
4. Run Synthesize, then Place & Route. Both must complete successfully.
5. Connect the Tang Nano 20K using a USB data cable.
6. Open Tools > Programmer, scan the device, and select GW2AR-18C.
7. Set Access Mode to SRAM Mode and Operation to SRAM Program.
8. For a fresh build, select `impl/pnr/run3.fs` relative to the Gowin project directory, then click Program/Configure.
9. Close Programmer, keep the board powered, and run the Python tests.
10. After verification, copy the tested bitstream to `bitstream/run3.fs` for submission.

To program the submitted build directly, select `bitstream/run3.fs`.

Optional fallback from the repository root:
`openFPGALoader -b tangnano20k bitstream/run3.fs`

SRAM programming is volatile; reprogram the board after it loses power.

## Inputs, outputs, and how to reproduce

- UART: 115200 baud, 8 data bits, no parity, 1 stop bit, LSB first.
- Multi-byte fields are big-endian. Prices are unsigned 16-bit values.
- Item IDs: A = `0x11`, B = `0x22`.
- Action codes: NONE = `0x00`, SELL = `0x01`, BUY = `0x02`.
- Request: exactly 8 bytes: index(2), item1(1), price1(2), item2(1), price2(2).
- Response: exactly 8 bytes: index(2), item1(1), action1(1), item2(1), action2(1), reserved(2).
- Reserved response bytes are always `0x0000`.
- Example request: `00 10 11 00 50 22 00 C8` represents index 16, A = 80, and B = 200.
- The host sends one request and waits for its complete response before sending the next.

Install Python 3 and the serial dependency:
```bash
python -m pip install pyserial
```

Program the board and close Gowin Programmer. Change only `PORT` in each test script to match your board's serial port. Our Windows test setup port used COM9 and Mac test port setup used /dev/cu.usbserial-20250303171.

From the repository root, run:
```bash
python testbench/21_quick_uart_test.py
python testbench/22_robust_uart_test.py
```

Use `python3` instead of `python` if required by your installation. Keep the board powered between runs; index 0 resets the session automatically.

The robust script writes its CSV and summary in the current working directory. Copy them into `results/` and give each run a unique filename before running the test again.

## Testing and verification
- **Simulation:** No HDL simulation was performed. On-board validation used the organizer-provided Python tests and their moving-average software reference models as the golden model.
- **On-board:** Quick UART test: PASS. Robust UART test: 84/84 scored packets correct, 168/168 actions correct, and zero timeouts.
- **Soak test:** 10 consecutive robust runs without resetting or reprogramming, all achieving 100% correctness. Across 1,000 received packets: zero timeouts, 840/840 scored packets correct, and 1,680/1,680 scored actions correct. Overall average round-trip latency: 16.743 ms.
- CSVs and per-run summaries are in `results/`.

## Results
| Metric | Ours | Organizer reference |
| --- | --- | --- |
| Total LUTs (synthesis report) | 298 | 542 |
| Average round-trip latency (single robust run) | 16.638 ms | 16.626 ms |
| Average round-trip latency (10 consecutive robust runs) | 16.743 ms | — |
| Scored packet correctness (single run) | 84/84 | — |
| Scored action correctness (single run) | 168/168 | — |
| Scored packet correctness (10 runs) | 840/840 | — |
| Scored action correctness (10 runs) | 1,680/1,680 | — |
| Timeouts across runs | 0 | — |

Latency measurements are from our local test computer.
Official judging uses the organizer's judging computer.

## Design notes
- **TX inter-byte gap:** The transmitter adds 100 µs of idle time after each byte (`TX_GAP_CYCLES = 2700` at 27 MHz) to help prevent dropped or corrupted bytes in the BL616 USB bridge. This setting passed all ten saved robust test runs.
- **Warm-up and reset strategy:** Indices 0–15 fill independent 16-price shift-register windows for A and B and return NONE. Index 0 clears both windows, rolling sums, previous prices, and held actions before processing the new session's prices. Each update shifts in the current price and removes the oldest. From index 16 onward, crossings use floor-divided old and new averages. Routing follows item IDs regardless of packet slot.
- **LUT optimizations and measured savings:** A shared arithmetic datapath processes the two slots sequentially. Shift-register windows avoid variable-address read multiplexers and buffer pointers. Actions use two bits, the UART transmitter shares its bit/gap timer, and packet reception uses a shift register. Synthesis LUT usage decreased from 604 to 298, saving 306 LUTs (50.7%).

## Known limitations
No failures were observed in the saved on-board tests. HDL simulation was not performed, and the official unpublished price seed has not been tested.
The reset button is unused; new sessions reset automatically at index 0.
The packet receiver discards partial requests after approximately 4.85 ms without another received byte.
