#!/usr/bin/env python3
"""Create memory pressure: allocate and keep touching GB of RAM so the system has to swap.

Usage: memory.py [GB=physical RAM * 1.2] [HOLD_SECONDS=90]
Shows up in JankWatch as process "Python"/"python3" (memory pressure). Ctrl-C to release.
"""
import os, sys, time, subprocess

ram = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip())
gb = float(sys.argv[1]) if len(sys.argv) > 1 else ram * 1.2 / 2**30
hold = float(sys.argv[2]) if len(sys.argv) > 2 else 90
chunk = 256 * 2**20
blocks = []
print(f"RAM {ram/2**30:.1f} GB; allocating {gb:.1f} GB in 256 MB chunks, then holding {hold:.0f}s")
try:
    while len(blocks) * chunk < gb * 2**30:
        b = bytearray(os.urandom(chunk))  # random content: the memory compressor cannot shrink it
        blocks.append(b)
        print(f"  {len(blocks) * chunk / 2**30:.2f} GB", flush=True)
    end = time.time() + hold
    while time.time() < end:  # keep touching pages so they stay hot
        for b in blocks:
            for i in range(0, len(b), 65536):
                b[i] = (b[i] + 1) & 0xFF
        time.sleep(0.5)
except KeyboardInterrupt:
    pass
print("released")
