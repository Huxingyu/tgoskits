/*
 * RT-Thread 10 ms periodic wake-up latency sampler for the Task 1 A/B.
 *
 * Mirrors the Zephyr probe contract (scripts/test/zephyr-periodic):
 * - waits for a single 'g' byte on the console before sampling,
 * - records 300 absolute-deadline wake-ups at a 10 ms period,
 * - prints CSV rows (sequence,timestamp_ns,deadline_ns,actual_ns,jitter_ns),
 * - prints "PERIODIC LATENCY COMPLETE samples=300" when done.
 *
 * Time is measured with the AArch64 physical counter (CNTPCT_EL0) so that
 * sub-tick jitter is visible even though the OS tick is 1 ms. Deadlines are
 * anchored to the CNTPCT real-time domain and only use the tick clock as a
 * sleep aid, so tick-rate skew cannot accumulate into the measurement.
 */

#include <stdint.h>
#include <string.h>

#include <ioremap.h>
#include <rtdevice.h>
#include <rtthread.h>

#define PERIOD_MS 10
#define SAMPLE_COUNT 300
#define UART0_PHYS UINT64_C(0x09000000)
#define PL011_DR 0x000
#define PL011_FR 0x018
#define PL011_FR_RXFE (1u << 4)

struct latency_sample {
	int64_t timestamp_ns;
	int64_t deadline_ns;
	int64_t actual_ns;
	int64_t jitter_ns;
};

static struct latency_sample samples[SAMPLE_COUNT];

static uint64_t read_cntpct(void)
{
	uint64_t cycles;

	__asm__ volatile("mrs %0, cntpct_el0" : "=r"(cycles));
	return cycles;
}

static uint64_t read_cntfrq(void)
{
	uint64_t freq;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	return freq;
}

static int64_t cycles_to_ns(uint64_t cycles, uint64_t freq)
{
	if (freq == 0) {
		return 0;
	}
	return (int64_t)((cycles * UINT64_C(1000000000)) / freq);
}

static volatile uint32_t *uart_base;

static int uart_init(void)
{
	uart_base = (volatile uint32_t *)rt_ioremap((void *)UART0_PHYS, 0x1000);
	if (uart_base == RT_NULL) {
		return -1;
	}
	return 0;
}

static int uart_getc(void)
{
	if (uart_base == RT_NULL) {
		return -1;
	}
	/* FR.RXFE is set when the receive FIFO is empty. */
	if (uart_base[PL011_FR / 4] & PL011_FR_RXFE) {
		return -1;
	}
	return (int)(uart_base[PL011_DR / 4] & 0xff);
}

static void wait_for_start(void)
{
	char byte = 0;
	rt_device_t console = rt_device_find(RT_CONSOLE_DEVICE_NAME);

	if (uart_init() != 0) {
		rt_kprintf("PERIODIC LATENCY ERROR uart-map-failed\n");
		return;
	}
	if (console != RT_NULL &&
	    rt_device_open(console, RT_DEVICE_OFLAG_RDWR | RT_DEVICE_FLAG_INT_RX) != RT_EOK) {
		rt_kprintf("PERIODIC LATENCY ERROR console-open-failed\n");
		console = RT_NULL;
	}

	rt_kprintf("PERIODIC LATENCY READY\n");
	while (byte != 'g') {
		int ch = uart_getc();
		char dev_byte = 0;

		if (console != RT_NULL &&
		    rt_device_read(console, 0, &dev_byte, 1) == 1) {
			byte = dev_byte;
		} else if (ch >= 0) {
			byte = (char)ch;
		}
		if (byte != 'g') {
			rt_thread_mdelay(1);
		}
	}
	rt_kprintf("PERIODIC LATENCY START\n");
}

int main(void)
{
	uint64_t freq = read_cntfrq();
	uint64_t period_cycles = freq * PERIOD_MS / 1000;
	rt_tick_t base_ticks;
	uint64_t base_cycles;
	int64_t sequence;

	if (freq == 0 || period_cycles == 0) {
		rt_kprintf("PERIODIC LATENCY ERROR counter-frequency=%llu\n",
			   (unsigned long long)freq);
		return 1;
	}

	wait_for_start();

	base_ticks = rt_tick_get();
	while (rt_tick_get() == base_ticks) {
	}
	base_ticks = rt_tick_get();
	base_cycles = read_cntpct();

	for (sequence = 0; sequence < SAMPLE_COUNT; sequence++) {
		uint64_t deadline_cycles;
		uint64_t actual_cycles;

		deadline_cycles =
			base_cycles + (uint64_t)((sequence + 1) * period_cycles);
		for (;;) {
			uint64_t now_cycles = read_cntpct();
			uint64_t remaining_cycles;
			rt_tick_t remaining_ms;

			if (now_cycles >= deadline_cycles) {
				break;
			}
			remaining_cycles = deadline_cycles - now_cycles;
			remaining_ms =
				(rt_tick_t)(remaining_cycles / (freq / 1000));
			if (remaining_ms == 0) {
				break;
			}
			rt_thread_mdelay(remaining_ms);
		}
		actual_cycles = read_cntpct();
		samples[sequence].timestamp_ns =
			cycles_to_ns(actual_cycles - base_cycles, freq);
		samples[sequence].deadline_ns =
			cycles_to_ns(deadline_cycles - base_cycles, freq);
		samples[sequence].actual_ns =
			cycles_to_ns(actual_cycles - base_cycles, freq);
		samples[sequence].jitter_ns =
			samples[sequence].actual_ns - samples[sequence].deadline_ns;
	}

	rt_kprintf("sequence,timestamp_ns,deadline_ns,actual_ns,jitter_ns\n");
	for (sequence = 0; sequence < SAMPLE_COUNT; sequence++) {
		rt_kprintf("%ld,%ld,%ld,%ld,%ld\n",
			   (long)sequence,
			   (long)samples[sequence].timestamp_ns,
			   (long)samples[sequence].deadline_ns,
			   (long)samples[sequence].actual_ns,
			   (long)samples[sequence].jitter_ns);
	}
	rt_kprintf("PERIODIC LATENCY COMPLETE samples=%d\n", SAMPLE_COUNT);
	return 0;
}
