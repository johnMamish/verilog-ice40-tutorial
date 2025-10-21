#!/bin/bash
rm proj.json
yosys -l yosys.log -s synth.yosys
