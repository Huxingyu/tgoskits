use alloc::sync::Arc;
use core::{
    ops::Deref,
    sync::atomic::{AtomicIsize, AtomicU64, Ordering},
};

use ax_linked_list_r4l::{GetLinks, Links, List};

use crate::{BaseScheduler, MAX_PRIORITY, MIN_PRIORITY, SchedPriority};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PriorityRRStats {
    pub quantum_expiries: u64,
    pub same_priority_rotations: u64,
    pub slice_preserving_preemptions: u64,
    pub voluntary_requeues: u64,
}

#[repr(align(64))]
struct CacheAlignedCounter(AtomicU64);

static QUANTUM_EXPIRIES: CacheAlignedCounter = CacheAlignedCounter(AtomicU64::new(0));
static SAME_PRIORITY_ROTATIONS: CacheAlignedCounter = CacheAlignedCounter(AtomicU64::new(0));
static SLICE_PRESERVING_PREEMPTIONS: CacheAlignedCounter = CacheAlignedCounter(AtomicU64::new(0));
static VOLUNTARY_REQUEUES: CacheAlignedCounter = CacheAlignedCounter(AtomicU64::new(0));

/// Returns aggregate fixed-priority round-robin mechanism counters.
pub fn priority_rr_stats_snapshot() -> PriorityRRStats {
    PriorityRRStats {
        quantum_expiries: QUANTUM_EXPIRIES.0.load(Ordering::Relaxed),
        same_priority_rotations: SAME_PRIORITY_ROTATIONS.0.load(Ordering::Relaxed),
        slice_preserving_preemptions: SLICE_PRESERVING_PREEMPTIONS.0.load(Ordering::Relaxed),
        voluntary_requeues: VOLUNTARY_REQUEUES.0.load(Ordering::Relaxed),
    }
}

/// Task wrapper for fixed-priority round-robin scheduling.
pub struct PriorityRRTask<T, const MAX_TIME_SLICE: usize> {
    inner: T,
    time_slice: AtomicIsize,
    links: Links<Self>,
}

impl<T, const S: usize> PriorityRRTask<T, S> {
    /// Creates a task with a full time slice.
    pub const fn new(inner: T) -> Self {
        Self {
            inner,
            time_slice: AtomicIsize::new(S as isize),
            links: Links::new(),
        }
    }

    fn time_slice(&self) -> isize {
        self.time_slice.load(Ordering::Acquire)
    }

    fn reset_time_slice(&self) {
        self.time_slice.store(S as isize, Ordering::Release);
    }

    /// Returns a reference to the wrapped task.
    pub const fn inner(&self) -> &T {
        &self.inner
    }
}

impl<T, const S: usize> GetLinks for PriorityRRTask<T, S> {
    type EntryType = Self;

    fn get_links(data: &Self::EntryType) -> &Links<Self::EntryType> {
        &data.links
    }
}

impl<T, const S: usize> Deref for PriorityRRTask<T, S> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl<T: SchedPriority, const S: usize> SchedPriority for PriorityRRTask<T, S> {
    fn sched_priority(&self) -> isize {
        self.inner.sched_priority()
    }

    fn set_sched_priority(&self, priority: isize) {
        self.inner.set_sched_priority(priority);
    }
}

/// Strict fixed priority between levels, with bounded round-robin within a
/// priority level.
pub struct PriorityRRScheduler<T: SchedPriority, const MAX_TIME_SLICE: usize> {
    ready_queues:
        [List<Arc<PriorityRRTask<T, MAX_TIME_SLICE>>>; (MAX_PRIORITY - MIN_PRIORITY + 1) as usize],
}

impl<T: SchedPriority, const S: usize> PriorityRRScheduler<T, S> {
    /// Creates an empty scheduler.
    pub const fn new() -> Self {
        Self {
            ready_queues: [const { List::new() }; (MAX_PRIORITY - MIN_PRIORITY + 1) as usize],
        }
    }

    /// Returns the scheduler name used by boot diagnostics.
    pub const fn scheduler_name() -> &'static str {
        "Fixed-priority round-robin"
    }

    fn priority_index(task: &PriorityRRTask<T, S>) -> usize {
        task.sched_priority().clamp(MIN_PRIORITY, MAX_PRIORITY) as usize
    }
}

impl<T: SchedPriority, const S: usize> BaseScheduler for PriorityRRScheduler<T, S> {
    type SchedItem = Arc<PriorityRRTask<T, S>>;

    fn init(&mut self) {}

    fn add_task(&mut self, task: Self::SchedItem) {
        self.ready_queues[Self::priority_index(&task)].push_back(task);
    }

    fn remove_task(&mut self, task: &Self::SchedItem) -> Option<Self::SchedItem> {
        unsafe { self.ready_queues[Self::priority_index(task)].remove(task) }
    }

    fn pick_next_task(&mut self) -> Option<Self::SchedItem> {
        self.ready_queues.iter_mut().rev().find_map(List::pop_front)
    }

    fn put_prev_task(&mut self, prev: Self::SchedItem, preempt: bool) {
        let queue = &mut self.ready_queues[Self::priority_index(&prev)];
        // A higher-priority preemption preserves the current task's position
        // and remaining slice. Quantum expiry and voluntary yield rotate the
        // task to the tail and start a fresh slice.
        if preempt && prev.time_slice() > 0 {
            SLICE_PRESERVING_PREEMPTIONS
                .0
                .fetch_add(1, Ordering::Relaxed);
            queue.push_front(prev);
        } else {
            if preempt && !queue.is_empty() {
                SAME_PRIORITY_ROTATIONS.0.fetch_add(1, Ordering::Relaxed);
            } else if !preempt {
                VOLUNTARY_REQUEUES.0.fetch_add(1, Ordering::Relaxed);
            }
            prev.reset_time_slice();
            queue.push_back(prev);
        }
    }

    fn task_tick(&mut self, current: &Self::SchedItem) -> bool {
        let old_slice = current.time_slice.fetch_sub(1, Ordering::Release);
        let expired = old_slice <= 1;
        if expired {
            QUANTUM_EXPIRIES.0.fetch_add(1, Ordering::Relaxed);
        }
        expired
    }

    fn set_priority(&mut self, task: &Self::SchedItem, priority: isize) -> bool {
        if !(MIN_PRIORITY..=MAX_PRIORITY).contains(&priority) {
            return false;
        }
        task.set_sched_priority(priority);
        true
    }
}

impl<T: SchedPriority, const S: usize> Default for PriorityRRScheduler<T, S> {
    fn default() -> Self {
        Self::new()
    }
}
