//! WFI trapping policy for the AArch64 timer backend.

/// Hardware wake sources available while a guest remains inside WFI.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct TimerWakeCapabilities {
    pub(super) virtual_timer: bool,
    pub(super) physical_timer: bool,
}

/// The current world switch loads CNTV state directly, while guest CNTP state
/// remains software-emulated and needs a trapped WFI to arm the host timer.
pub(super) const TIMER_WAKE_CAPABILITIES: TimerWakeCapabilities = TimerWakeCapabilities {
    virtual_timer: true,
    physical_timer: false,
};

pub(super) const fn trap_wfi(
    placed_on_dedicated_cpus: bool,
    capabilities: TimerWakeCapabilities,
) -> bool {
    !placed_on_dedicated_cpus || !capabilities.virtual_timer || !capabilities.physical_timer
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dedicated_vcpu_still_traps_wfi_when_a_guest_timer_is_emulated() {
        assert!(trap_wfi(
            true,
            TimerWakeCapabilities {
                virtual_timer: true,
                physical_timer: false,
            }
        ));
    }

    #[test]
    fn shared_vcpu_always_traps_wfi() {
        assert!(trap_wfi(
            false,
            TimerWakeCapabilities {
                virtual_timer: true,
                physical_timer: true,
            }
        ));
    }

    #[test]
    fn dedicated_vcpu_may_wait_in_place_when_every_guest_timer_wakes_in_hardware() {
        assert!(!trap_wfi(
            true,
            TimerWakeCapabilities {
                virtual_timer: true,
                physical_timer: true,
            }
        ));
    }
}
