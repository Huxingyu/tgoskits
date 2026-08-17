# Guest-entry boundary pilot

This one-pair diagnostic extends the post-VM-exit yield experiment with a new
architecture boundary. `*_to_guest_entry` is recorded after pending-vIRQ drain,
timer preparation, vCPU state transition, and VGIC load, immediately before
the AArch64 backend enters the Guest.

The run uses the same single-variable protocol as the counterbalanced pilot:
2-vCPU Linux on pCPU2/pCPU3, `dedicated_cpus=1,2,3`, CNTV-only, trapped WFI,
timerlat, the same stress load, and an unchanged Zephyr control Guest. Only the
modified side disables the unconditional post-VM-exit yield.

## Key result

| Host segment | Baseline | No exit yield | Change |
|---|---:|---:|---:|
| direct ACK to `run_vcpu` dispatch P50 | 15 us | 9 us | 40.00% lower |
| direct ACK to `run_vcpu` dispatch P99 | 24 us | 15 us | 37.50% lower |
| direct ACK to Guest entry P50 | 57 us | 51 us | 10.53% lower |
| direct ACK to Guest entry P99 | 89 us | 79 us | 11.24% lower |
| callback to `run_vcpu` dispatch P99 | 109 us | 102 us | 6.42% lower |
| callback to Guest entry P99 | 169 us | 162 us | 4.14% lower |

The implied dispatch-to-Guest-entry P99 is approximately 60-65 us on both
sides. Removing the yield changes the earlier runqueue segment, but does not
change architecture preparation itself.

pCPU3 timer-wheel expiry P99 was 199 us in the baseline and 198 us in the
modified run. Linux timerlat IRQ P99 was 451.104 us and 587.968 us respectively.
The single-pair end-to-end direction is not accepted: the unchanged Zephyr P99
also moved by 12.41%, and this experiment was designed as a boundary diagnostic.

## Conclusion

VGIC load and the surrounding architecture-entry preparation are measurable
but are not the missing 200-300 us dominant segment. The next split must occur
inside timer expiry lateness: programmed deadline to host hardware IRQ versus
host IRQ to the priority-89 timer worker. That measurement determines whether
the remaining cost is QEMU/hardware timer delivery or an AxVisor scheduling
path that can be optimized.

Raw derived values are in `mechanism-comparison.txt`; all input settings are in
`protocol.txt` and the per-run `meta.txt` files.
