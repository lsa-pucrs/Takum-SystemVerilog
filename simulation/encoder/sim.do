# python3 tools/takum_oracle.py gen encode 16 simulation/encoder/encode_vectors_16.txt <-- gera os valores para o teste padrão
# python3 tools/takum_oracle.py gen encsweep 16 simulation/encoder/encsweep_vectors_16.txt <-- gera os valores para o teste de estresse de arredondamento

if {[file isdirectory work]} {vdel -all -lib work}
vlib work
vmap work work

vlog -work work ../../rtl/encoder/encoder_linear.sv
vlog -work work ../../rtl/encoder/encoder_logarithmic.sv
vlog -work work ../../rtl/encoder/postencoder.sv
vlog -work work postencoder_tb.sv

# vsim para teste padrão
vsim -voptargs=+acc work.postencoder_tb +VEC=encode_vectors_16.txt
# Para teste de estresse de arredondamento
# vsim -voptargs=+acc work.postencoder_tb +VEC=encsweep_vectors_16.txt

quietly set StdArithNoWarnings 1
quietly set StdVitalGlitchNoWarnings 1

add wave *
run 70us
