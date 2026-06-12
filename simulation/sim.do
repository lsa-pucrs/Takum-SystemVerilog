# python3 tools/takum_oracle.py gen codec 16 simulation/codec_vectors_16.txt <-- Gera o arquivo de dados base para o teste

if {[file isdirectory work]} {vdel -all -lib work}
vlib work
vmap work work

vlog -work work ../rtl/decoder/decoder_linear.sv
vlog -work work ../rtl/decoder/decoder_logarithmic.sv
vlog -work work ../rtl/decoder/predecoder.sv
vlog -work work ../rtl/encoder/encoder_linear.sv
vlog -work work ../rtl/encoder/encoder_logarithmic.sv
vlog -work work ../rtl/encoder/postencoder.sv
vlog -work work codec_roundtrip_tb.sv

vsim -voptargs=+acc work.codec_roundtrip_tb +VEC=codec_vectors_16.txt

quietly set StdArithNoWarnings 1
quietly set StdVitalGlitchNoWarnings 1

add wave *
run 70us
