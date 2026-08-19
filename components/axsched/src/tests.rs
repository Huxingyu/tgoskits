macro_rules! def_test_sched {
    ($name:ident, $scheduler:ty, $task:ty) => {
        mod $name {
            use alloc::sync::Arc;

            use crate::*;

            #[test]
            fn test_sched() {
                const NUM_TASKS: usize = 11;

                let mut scheduler = <$scheduler>::new();
                for i in 0..NUM_TASKS {
                    scheduler.add_task(Arc::new(<$task>::new(i)));
                }

                for i in 0..NUM_TASKS * 10 - 1 {
                    let next = scheduler.pick_next_task().unwrap();
                    assert_eq!(*next.inner(), i % NUM_TASKS);
                    // pass a tick to ensure the order of tasks
                    scheduler.task_tick(&next);
                    scheduler.put_prev_task(next, false);
                }

                let mut n = 0;
                while scheduler.pick_next_task().is_some() {
                    n += 1;
                }
                assert_eq!(n, NUM_TASKS);
            }

            #[test]
            fn bench_yield() {
                const NUM_TASKS: usize = 1_000_000;
                const COUNT: usize = NUM_TASKS * 3;

                let mut scheduler = <$scheduler>::new();
                for i in 0..NUM_TASKS {
                    scheduler.add_task(Arc::new(<$task>::new(i)));
                }

                let t0 = std::time::Instant::now();
                for _ in 0..COUNT {
                    let next = scheduler.pick_next_task().unwrap();
                    scheduler.put_prev_task(next, false);
                }
                let t1 = std::time::Instant::now();
                println!(
                    "  {}: task yield speed: {:?}/task",
                    stringify!($scheduler),
                    (t1 - t0) / (COUNT as u32)
                );
            }

            #[test]
            fn bench_remove() {
                const NUM_TASKS: usize = 10_000;

                let mut scheduler = <$scheduler>::new();
                let mut tasks = Vec::new();
                for i in 0..NUM_TASKS {
                    let t = Arc::new(<$task>::new(i));
                    tasks.push(t.clone());
                    scheduler.add_task(t);
                }

                let t0 = std::time::Instant::now();
                for i in (0..NUM_TASKS).rev() {
                    let t = scheduler.remove_task(&tasks[i]).unwrap();
                    assert_eq!(*t.inner(), i);
                }
                let t1 = std::time::Instant::now();
                println!(
                    "  {}: task remove speed: {:?}/task",
                    stringify!($scheduler),
                    (t1 - t0) / (NUM_TASKS as u32)
                );
            }
        }
    };
}

def_test_sched!(fifo, FifoScheduler::<usize>, FifoTask::<usize>);
def_test_sched!(rr, RRScheduler::<usize, 5>, RRTask::<usize, 5>);
def_test_sched!(cfs, CFScheduler::<usize>, CFSTask::<usize>);

struct PriorityTestTask {
    value: usize,
    priority: core::sync::atomic::AtomicIsize,
}

impl PriorityTestTask {
    const fn new(value: usize) -> Self {
        Self {
            value,
            priority: core::sync::atomic::AtomicIsize::new(0),
        }
    }
}

impl crate::SchedPriority for PriorityTestTask {
    fn sched_priority(&self) -> isize {
        self.priority.load(core::sync::atomic::Ordering::Acquire)
    }

    fn set_sched_priority(&self, priority: isize) {
        self.priority
            .store(priority, core::sync::atomic::Ordering::Release);
    }
}

#[test]
fn fixed_priority_runs_highest_first_and_preserves_fifo() {
    use alloc::sync::Arc;

    use crate::{BaseScheduler, PriorityScheduler, PriorityTask};

    let mut scheduler = PriorityScheduler::<PriorityTestTask>::new();
    let low = Arc::new(PriorityTask::new(PriorityTestTask::new(0)));
    let high_first = Arc::new(PriorityTask::new(PriorityTestTask::new(1)));
    let high_second = Arc::new(PriorityTask::new(PriorityTestTask::new(2)));
    assert!(scheduler.set_priority(&low, 10));
    assert!(scheduler.set_priority(&high_first, 90));
    assert!(scheduler.set_priority(&high_second, 90));

    scheduler.add_task(low);
    scheduler.add_task(high_first);
    scheduler.add_task(high_second);

    assert_eq!(scheduler.pick_next_task().unwrap().inner().value, 1);
    assert_eq!(scheduler.pick_next_task().unwrap().inner().value, 2);
    assert_eq!(scheduler.pick_next_task().unwrap().inner().value, 0);
}

