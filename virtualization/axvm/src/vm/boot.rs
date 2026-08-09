//! Guest boot image address planning.

pub(crate) use crate::config::GuestBootPolicy;
use crate::{
    GuestPhysAddr,
    config::{AxVMConfig, VMBootProtocol},
};

const BIOS_RESERVED_SIZE: usize = 2 * 1024 * 1024;

/// Boot image placement facts derived from prepared VM memory.
pub(crate) struct BootImagePlan {
    main_memory_gpa: GuestPhysAddr,
    main_memory_identical: bool,
}

impl BootImagePlan {
    pub(crate) const fn new(main_memory_gpa: GuestPhysAddr, main_memory_identical: bool) -> Self {
        Self {
            main_memory_gpa,
            main_memory_identical,
        }
    }

    pub(crate) fn apply_to_config(&self, config: &mut AxVMConfig) {
        let Some(kernel_load_gpa) = self.adjusted_kernel_load_gpa(config) else {
            return;
        };
        config.relocate_kernel_image(kernel_load_gpa);

        // With identity-mapped guest memory the configured GPA is replaced by
        // the dynamically allocated HPA. The kernel is relocated above, but
        // the ramdisk (and the FDT `/chosen` initrd range derived from it)
        // must follow the same base so the fixed load address stays valid.
        if self.main_memory_identical {
            let configured_base = config.memory_regions().first().map(|region| region.gpa);
            if let (Some(base), Some(ramdisk)) =
                (configured_base, config.image_config().ramdisk.as_ref())
                && let Some(offset) = ramdisk.load_gpa.as_usize().checked_sub(base)
            {
                config.relocate_ramdisk_image(GuestPhysAddr::from(
                    self.main_memory_gpa.as_usize() + offset,
                ));
            }
        }
    }

    fn adjusted_kernel_load_gpa(&self, config: &AxVMConfig) -> Option<GuestPhysAddr> {
        let GuestBootPolicy::AdjustKernelForBootProtocol { protocol } = config.boot_policy() else {
            return None;
        };
        if protocol == VMBootProtocol::Uefi || !self.main_memory_identical {
            return None;
        }

        let mut kernel_addr = self.main_memory_gpa;
        if protocol == VMBootProtocol::Multiboot && config.image_config().bios_load_gpa.is_some() {
            kernel_addr += BIOS_RESERVED_SIZE;
        }
        Some(kernel_addr)
    }
}

#[cfg(test)]
mod tests {
    use alloc::string::String;

    use super::*;
    use crate::config::{
        AxVCpuConfig, AxVMConfig, AxVMConfigParams, PhysCpuList, RamdiskInfo, VMImageConfig,
    };

    fn config_for_boot_policy(
        protocol: VMBootProtocol,
        bios_load_gpa: Option<usize>,
    ) -> AxVMConfig {
        AxVMConfig::new(AxVMConfigParams {
            id: 1,
            name: String::from("boot-policy-test"),
            phys_cpu_ls: PhysCpuList::new(1, None, None),
            cpu_config: AxVCpuConfig {
                bsp_entry: GuestPhysAddr::from(0x101000),
                ap_entry: GuestPhysAddr::from(0x102000),
            },
            image_config: VMImageConfig {
                kernel_load_gpa: GuestPhysAddr::from(0x100000),
                loaded_from_filesystem: false,
                bios_load_gpa: bios_load_gpa.map(GuestPhysAddr::from),
                dtb_load_gpa: None,
                ramdisk: None,
            },
            boot_policy: GuestBootPolicy::AdjustKernelForBootProtocol { protocol },
            ..Default::default()
        })
    }

    #[test]
    fn boot_policy_moves_multiboot_kernel_after_reserved_bios_space() {
        let mut config = config_for_boot_policy(VMBootProtocol::Multiboot, Some(0x8000));
        let plan = BootImagePlan::new(GuestPhysAddr::from(0x4000_0000), true);

        plan.apply_to_config(&mut config);

        assert_eq!(
            config.image_config().kernel_load_gpa.as_usize(),
            0x4020_0000
        );
        assert_eq!(config.bsp_entry().as_usize(), 0x4020_1000);
        assert_eq!(config.ap_entry().as_usize(), 0x4020_2000);
    }

    #[test]
    fn boot_policy_keeps_uefi_kernel_load_address() {
        let mut config = config_for_boot_policy(VMBootProtocol::Uefi, Some(0x2000_0000));
        let plan = BootImagePlan::new(GuestPhysAddr::from(0x4000_0000), true);

        plan.apply_to_config(&mut config);

        assert_eq!(config.image_config().kernel_load_gpa.as_usize(), 0x100000);
        assert_eq!(config.bsp_entry().as_usize(), 0x101000);
        assert_eq!(config.ap_entry().as_usize(), 0x102000);
    }

    #[test]
    fn keep_configured_boot_policy_does_not_relocate_identical_memory() {
        let mut config = config_for_boot_policy(VMBootProtocol::Multiboot, Some(0x8000));
        config.set_boot_policy(GuestBootPolicy::KeepConfigured);
        let plan = BootImagePlan::new(GuestPhysAddr::from(0x4000_0000), true);

        plan.apply_to_config(&mut config);

        assert_eq!(config.image_config().kernel_load_gpa.as_usize(), 0x100000);
        assert_eq!(config.bsp_entry().as_usize(), 0x101000);
        assert_eq!(config.ap_entry().as_usize(), 0x102000);
    }

    #[test]
    fn identical_memory_relocates_ramdisk_with_kernel() {
        let mut config = config_for_boot_policy(VMBootProtocol::Direct, None);
        config.image_config.ramdisk = Some(RamdiskInfo {
            load_gpa: GuestPhysAddr::from(0x8800_0000),
            size: None,
        });
        config.set_memory_regions(alloc::vec![crate::config::VmMemConfig {
            gpa: 0x8000_0000,
            size: 0x1000_0000,
            flags: 0x7,
            map_type: crate::config::VmMemMappingType::MapIdentical,
        }]);
        let plan = BootImagePlan::new(GuestPhysAddr::from(0x5000_0000), true);

        plan.apply_to_config(&mut config);

        assert_eq!(
            config
                .image_config()
                .ramdisk
                .as_ref()
                .unwrap()
                .load_gpa
                .as_usize(),
            0x5800_0000
        );
    }

    #[test]
    fn non_identical_memory_keeps_ramdisk_address() {
        let mut config = config_for_boot_policy(VMBootProtocol::Direct, None);
        config.image_config.ramdisk = Some(RamdiskInfo {
            load_gpa: GuestPhysAddr::from(0x8800_0000),
            size: None,
        });
        let plan = BootImagePlan::new(GuestPhysAddr::from(0x5000_0000), false);

        plan.apply_to_config(&mut config);

        assert_eq!(
            config
                .image_config()
                .ramdisk
                .as_ref()
                .unwrap()
                .load_gpa
                .as_usize(),
            0x8800_0000
        );
    }
}
