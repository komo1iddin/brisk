//! Delivers backend events to Swift.
//!
//! The worker calls `Waker::wake` after every event it sends. The waker here
//! sends on a channel the pump thread waits on; the pump drains the backend,
//! converts the events, and hands them to the listener.
//!
//! A wake asking for a frame after a delay is taken as one now: the pump has
//! no clock to keep, and a drain that finds nothing costs nothing. A slow
//! timeout backs the channel up so an event can be late but never lost.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use zapfast::backend::{Backend, Waker};

use crate::client::EventListener;

/// Longest an event can wait if a wake signal were ever missed.
const SAFETY_POLL: Duration = Duration::from_secs(1);

/// The receiving end of the wake signal the waker raises.
pub struct Signal {
    wakes: Receiver<()>,
}

/// A waker wired to a signal channel, and that channel's receiving end.
pub fn waker() -> (Waker, Signal) {
    let (tx, rx) = mpsc::channel();
    // `Sender` is not `Sync`, and the backend wakes from several threads.
    let tx = Mutex::new(tx);
    let waker = Waker::default();
    waker.attach(move |_delay| {
        let _ = tx.lock().unwrap_or_else(|p| p.into_inner()).send(());
    });
    (waker, Signal { wakes: rx })
}

pub struct Pump {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Pump {
    pub fn spawn(
        backend: Arc<Mutex<Backend>>,
        signal: Signal,
        listener: Arc<dyn EventListener>,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = std::thread::Builder::new()
            .name("zapfast-bridge-pump".into())
            .spawn(move || run(&backend, &signal, &*listener, &stopping))
            .expect("unable to start the bridge event pump");
        Self {
            stop,
            thread: Some(thread),
        }
    }

    pub fn stop(mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn run(backend: &Mutex<Backend>, signal: &Signal, listener: &dyn EventListener, stop: &AtomicBool) {
    // A wake or the safety poll runs a drain; only a dropped sender ends it.
    while !matches!(
        signal.wakes.recv_timeout(SAFETY_POLL),
        Err(RecvTimeoutError::Disconnected)
    ) {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        // Coalesce a burst of wakes into one drain.
        while signal.wakes.try_recv().is_ok() {}

        let raw = backend.lock().unwrap_or_else(|p| p.into_inner()).poll();
        let events: Vec<_> = raw.into_iter().filter_map(crate::events::convert).collect();
        if !events.is_empty() {
            listener.on_events(events);
        }
    }
}
