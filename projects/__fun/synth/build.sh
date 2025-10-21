#!/bin/bash
rm proj.json
yosys -l yosys.log -s synth.yosys
nextpnr-ice40 \
    --up5k --package sg48 \
    --randomize-seed \
    --pcf pins.pcf --json proj.json \
    --opt-timing --tmg-ripup \
    --asc proj.asc
icepack proj.asc proj.bin
