//! Asks whoever draws the interface for a new frame.
//!
//! The backend runs on its own thread and has no idea what is drawing. It
//! calls [`Waker::wake`] after every event; whoever draws attaches a callback
//! once and the backend never learns more than that. [`Waker::wake_after`]
//! asks for a frame later instead, which is how playback keeps its progress
//! bar moving without a timer of its own.
//!
//! The egui window attaches `fastframe_shell::Waker::wake`, which repaints
//! the context the shell holds. A host that draws with something else (the
//! native macOS interface, which reaches the backend through its own bridge)
//! attaches a callback of its own. This is the whole reason the type lives
//! here rather than being `fastframe_shell`'s: the backend must not depend on
//! egui, so that a build without the egui interface still links.
//!
//! A waker with nothing attached does nothing, which is what tests and
//! headless runs want.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

/// `None` asks for a frame now, `Some(delay)` for one after `delay`.
type Wake = Arc<dyn Fn(Option<Duration>) + Send + Sync>;

/// A handle every part of the backend can hold and clone. Attaching replaces
/// whatever was attached before.
#[derive(Clone, Default)]
pub struct Waker(Arc<Mutex<Option<Wake>>>);

impl std::fmt::Debug for Waker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Waker")
            .field("attached", &self.attached())
            .finish()
    }
}

impl Waker {
    /// Calls `wake` from now on, from whichever thread woke the backend.
    /// Its argument is how long to wait first, if at all; a host that
    /// redraws whenever its own state changes may ignore it.
    pub fn attach(&self, wake: impl Fn(Option<Duration>) + Send + Sync + 'static) {
        *self.lock() = Some(Arc::new(wake));
    }

    /// Stops calling: nothing is drawing any more.
    pub fn detach(&self) {
        *self.lock() = None;
    }

    /// Whether anything is drawing.
    pub fn attached(&self) -> bool {
        self.lock().is_some()
    }

    /// Asks for a new frame, if anything is drawing.
    pub fn wake(&self) {
        self.call(None);
    }

    /// Asks for a frame after `delay`, if anything is drawing.
    pub fn wake_after(&self, delay: Duration) {
        self.call(Some(delay));
    }

    fn call(&self, delay: Option<Duration>) {
        // The callback is cloned out before it runs: it may wake a thread
        // that wakes us straight back, and the lock must not be held then.
        let wake = self.lock().clone();
        if let Some(wake) = wake {
            wake(delay);
        }
    }

    fn lock(&self) -> MutexGuard<'_, Option<Wake>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn a_waker_with_nothing_attached_does_nothing() {
        let waker = Waker::default();
        assert!(!waker.attached());
        waker.wake();
    }

    #[test]
    fn waking_calls_what_was_attached() {
        let waker = Waker::default();
        let woken = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&woken);
        waker.attach(move |_| {
            count.fetch_add(1, Ordering::Relaxed);
        });
        waker.wake();
        waker.wake();
        assert_eq!(woken.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn clones_share_one_callback() {
        let waker = Waker::default();
        let woken = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&woken);
        // Attached through a clone, woken through the original.
        waker.clone().attach(move |_| {
            count.fetch_add(1, Ordering::Relaxed);
        });
        waker.wake();
        assert_eq!(woken.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn detaching_stops_the_callback() {
        let waker = Waker::default();
        let woken = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&woken);
        waker.attach(move |_| {
            count.fetch_add(1, Ordering::Relaxed);
        });
        waker.wake();
        waker.detach();
        waker.wake();
        assert!(!waker.attached());
        assert_eq!(woken.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn a_callback_may_wake_the_same_waker_without_deadlocking() {
        let waker = Waker::default();
        let inner = waker.clone();
        let depth = Arc::new(AtomicUsize::new(0));
        let seen = Arc::clone(&depth);
        waker.attach(move |_| {
            // Only the first call re-enters; the lock must be free by then.
            if seen.fetch_add(1, Ordering::Relaxed) == 0 {
                inner.wake();
            }
        });
        waker.wake();
        assert_eq!(depth.load(Ordering::Relaxed), 2);
    }
}
