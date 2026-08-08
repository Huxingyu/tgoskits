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

//! Bounded host-side trace for the software-vIRQ delivery path.
//!
//! The ring is deliberately owned by one VM runtime. It is only enabled by
//! the `realtime-trace` feature used by the OpenRace experiment, so normal
//! VM execution does not pay for event storage or timestamp reads.

#[cfg(feature = "realtime-trace")]
use alloc::{
    collections::{BTreeMap, VecDeque},
    vec::Vec,
};
#[cfg(feature = "realtime-trace")]
use core::sync::atomic::{AtomicU64, Ordering};

#[cfg(feature = "realtime-trace")]
use ax_kspin::SpinNoIrq as Mutex;

#[cfg(feature = "realtime-trace")]
use crate::host::{HostCpu, HostTime, default_host};

/// Maximum number of events retained for one host CPU.
#[cfg(feature = "realtime-trace")]
pub(crate) const CAPACITY_PER_CPU: usize = 4096;

/// A point in the host software-vIRQ delivery path.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum VirqTraceKind {
    Enqueue,
    Notify,
    Ipi,
    Running,
    Drain,
    Inject,
}

impl VirqTraceKind {
    #[cfg(feature = "realtime-trace")]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Enqueue => "enqueue",
            Self::Notify => "notify",
            Self::Ipi => "ipi",
            Self::Running => "running",
            Self::Drain => "drain",
            Self::Inject => "inject",
        }
    }
}

/// One immutable trace record.
#[cfg(feature = "realtime-trace")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct VirqTraceEvent {
    pub(crate) sequence: u64,
    pub(crate) timestamp_ns: u64,
    pub(crate) cpu_id: usize,
    pub(crate) vm_id: usize,
    pub(crate) vcpu_id: usize,
    pub(crate) vector: u32,
    pub(crate) kind: VirqTraceKind,
}

/// Per-CPU bounded event rings.
#[cfg(feature = "realtime-trace")]
pub(crate) struct VirqTraceRing {
    sequence: AtomicU64,
    rings: Mutex<BTreeMap<usize, VecDeque<VirqTraceEvent>>>,
}

#[cfg(feature = "realtime-trace")]
impl VirqTraceRing {
    pub(crate) const fn new() -> Self {
        Self {
            sequence: AtomicU64::new(0),
            rings: Mutex::new(BTreeMap::new()),
        }
    }

    pub(crate) fn record(&self, kind: VirqTraceKind, vm_id: usize, vcpu_id: usize, vector: u32) {
        self.record_at(
            kind,
            vm_id,
            vcpu_id,
            vector,
            default_host().this_cpu_id(),
            default_host().monotonic_time().as_nanos() as u64,
        );
    }

    fn record_at(
        &self,
        kind: VirqTraceKind,
        vm_id: usize,
        vcpu_id: usize,
        vector: u32,
        cpu_id: usize,
        timestamp_ns: u64,
    ) {
        let event = VirqTraceEvent {
            sequence: self.sequence.fetch_add(1, Ordering::Relaxed),
            timestamp_ns,
            cpu_id,
            vm_id,
            vcpu_id,
            vector,
            kind,
        };

        let mut rings = self.rings.lock();
        let ring = rings.entry(event.cpu_id).or_default();
        if ring.len() == CAPACITY_PER_CPU {
            ring.pop_front();
        }
        ring.push_back(event);
    }

    pub(crate) fn snapshot(&self) -> Vec<VirqTraceEvent> {
        let rings = self.rings.lock();
        let mut events = rings
            .values()
            .flat_map(|ring| ring.iter().copied())
            .collect::<Vec<_>>();
        events.sort_by_key(|event| event.sequence);
        events
    }
}

#[cfg(all(test, feature = "host-test", feature = "realtime-trace"))]
mod tests {
    use super::*;

    #[test]
    fn ring_is_bounded_and_snapshot_is_sequence_ordered() {
        let ring = VirqTraceRing::new();
        for sequence in 0..(CAPACITY_PER_CPU + 3) {
            ring.record_at(
                VirqTraceKind::Enqueue,
                1,
                0,
                sequence as u32,
                0,
                sequence as u64,
            );
        }

        let events = ring.snapshot();
        assert_eq!(events.len(), CAPACITY_PER_CPU);
        assert!(
            events
                .windows(2)
                .all(|window| window[0].sequence < window[1].sequence)
        );
        assert_eq!(events[0].vector, 3);
    }
}
