//! Bounded perception-to-control decisions shared by Task-3 model adapters.
//!
//! The detector runtime is deliberately outside this module.  A YOLO/ONNX,
//! TorchScript, or hardware-NPU adapter supplies normalized detection fields;
//! this module validates them and converts one accepted detection into a
//! control target without allowing model output to bypass the RTOS safety
//! contract.

/// A normalized YOLO-style detection produced by a model adapter.
///
/// All values use integer thousandths so the contract is deterministic in the
/// `no_std` guest and does not depend on floating-point rounding.  Coordinates
/// and area are normalized to `0..=1000`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct YoloDetection {
    pub class_id: u16,
    pub confidence_milli: u16,
    pub center_x_milli: u16,
    pub area_milli: u16,
}

/// Policy limiting how a detection may affect the control target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct YoloPolicy {
    pub min_confidence_milli: u16,
    pub min_area_milli: u16,
    pub target_min: i32,
    pub target_max: i32,
    pub max_target_step: i32,
}

impl YoloPolicy {
    /// Conservative default for the Task-3 `0..=1000` target range.
    pub const fn task3_default() -> Self {
        Self {
            min_confidence_milli: 600,
            min_area_milli: 10,
            target_min: 0,
            target_max: 1000,
            max_target_step: 100,
        }
    }
}

/// Why a model result was not allowed to drive the control loop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PerceptionRejectReason {
    InvalidConfidence,
    InvalidCoordinate,
    InvalidArea,
    LowConfidence,
    SmallArea,
    InvalidTargetRange,
}

/// A validated decision for the controller.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PerceptionDecision {
    /// Apply the bounded target and retain the detector confidence for logs.
    Target {
        target: i32,
        class_id: u16,
        confidence_milli: u16,
    },
    /// Enter the caller's Safe behavior; the reason must be observable.
    Reject(PerceptionRejectReason),
}

/// Convert one normalized YOLO detection into a bounded Task-3 target.
///
/// The x-center maps linearly into the configured target interval.  The
/// maximum step is applied around `current_target` so a single noisy frame
/// cannot create an unbounded control jump.  No detection aggregation or
/// temporal smoothing is hidden here; those policies belong to the caller.
pub fn yolo_detection_to_target(
    detection: YoloDetection,
    current_target: i32,
    policy: YoloPolicy,
) -> PerceptionDecision {
    if detection.confidence_milli > 1000 {
        return PerceptionDecision::Reject(PerceptionRejectReason::InvalidConfidence);
    }
    if detection.center_x_milli > 1000 {
        return PerceptionDecision::Reject(PerceptionRejectReason::InvalidCoordinate);
    }
    if detection.area_milli > 1000 {
        return PerceptionDecision::Reject(PerceptionRejectReason::InvalidArea);
    }
    if policy.target_min > policy.target_max || policy.max_target_step < 0 {
        return PerceptionDecision::Reject(PerceptionRejectReason::InvalidTargetRange);
    }
    if detection.confidence_milli < policy.min_confidence_milli {
        return PerceptionDecision::Reject(PerceptionRejectReason::LowConfidence);
    }
    if detection.area_milli < policy.min_area_milli {
        return PerceptionDecision::Reject(PerceptionRejectReason::SmallArea);
    }

    let target_min = i64::from(policy.target_min);
    let target_max = i64::from(policy.target_max);
    let target_span = target_max - target_min;
    let mapped_target =
        i64::from(policy.target_min) + target_span * i64::from(detection.center_x_milli) / 1000;
    let bounded_current = i64::from(current_target).clamp(target_min, target_max);
    let step = i64::from(policy.max_target_step);
    let target = mapped_target
        .clamp(bounded_current - step, bounded_current + step)
        .clamp(target_min, target_max) as i32;

    PerceptionDecision::Target {
        target,
        class_id: detection.class_id,
        confidence_milli: detection.confidence_milli,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detection(center_x_milli: u16) -> YoloDetection {
        YoloDetection {
            class_id: 1,
            confidence_milli: 900,
            center_x_milli,
            area_milli: 200,
        }
    }

    #[test]
    fn maps_center_and_preserves_detection_metadata() {
        assert_eq!(
            yolo_detection_to_target(detection(500), 500, YoloPolicy::task3_default()),
            PerceptionDecision::Target {
                target: 500,
                class_id: 1,
                confidence_milli: 900,
            }
        );
    }

    #[test]
    fn rejects_low_confidence_and_small_area() {
        let mut low_confidence = detection(500);
        low_confidence.confidence_milli = 599;
        assert_eq!(
            yolo_detection_to_target(low_confidence, 500, YoloPolicy::task3_default()),
            PerceptionDecision::Reject(PerceptionRejectReason::LowConfidence)
        );

        let mut small_area = detection(500);
        small_area.area_milli = 9;
        assert_eq!(
            yolo_detection_to_target(small_area, 500, YoloPolicy::task3_default()),
            PerceptionDecision::Reject(PerceptionRejectReason::SmallArea)
        );
    }

    #[test]
    fn rejects_out_of_range_normalized_fields() {
        let mut invalid = detection(500);
        invalid.center_x_milli = 1001;
        assert_eq!(
            yolo_detection_to_target(invalid, 500, YoloPolicy::task3_default()),
            PerceptionDecision::Reject(PerceptionRejectReason::InvalidCoordinate)
        );

        let mut invalid = detection(500);
        invalid.confidence_milli = 1001;
        assert_eq!(
            yolo_detection_to_target(invalid, 500, YoloPolicy::task3_default()),
            PerceptionDecision::Reject(PerceptionRejectReason::InvalidConfidence)
        );
    }

    #[test]
    fn clamps_single_frame_target_step() {
        assert_eq!(
            yolo_detection_to_target(detection(1000), 500, YoloPolicy::task3_default()),
            PerceptionDecision::Target {
                target: 600,
                class_id: 1,
                confidence_milli: 900,
            }
        );
    }

    #[test]
    fn rejects_invalid_policy_range() {
        let mut policy = YoloPolicy::task3_default();
        policy.target_min = 1000;
        policy.target_max = 0;
        assert_eq!(
            yolo_detection_to_target(detection(500), 500, policy),
            PerceptionDecision::Reject(PerceptionRejectReason::InvalidTargetRange)
        );
    }
}
