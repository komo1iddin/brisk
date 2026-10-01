//! Where a call stands, and how each signal moves it.
//!
//! Pure: the glue in `session` feeds it what WhatsApp and the person did, and
//! publishes whatever phase comes back. A call that has ended stays ended, so
//! a late signal (a terminate after our own hang-up, media closing after the
//! peer's terminate) never reopens or relabels it.

/// Why a call ended, worded from this side.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CallEndReason {
    /// We hung up.
    HungUp,
    /// We declined while it rang.
    Declined,
    /// The other side hung up.
    PeerHungUp,
    /// The other side declined our call.
    PeerDeclined,
    /// The caller gave up before we answered.
    Missed,
    /// Nobody answered our call.
    NoAnswer,
    /// Another of our devices answered.
    AnsweredElsewhere,
    /// Another of our devices declined.
    DeclinedElsewhere,
    /// The media path went away without either side hanging up.
    ConnectionLost,
    /// The call could not be set up.
    Failed { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CallPhase {
    /// Someone is calling us.
    Ringing,
    /// We are calling and nobody has answered yet.
    Calling,
    /// We answered; the media path is being set up.
    Connecting,
    /// Both sides are talking.
    Active,
    Ended {
        reason: CallEndReason,
    },
}

impl CallPhase {
    pub fn is_ended(&self) -> bool {
        matches!(self, Self::Ended { .. })
    }
}

/// What happened to a call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Signal {
    PeerAccepted,
    PeerRejected,
    /// The other side sent `<terminate>`; `timeout` when the server ended an
    /// unanswered call.
    PeerTerminated {
        timeout: bool,
    },
    AnsweredElsewhere,
    DeclinedElsewhere,
    MediaUp,
    MediaEnded,
    TimedOut,
    LocalHangUp,
    Failed(String),
}

/// The phase `signal` moves `phase` to, or `None` when it changes nothing.
pub fn next(phase: &CallPhase, signal: Signal) -> Option<CallPhase> {
    use CallEndReason as Why;
    use CallPhase::*;
    let ended = |reason| Some(Ended { reason });
    match (phase, signal) {
        (Ended { .. }, _) => None,
        (Calling, Signal::PeerAccepted) => Some(Active),
        (Connecting, Signal::MediaUp) => Some(Active),
        (Calling, Signal::PeerRejected) => ended(Why::PeerDeclined),
        (Ringing, Signal::PeerTerminated { .. }) => ended(Why::Missed),
        (Calling, Signal::PeerTerminated { timeout: true }) => ended(Why::NoAnswer),
        (Calling, Signal::PeerTerminated { timeout: false }) => ended(Why::PeerDeclined),
        (Connecting | Active, Signal::PeerTerminated { .. }) => ended(Why::PeerHungUp),
        (Ringing, Signal::AnsweredElsewhere) => ended(Why::AnsweredElsewhere),
        (Ringing, Signal::DeclinedElsewhere) => ended(Why::DeclinedElsewhere),
        (Calling | Connecting | Active, Signal::MediaEnded) => ended(Why::ConnectionLost),
        (Calling, Signal::TimedOut) => ended(Why::NoAnswer),
        (Ringing, Signal::LocalHangUp) => ended(Why::Declined),
        (_, Signal::LocalHangUp) => ended(Why::HungUp),
        (_, Signal::Failed(message)) => ended(Why::Failed { message }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use CallEndReason as Why;

    fn ended(reason: Why) -> Option<CallPhase> {
        Some(CallPhase::Ended { reason })
    }

    #[test]
    fn an_outgoing_call_goes_live_when_the_peer_accepts() {
        assert_eq!(
            next(&CallPhase::Calling, Signal::PeerAccepted),
            Some(CallPhase::Active)
        );
        assert_eq!(next(&CallPhase::Ringing, Signal::PeerAccepted), None);
        assert_eq!(next(&CallPhase::Active, Signal::PeerAccepted), None);
    }

    #[test]
    fn an_answered_call_goes_live_when_media_is_up() {
        assert_eq!(
            next(&CallPhase::Connecting, Signal::MediaUp),
            Some(CallPhase::Active)
        );
        assert_eq!(next(&CallPhase::Calling, Signal::MediaUp), None);
    }

    #[test]
    fn a_terminate_reads_by_where_the_call_was() {
        let peer = Signal::PeerTerminated { timeout: false };
        assert_eq!(next(&CallPhase::Ringing, peer.clone()), ended(Why::Missed));
        assert_eq!(
            next(&CallPhase::Calling, peer.clone()),
            ended(Why::PeerDeclined)
        );
        assert_eq!(
            next(
                &CallPhase::Calling,
                Signal::PeerTerminated { timeout: true }
            ),
            ended(Why::NoAnswer)
        );
        assert_eq!(
            next(&CallPhase::Active, peer.clone()),
            ended(Why::PeerHungUp)
        );
        assert_eq!(next(&CallPhase::Connecting, peer), ended(Why::PeerHungUp));
    }

    #[test]
    fn hanging_up_a_ringing_call_declines_it() {
        assert_eq!(
            next(&CallPhase::Ringing, Signal::LocalHangUp),
            ended(Why::Declined)
        );
        assert_eq!(
            next(&CallPhase::Active, Signal::LocalHangUp),
            ended(Why::HungUp)
        );
        assert_eq!(
            next(&CallPhase::Calling, Signal::LocalHangUp),
            ended(Why::HungUp)
        );
    }

    #[test]
    fn another_device_settles_a_ringing_call_only() {
        assert_eq!(
            next(&CallPhase::Ringing, Signal::AnsweredElsewhere),
            ended(Why::AnsweredElsewhere)
        );
        assert_eq!(
            next(&CallPhase::Ringing, Signal::DeclinedElsewhere),
            ended(Why::DeclinedElsewhere)
        );
        assert_eq!(next(&CallPhase::Active, Signal::AnsweredElsewhere), None);
    }

    #[test]
    fn media_ending_on_its_own_is_a_lost_connection() {
        assert_eq!(
            next(&CallPhase::Active, Signal::MediaEnded),
            ended(Why::ConnectionLost)
        );
        assert_eq!(next(&CallPhase::Ringing, Signal::MediaEnded), None);
    }

    #[test]
    fn an_ended_call_stays_as_it_ended() {
        let over = CallPhase::Ended {
            reason: Why::PeerHungUp,
        };
        for signal in [
            Signal::PeerAccepted,
            Signal::PeerTerminated { timeout: false },
            Signal::MediaEnded,
            Signal::LocalHangUp,
            Signal::Failed("late".into()),
        ] {
            assert_eq!(next(&over, signal), None);
        }
    }

    #[test]
    fn only_an_unanswered_outgoing_call_times_out() {
        assert_eq!(
            next(&CallPhase::Calling, Signal::TimedOut),
            ended(Why::NoAnswer)
        );
        assert_eq!(next(&CallPhase::Active, Signal::TimedOut), None);
    }
}
