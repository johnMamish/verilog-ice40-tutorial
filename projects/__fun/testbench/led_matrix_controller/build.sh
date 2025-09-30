#!/bin/bash
iverilog -g2012 -o test.vvp ../../led_matrix_controller.sv tb.sv -s tb
./test.vvp