#[test]
fn fixed_priority_preemption_preserves_same_class_position() {
    use alloc::sync::Arc;

    use crate::{BaseScheduler, PriorityScheduler, PriorityTask};

    let mut scheduler = PriorityScheduler::<PriorityTestTask>::new();
    let current = Arc::new(PriorityTask::new(PriorityTestTask::new(0)));
    let peer = Arc::new(PriorityTask::new(PriorityTestTask::new(1)));
    assert!(scheduler.set_priority(&current, 90));
    assert!(scheduler.set_priority(&peer, 90));
    scheduler.add_task(peer);
    scheduler.put_prev_task(current, true);

    assert_eq!(scheduler.pick_next_task().unwrap().inner().value, 0);
    assert_eq!(scheduler.pick_next_task().unwrap().inner().value, 1);
}

#[test]
fn fixed_priority_rejects_out_of_range_values() {
    use alloc::sync::Arc;

    use crate::{BaseScheduler, MAX_PRIORITY, MIN_PRIORITY, PriorityScheduler, PriorityTask};

    let mut scheduler = PriorityScheduler::<PriorityTestTask>::new();
    let task = Arc::new(PriorityTask::new(PriorityTestTask::new(0)));

    assert!(!scheduler.set_priority(&task, MIN_PRIORITY - 1));
    assert!(!scheduler.set_priority(&task, MAX_PRIORITY + 1));
    assert!(scheduler.set_priority(&task, MAX_PRIORITY));
}

#[test]
fn fixed_priority_rr_rotates_same_priority_tasks_after_slice_expiry() {
    use alloc::sync::Arc;

    use crate::{BaseScheduler, PriorityRRScheduler, PriorityRRTask, priority_rr_stats_snapshot};

    let stats_before = priority_rr_stats_snapshot();
    let mut scheduler = PriorityRRScheduler::<PriorityTestTask, 2>::new();
    let first = Arc::new(PriorityRRTask::new(PriorityTestTask::new(0)));
    let second = Arc::new(PriorityRRTask::new(PriorityTestTask::new(1)));
    assert!(scheduler.set_priority(&first, 90));
    assert!(scheduler.set_priority(&second, 90));
    scheduler.add_task(first);
    scheduler.add_task(second);

    let current = scheduler.pick_next_task().unwrap();
    assert_eq!(current.inner().value, 0);
    assert!(!scheduler.task_tick(&current));
    scheduler.put_prev_task(current, true);

    let current = scheduler.pick_next_task().unwrap();
    assert_eq!(current.inner().value, 0);
    assert!(scheduler.task_tick(&current));
    scheduler.put_prev_task(current, true);

    assert_eq!(scheduler.pick_next_task().unwrap().inner().value, 1);
    let stats_after = priority_rr_stats_snapshot();
    assert!(stats_after.quantum_expiries > stats_before.quantum_expiries);
    assert!(stats_after.same_priority_rotations > stats_before.same_priority_rotations);
}

#[test]
fn fixed_priority_rr_preserves_preempted_task_until_slice_expiry() {
    use alloc::sync::Arc;

    use crate::{BaseScheduler, PriorityRRScheduler, PriorityRRTask};

    let mut scheduler = PriorityRRScheduler::<PriorityTestTask, 2>::new();
    let low = Arc::new(PriorityRRTask::new(PriorityTestTask::new(0)));
    let high = Arc::new(PriorityRRTask::new(PriorityTestTask::new(1)));
    assert!(scheduler.set_priority(&low, 90));
    assert!(scheduler.set_priority(&high, 91));

    scheduler.add_task(low.clone());
    let current = scheduler.pick_next_task().unwrap();
    assert_eq!(current.inner().value, 0);
    assert!(!scheduler.task_tick(&current));
    scheduler.add_task(high);
    scheduler.put_prev_task(current, true);

    assert_eq!(scheduler.pick_next_task().unwrap().inner().value, 1);
    assert_eq!(scheduler.pick_next_task().unwrap().inner().value, 0);
}

#[test]
fn rr_preempt_preserves_slice_but_forced_reschedule_rotates() {
    use alloc::sync::Arc;

    use crate::{BaseScheduler, RRScheduler, RRTask};

    let mut scheduler = RRScheduler::<usize, 5>::new();
    let current = Arc::new(RRTask::<usize, 5>::new(0));
    let remote = Arc::new(RRTask::<usize, 5>::new(1));
    scheduler.add_task(remote.clone());
    scheduler.put_prev_task(current.clone(), true);
    assert_eq!(
        *scheduler.pick_next_task().unwrap().inner(),
        0,
        "ordinary RR preemption preserves the current task's remaining slice",
    );

    let mut scheduler = RRScheduler::<usize, 5>::new();
    let current = Arc::new(RRTask::<usize, 5>::new(0));
    let remote = Arc::new(RRTask::<usize, 5>::new(1));
    scheduler.add_task(remote);
    scheduler.put_prev_task(current, false);
    assert_eq!(
        *scheduler.pick_next_task().unwrap().inner(),
        1,
        "forced remote reschedule must rotate the current task behind queued work",
    );
}
