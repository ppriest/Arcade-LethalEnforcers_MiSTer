# Over-constrained at 100 MHz so the limit shows as negative slack and the Fmax
# summary names it. The core runs this at 48 MHz.
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty
