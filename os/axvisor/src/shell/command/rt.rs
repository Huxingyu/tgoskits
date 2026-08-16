// Copyright 2025 The Axvisor Team
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! `rt stat`: low-overhead snapshots for long-run stall diagnosis.

use std::{collections::BTreeMap, println, string::ToString};

use crate::shell::command::{CommandNode, ParsedCommand};

fn rt_stat(_cmd: &ParsedCommand) {
    let runtime = axvm::rt_runtime_stats_snapshot();
    println!("RT vCPU wait counters:");
    for counts in runtime.vcpus {
        if counts.parks != 0 || counts.wakes != 0 || counts.notify_woke != 0 {
            println!(
                "  vcpu={} parks={} wakes={} notify_woke={}",
                counts.vcpu_id, counts.parks, counts.wakes, counts.notify_woke
            );
        }
    }
    println!("  lr_skips={}", runtime.lr_skips);

    println!("RT AxVM timer counters:");
    for counts in runtime.timers {
        if counts.registered != 0
            || counts.cancelled != 0
            || counts.expired != 0
            || counts.worker_wakes != 0
        {
            println!(
                "  cpu={} registered={} cancelled={} expired={} worker_wakes={}",
                counts.cpu_id,
                counts.registered,
                counts.cancelled,
                counts.expired,
                counts.worker_wakes
            );
        }
    }

    println!("RT host hardware timer IRQ counters:");
    for cpu_id in 0..ax_std::os::arceos::modules::ax_runtime::hal::cpu_num() {
        let count = ax_std::os::arceos::modules::ax_task::hardware_timer_irq_count(cpu_id);
        println!("  cpu={} irqs={}", cpu_id, count);
    }

    let console = crate::guest_console::stats_snapshot();
    println!(
        "RT console counters: attached={:?} flush_calls={} host_write_bytes={}",
        console.attached, console.flush_calls, console.host_write_bytes
    );
    for counts in console.guests {
        println!(
            "  vm={} active={} enqueued={} drained={} dropped={} pending={}",
            counts.vm_id,
            counts.active,
            counts.output_enqueued,
            counts.output_drained,
            counts.output_dropped,
            counts.output_pending
        );
    }
}

pub fn build_rt_cmd(tree: &mut BTreeMap<String, CommandNode>) {
    let stat_cmd = CommandNode::new("Show real-time runtime and console counters")
        .with_handler(rt_stat)
        .with_usage("rt stat");
    let rt_cmd = CommandNode::new("Inspect real-time runtime diagnostics")
        .with_usage("rt <stat> ...")
        .add_subcommand("stat", stat_cmd);
    tree.insert("rt".to_string(), rt_cmd);
}
