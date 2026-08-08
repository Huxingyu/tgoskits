#include <stdint.h>

#include <zephyr/arch/arm64/arch.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/time_units.h>

#define PERIOD_MS 10
#define SAMPLE_COUNT 300

int main(void)
{
	printk("SYNTHETIC VIRQ BOOT cpus=%d\n", arch_num_cpus());
	while (arch_num_cpus() < 2) {
		k_msleep(1);
	}

	printk("SYNTHETIC VIRQ START samples=%d target_cpu=1\n", SAMPLE_COUNT);
	printk("sequence,timestamp_ns\n");
	const int64_t base_cycles = (int64_t)k_cycle_get_64();

	for (int64_t sequence = 0; sequence < SAMPLE_COUNT; sequence++) {
		const int64_t deadline_cycles =
			base_cycles + (sequence + 1) *
			((int64_t)sys_clock_hw_cycles_per_sec() * PERIOD_MS / 1000);
		const int64_t now_cycles = (int64_t)k_cycle_get_64();
		if (now_cycles < deadline_cycles) {
			k_sleep(K_CYC((uint64_t)(deadline_cycles - now_cycles)));
		}

		const int64_t send_cycles = (int64_t)k_cycle_get_64();
		arch_sched_directed_ipi(1u << 1);
		printk("%lld,%lld\n", sequence,
		       (int64_t)k_cyc_to_ns_floor64((uint64_t)(send_cycles - base_cycles)));
	}

	printk("SYNTHETIC VIRQ COMPLETE samples=%d\n", SAMPLE_COUNT);
	return 0;
}
