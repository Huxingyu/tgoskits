/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Earliest observable marker for the ATK-DLRK3588 native BL33 path.
 */

#include <stdint.h>

#define ATK_UART2_BASE 0xfeb50000UL
#define UART_THR       0x00UL
#define UART_LSR       0x14UL
#define UART_LSR_THRE  (1U << 5)

static void raw_putc(char value)
{
	volatile uint32_t *const lsr =
		(volatile uint32_t *)(ATK_UART2_BASE + UART_LSR);
	volatile uint32_t *const thr =
		(volatile uint32_t *)(ATK_UART2_BASE + UART_THR);

	for (unsigned int spin = 0; spin < 1000000U; ++spin) {
		if ((*lsr & UART_LSR_THRE) != 0U) {
			break;
		}
	}
	*thr = (uint32_t)(uint8_t)value;
}

static void raw_puts(const char *text)
{
	while (*text != '\0') {
		raw_putc(*text++);
	}
}

void soc_prep_hook(void)
{
	raw_puts("\r\nATK_NATIVE_PERIODIC_PREP\r\n");
}
