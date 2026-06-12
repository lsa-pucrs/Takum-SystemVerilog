# python3 tools/takum_oracle.py gen decode 16 simulation/decoder-sim/decode_vectors_16.txt 0 <-- gera os valores para o teste

if {[file isdirectory work]} {vdel -all -lib work}
vlib work
vmap work work

vlog -work work ../../rtl/decoder/decoder_linear.sv
vlog -work work ../../rtl/decoder/decoder_logarithmic.sv
vlog -work work ../../rtl/decoder/predecoder.sv
vlog -work work predecoder_tb.sv

vsim -voptargs=+acc work.predecoder_tb +VEC=decode_vectors_16.txt

quietly set StdArithNoWarnings 1
quietly set StdVitalGlitchNoWarnings 1

add wave *
run 70us
