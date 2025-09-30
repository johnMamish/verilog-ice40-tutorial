#!/bin/bash
iverilog -g2012 -o test.vvp ../../uart.sv ../../led_matrix_controller.sv ../../top.sv tb.sv -s tb
./test.vvp
